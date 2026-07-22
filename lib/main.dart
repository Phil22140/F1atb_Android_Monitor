import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Client HTTP natif, plus permissif que le package http ─────────────────────
Future<String> simpleGet(String url, {String? cookie}) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 8);
  client.badCertificateCallback = (cert, host, port) => true;
  try {
    final uri = Uri.parse(url);
    final request = await client.getUrl(uri);
    request.headers.set('Connection', 'close');
    if (cookie != null && cookie.isNotEmpty) {
      request.headers.set('Cookie', cookie);
    }
    final response = await request.close();
    final body = await response.transform(const SystemEncoding().decoder).join();
    return body;
  } finally {
    client.close(force: true);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChauffeEauApp());
}

// ── Séparateurs ASCII (identiques au firmware F1ATB) ──────────────────────────
const String GS = '\x1d'; // Group Separator
const String appVersion = '3.5.4';
const String RS = '\x1e'; // Record Separator

// ── Parsing /ajax_data ────────────────────────────────────────────────────────
Map<String, double> parsePuissances(String body) {
  final groupes = body.split(GS);
  if (groupes.length < 2) return {'pws': 0.0, 'pwi': 0.0, 'pwsT': 0.0, 'pwiT': 0.0};
  final g1 = groupes[1].split(RS);
  final pws = double.tryParse(g1[0].trim()) ?? 0.0;
  final pwi = g1.length > 1 ? (double.tryParse(g1[1].trim()) ?? 0.0) : 0.0;
  double pwsT = 0.0, pwiT = 0.0;
  if (groupes.length >= 3) {
    final g2 = groupes[2].split(RS);
    pwsT = double.tryParse(g2[0].trim()) ?? 0.0;
    pwiT = g2.length > 1 ? (double.tryParse(g2[1].trim()) ?? 0.0) : 0.0;
  }
  return {'pws': pws, 'pwi': pwi, 'pwsT': pwsT, 'pwiT': pwiT};
}

// ── Parsing des températures (G0[5] de /ajax_data) ────────────────────────────
// Format: "2.02|1.96|1.96|1.98|" — capteur absent = -127.00
List<double?> parseTemperatures(String body) {
  final groupes = body.split(GS);
  if (groupes.isEmpty) return [null, null, null, null];
  final g0 = groupes[0].split(RS);
  if (g0.length < 6) return [null, null, null, null];

  final raw = g0[5].trim(); // "2.02|1.96|1.96|1.98|"
  final parts = raw.split('|').where((s) => s.isNotEmpty).toList();

  return List.generate(4, (i) {
    if (i >= parts.length) return null;
    final v = double.tryParse(parts[i].trim());
    if (v == null || v <= -100) return null; // -127.00 = capteur absent
    return v;
  });
}

// ── Parsing des noms/activation capteurs (JSON /ParaFixe) ────────────────────
class CapteurInfo {
  final String nom;
  final bool actif;
  const CapteurInfo({required this.nom, required this.actif});
}

List<CapteurInfo> parseCapteursInfo(String jsonBody) {
  try {
    final data = jsonDecode(jsonBody) as Map<String, dynamic>;
    return List.generate(4, (i) {
      final nom = (data['nomTemperature$i'] ?? 'Capteur ${i + 1}').toString();
      final source = (data['Source_Temp$i'] ?? 'tempNo').toString();
      return CapteurInfo(nom: nom, actif: source != 'tempNo');
    });
  } catch (_) {
    return List.generate(4, (i) => const CapteurInfo(nom: '', actif: false));
  }
}


// ── Parsing /ajax_etatActions ─────────────────────────────────────────────────
// ── Conversion équivalence ouverture → HH:MM ─────────────────────────────────
// data[4] * 60 / 100, arrondi, converti en H:MM
String equivToHmn(String raw) {
  final val = int.tryParse(raw.trim()) ?? 0;
  final totalMinutes = (val * 60 / 100).round();
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  return '$h:${m.toString().padLeft(2, '0')}';
}

// ── Parsing /ajax_etatActions (multi-modules : Triac unique ou relais SSR 1-9) ─
class ModuleData {
  final int numAction;       // NumAction réel à utiliser pour le forçage
  final String nom;          // nom du contacteur (ex: "Chauffe-Eau", "Relais 1")
  final double? ouverture;   // % ouverture (ou 100/0 si 'On'/'Off')
  final int forcage;         // 0=auto, >0=forcé ON (min restantes), <0=forcé OFF
  final String? heureEquiv;  // équivalence HH:MM à 100%
  const ModuleData({
    required this.numAction,
    required this.nom,
    this.ouverture,
    this.forcage = 0,
    this.heureEquiv,
  });
}

List<ModuleData> parseActionneurs(String body) {
  final groupes = body.split(GS);
  if (groupes.length < 5) return [];

  final modules = <ModuleData>[];
  // groupes[4..] : un groupe par module actif
  for (var i = 4; i < groupes.length; i++) {
    final raw = groupes[i].trim();
    if (raw.isEmpty) continue;
    final data = raw.split(RS);
    if (data.length < 3) continue;

    final numAction = int.tryParse(data[0].trim()) ?? 0;
    final nom = data[1].trim();

    final v = data[2].trim();
    double? ouverture;
    if (v == 'On')       ouverture = 100;
    else if (v == 'Off') ouverture = 0;
    else                 ouverture = double.tryParse(v);

    int forcage = 0;
    if (data.length >= 4) forcage = int.tryParse(data[3].trim()) ?? 0;

    String? heureEquiv;
    if (data.length >= 5) {
      final rawH = data[4].trim();
      if (rawH.isNotEmpty) heureEquiv = equivToHmn(rawH);
    }

    modules.add(ModuleData(
      numAction: numAction,
      nom: nom,
      ouverture: ouverture,
      forcage: forcage,
      heureEquiv: heureEquiv,
    ));
  }
  return modules;
}

// ── App principale ─────────────────────────────────────────────────────────────
class ChauffeEauApp extends StatelessWidget {
  const ChauffeEauApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'F1ATB Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0F1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFF97316),
          surface: Color(0xFF111827),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ── Config et état par ESP32 ───────────────────────────────────────────────────
class EspConfig {
  final String name;
  final String url;
  final String password;
  final List<int>? enabledNumActions;   // null=tout afficher, []=aucune, [0,1]=filtrés
  final List<int>? enabledTempIndices;  // null=tout afficher, []=aucun, [0,2]=filtrés
  const EspConfig({
    required this.name,
    required this.url,
    required this.password,
    this.enabledNumActions,
    this.enabledTempIndices,
  });
}

class EspState {
  final List<ModuleData> modules;
  final int? selectedNumAction;
  final List<CapteurInfo> capteursInfo;
  final List<double?> temperatures;
  final double pws;
  final double pwi;
  final double pwsT;   // puissance soutirée sonde fixe (Triac)
  final double pwiT;   // puissance injectée sonde fixe (Triac)
  final String nomSonde1; // nom sonde mobile (G1)
  final String nomSonde2; // nom sonde fixe (G2) — vide = pas de seconde sonde
  final String nomPpos;   // label puissance positive sonde fixe (ex: "Soutiré")
  final String nomPneg;   // label puissance négative sonde fixe (ex: "Injecté")
  final bool ok;
  final String statusTxt;
  final String? routerVersion;

  EspState({
    this.modules = const [],
    this.selectedNumAction,
    List<CapteurInfo>? capteursInfo,
    List<double?>? temperatures,
    this.pws = 0,
    this.pwi = 0,
    this.pwsT = 0,
    this.pwiT = 0,
    this.nomSonde1 = '',
    this.nomSonde2 = '',
    this.nomPpos = 'Soutiré',
    this.nomPneg = 'Injecté',
    this.ok = false,
    this.statusTxt = 'connexion…',
    this.routerVersion,
  })  : capteursInfo = capteursInfo ?? const [],
        temperatures = temperatures ?? const [null, null, null, null];

  EspState copyWith({
    List<ModuleData>? modules,
    int? selectedNumAction,
    bool clearSelected = false,
    List<CapteurInfo>? capteursInfo,
    List<double?>? temperatures,
    double? pws,
    double? pwi,
    double? pwsT,
    double? pwiT,
    String? nomSonde1,
    String? nomSonde2,
    String? nomPpos,
    String? nomPneg,
    bool? ok,
    String? statusTxt,
    String? routerVersion,
  }) {
    return EspState(
      modules: modules ?? this.modules,
      selectedNumAction: clearSelected ? null : (selectedNumAction ?? this.selectedNumAction),
      capteursInfo: capteursInfo ?? this.capteursInfo,
      temperatures: temperatures ?? this.temperatures,
      pws: pws ?? this.pws,
      pwi: pwi ?? this.pwi,
      pwsT: pwsT ?? this.pwsT,
      pwiT: pwiT ?? this.pwiT,
      nomSonde1: nomSonde1 ?? this.nomSonde1,
      nomSonde2: nomSonde2 ?? this.nomSonde2,
      nomPpos: nomPpos ?? this.nomPpos,
      nomPneg: nomPneg ?? this.nomPneg,
      ok: ok ?? this.ok,
      statusTxt: statusTxt ?? this.statusTxt,
      routerVersion: routerVersion ?? this.routerVersion,
    );
  }
}

// ── Écran principal ────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<EspConfig> _espConfigs = [];
  List<EspState>  _espStates  = [];
  String _orientationMode = 'auto';
  String _displayMode     = 'multi'; // 'multi' | 'single'
  bool   _multiSites      = false;   // false=site unique, true=multisites
  int _currentPage = 0;
  int? _singleSelectedId;  // encodé : espIdx * 1000 + numAction
  late PageController _pageController;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _loadConfig();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // ── Config ──────────────────────────────────────────────────────────────────

  // ── Fichier de config (plus fiable que SharedPreferences sur Android) ─────
  Future<File> get _configFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/esp_config.json');
  }

  Future<void> _loadConfig() async {
    final configs     = <EspConfig>[];
    String orientation = 'auto';

    // ── Priorité 1 : fichier JSON (format actuel, fiable) ──────────────────
    try {
      final file = await _configFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final data    = jsonDecode(content) as Map<String, dynamic>;
        orientation   = (data['orientation'] as String?) ?? 'auto';
        final dm      = (data['display_mode'] as String?) ?? 'multi';
        _displayMode  = dm;
        _multiSites   = (data['multi_sites'] as bool?) ?? false;
        final list    = (data['configs'] as List).cast<Map<String, dynamic>>();
        for (final c in list) {
          configs.add(EspConfig(
            name:               (c['name'] as String?) ?? 'ESP',
            url:                (c['url']  as String?) ?? '',
            password:           (c['pwd']  as String?) ?? '',
            enabledNumActions:  c.containsKey('enabled')
                ? (c['enabled'] as List?)?.cast<int>()
                : null,
            enabledTempIndices: c.containsKey('enabled_temps')
                ? (c['enabled_temps'] as List?)?.cast<int>()
                : null,
          ));
        }
      }
    } catch (_) { configs.clear(); }

    // ── Priorité 2 : SharedPreferences esp_configs_json (v3.2.0) ───────────
    if (configs.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        orientation  = prefs.getString('orientation_mode') ?? orientation;
        final json   = prefs.getString('esp_configs_json');
        if (json != null) {
          final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
          for (final c in list) {
            configs.add(EspConfig(
              name:              (c['name'] as String?) ?? 'ESP',
              url:               (c['url']  as String?) ?? '',
              password:          (c['pwd']  as String?) ?? '',
              enabledNumActions: c.containsKey('enabled')
                  ? (c['enabled'] as List?)?.cast<int>()
                  : null,
              enabledTempIndices: c.containsKey('enabled_temps')
                  ? (c['enabled_temps'] as List?)?.cast<int>()
                  : null,
            ));
          }
        }
      } catch (_) { configs.clear(); }
    }

    // ── Priorité 3 : SharedPreferences multi-clés (v3.0-v3.1) ─────────────
    if (configs.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        orientation  = prefs.getString('orientation_mode') ?? orientation;
        // Découverte automatique — ne pas faire confiance à esp_count
        int count    = prefs.getInt('esp_count') ?? 0;
        if (count == 0) {
          for (var i = 0; i < 9; i++) {
            if (prefs.getString('esp_${i}_url') != null) count = i + 1;
            else break;
          }
        }
        if (count == 0) count = 1;
        for (var i = 0; i < count; i++) {
          final url  = prefs.getString('esp_${i}_url')
              ?? (i == 0 ? prefs.getString('esp32_url') ?? '' : '');
          final pwd  = prefs.getString('esp_${i}_pwd')
              ?? (i == 0 ? prefs.getString('esp32_pwd') ?? '' : '');
          final name = prefs.getString('esp_${i}_name')
              ?? (count == 1 ? 'F1ATB Monitor' : 'ESP ${i + 1}');
          configs.add(EspConfig(name: name, url: url, password: pwd));
        }
      } catch (_) { configs.clear(); }
    }

    // ── Priorité 4 : très ancienne clé unique ──────────────────────────────
    if (configs.isEmpty || configs.first.url.isEmpty) {
      try {
        final prefs  = await SharedPreferences.getInstance();
        final oldUrl = prefs.getString('esp32_url') ?? '';
        final oldPwd = prefs.getString('esp32_pwd') ?? '';
        if (oldUrl.isNotEmpty) {
          configs.clear();
          configs.add(EspConfig(name: 'F1ATB Monitor', url: oldUrl, password: oldPwd));
        }
      } catch (_) {}
    }

    if (configs.isNotEmpty && configs.first.url.isNotEmpty) {
      setState(() {
        _espConfigs = configs;
        _espStates  = List.generate(configs.length, (_) => EspState());
        _orientationMode = orientation;
      });
      _applyOrientation(orientation);
      _startPolling();
    } else {
      _showConfig();
    }
  }

  Future<void> _saveConfig(List<EspConfig> configs, String orientation,
      String displayMode, bool multiSites) async {
    _displayMode = displayMode;
    _multiSites  = multiSites;
    // ── Sauvegarde dans un fichier JSON (synchrone = garanti sur disque) ───
    try {
      final file    = await _configFile;
      final content = jsonEncode({
        'orientation':  orientation,
        'display_mode': _displayMode,
        'multi_sites':  _multiSites,
        'configs': configs.map((c) {
          final map = <String, dynamic>{
            'name': c.name,
            'url':  c.url,
            'pwd':  c.password,
          };
          // N'inclure 'enabled' que si configuré explicitement
          // (null = pas de test = tout afficher → clé absente dans le JSON)
          if (c.enabledNumActions  != null) map['enabled']       = c.enabledNumActions;
          if (c.enabledTempIndices != null) map['enabled_temps'] = c.enabledTempIndices;
          return map;
        }).toList(),
      });
      await file.writeAsString(content, flush: true); // flush=true force l'écriture disque
    } catch (_) {}

    // ── Backward compat SharedPreferences (pour migration future) ──────────
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('orientation_mode', orientation);
      if (configs.isNotEmpty) {
        await prefs.setString('esp32_url', configs.first.url);
        await prefs.setString('esp32_pwd', configs.first.password);
      }
    } catch (_) {}

    setState(() {
      _espConfigs = configs;
      while (_espStates.length < configs.length) _espStates.add(EspState());
      if (_espStates.length > configs.length) {
        _espStates = _espStates.sublist(0, configs.length);
      }
      _orientationMode = orientation;
    });
    _applyOrientation(orientation);
    _startPolling();
  }

  void _applyOrientation(String mode) {
    switch (mode) {
      case 'portrait':
        SystemChrome.setPreferredOrientations(
            [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
        break;
      case 'landscape':
        SystemChrome.setPreferredOrientations(
            [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
        break;
      default:
        SystemChrome.setPreferredOrientations([]);
    }
  }

  // ── Polling ─────────────────────────────────────────────────────────────────

  void _startPolling() {
    _timer?.cancel();
    if (_displayMode == 'single') {
      // Mode page unique : poll tous les ESPs
      for (var i = 0; i < _espConfigs.length; i++) _fetchCapteursInfo(i);
      _refreshAll();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refreshAll());
    } else {
      // Mode multi-pages : poll seulement la page visible
      _fetchCapteursInfo(_currentPage);
      _refreshEsp(_currentPage);
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refreshEsp(_currentPage));
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      for (var i = 0; i < _espConfigs.length; i++) _refreshEsp(i),
    ]);
  }

  Future<void> _fetchCapteursInfo(int idx) async {
    if (idx >= _espConfigs.length) return;
    final cfg = _espConfigs[idx];
    final base = cfg.url.trimRight().replaceAll(RegExp(r'/$'), '');
    final cookie = cfg.password.isNotEmpty ? 'CleAcces=${cfg.password}' : null;
    try {
      final body = await simpleGet('$base/ParaFixe', cookie: cookie)
          .timeout(const Duration(seconds: 8));
      final infos = parseCapteursInfo(body);
      String? routerVer;
      String nomSonde1 = '';
      String nomSonde2 = '';
      String nomPpos   = 'Soutiré';
      String nomPneg   = 'Injecté';
      try {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final v = int.tryParse(data['VersionStocke']?.toString() ?? '');
        if (v != null) routerVer = (v / 100).toStringAsFixed(2);
        nomSonde1 = (data['nomSondeMobile'] ?? '').toString();
        nomSonde2 = (data['nomSondeFixe']  ?? '').toString();
        nomPpos   = (data['nomSfixePpos']  ?? 'Soutiré').toString();
        nomPneg   = (data['nomSfixePneg']  ?? 'Injecté').toString();
        // Source sans sonde fixe (triphasé, compteur externe...) → pas de 2e sonde
        final source = (data['Source'] ?? '').toString();
        if (source == 'Ext' || source == 'ShellyPro') nomSonde2 = '';
      } catch (_) {}
      if (mounted) setState(() {
        _espStates[idx] = _espStates[idx].copyWith(
          capteursInfo: infos,
          routerVersion: routerVer,
          nomSonde1: nomSonde1,
          nomSonde2: nomSonde2,
          nomPpos: nomPpos,
          nomPneg: nomPneg,
        );
      });
    } catch (_) {}
  }

  Future<void> _refreshEsp(int idx) async {
    if (idx >= _espConfigs.length) return;
    final cfg = _espConfigs[idx];
    final base = cfg.url.trimRight().replaceAll(RegExp(r'/$'), '');
    final cookie = cfg.password.isNotEmpty ? 'CleAcces=${cfg.password}' : null;
    try {
      final results = await Future.wait([
        simpleGet('$base/ajax_data', cookie: cookie),
        simpleGet('$base/ajax_etatActions?Force=0&NumAction=0', cookie: cookie),
      ]).timeout(const Duration(seconds: 10));

      final pw      = parsePuissances(results[0]);
      final modules = parseActionneurs(results[1]);
      final temps   = parseTemperatures(results[0]);

      final old = _espStates[idx];
      int? sel = old.selectedNumAction;
      if (modules.length == 1) {
        sel = modules.first.numAction;
      } else if (sel != null && !modules.any((m) => m.numAction == sel)) {
        sel = null;
      }

      if (mounted) setState(() {
        _espStates[idx] = old.copyWith(
          modules: modules,
          selectedNumAction: sel,
          temperatures: temps,
          pws:  pw['pws']!,
          pwi:  pw['pwi']!,
          pwsT: pw['pwsT']!,
          pwiT: pw['pwiT']!,
          ok: true,
          statusTxt: 'màj ${TimeOfDay.now().format(context)}',
        );
      });
    } catch (e) {
      if (mounted) setState(() {
        _espStates[idx] = _espStates[idx].copyWith(
          ok: false,
          statusTxt: 'erreur : $e',
        );
      });
    }
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _sendForce(int espIdx, int force) async {
    if (espIdx >= _espStates.length) return;
    final state = _espStates[espIdx];
    if (state.selectedNumAction == null) return;
    final cfg = _espConfigs[espIdx];
    final base = cfg.url.trimRight().replaceAll(RegExp(r'/$'), '');
    final cookie = cfg.password.isNotEmpty ? 'CleAcces=${cfg.password}' : null;
    try {
      await simpleGet(
        '$base/ajax_etatActions?Force=$force&NumAction=${state.selectedNumAction}',
        cookie: cookie,
      );
      await _refreshEsp(espIdx);
    } catch (_) {}
  }

  void _selectModule(int espIdx, int numAction) {
    if (espIdx >= _espStates.length) return;
    setState(() {
      _espStates[espIdx] = _espStates[espIdx].copyWith(selectedNumAction: numAction);
    });
  }

  // ── Helpers mode page unique ────────────────────────────────────────────────

  // Construit la liste combinée de tous les modules visibles de tous les ESPs
  List<ModuleData> _buildCombinedModules() {
    final result = <ModuleData>[];
    for (var i = 0; i < _espConfigs.length; i++) {
      if (i >= _espStates.length) continue;
      final cfg   = _espConfigs[i];
      final state = _espStates[i];
      final visible = cfg.enabledNumActions == null
          ? state.modules
          : state.modules.where((m) => cfg.enabledNumActions!.contains(m.numAction)).toList();
      for (final m in visible) {
        result.add(ModuleData(
          numAction:  i * 1000 + m.numAction, // ID encodé unique
          nom:        '${cfg.name} - ${m.nom}',
          ouverture:  m.ouverture,
          forcage:    m.forcage,
          heureEquiv: m.heureEquiv,
        ));
      }
    }
    return result;
  }

  // Module sélectionné en mode single
  ({int espIdx, ModuleData module})? _getSingleSelected() {
    if (_singleSelectedId == null) return null;
    final espIdx   = _singleSelectedId! ~/ 1000;
    final numAction = _singleSelectedId! % 1000;
    if (espIdx >= _espStates.length) return null;
    for (final m in _espStates[espIdx].modules) {
      if (m.numAction == numAction) return (espIdx: espIdx, module: m);
    }
    return null;
  }

  Future<void> _sendForceSingle(int encodedId, int force) async {
    final espIdx   = encodedId ~/ 1000;
    final numAction = encodedId % 1000;
    if (espIdx >= _espStates.length) return;
    setState(() {
      _espStates[espIdx] = _espStates[espIdx].copyWith(selectedNumAction: numAction);
    });
    await _sendForce(espIdx, force);
  }

  void _showConfig() {
    _timer?.cancel();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => ConfigSheet(
        currentConfigs: _espConfigs.isNotEmpty
            ? _espConfigs
            : [const EspConfig(name: 'F1ATB Monitor', url: '', password: '')],
        currentOrientation: _orientationMode,
        currentDisplayMode: _displayMode,
        currentMultiSites:  _multiSites,
        onSave: (configs, orientation, displayMode, multiSites) async {
          await _saveConfig(configs, orientation, displayMode, multiSites);
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  // ── Blocs réutilisables ─────────────────────────────────────────────────────

  Widget _buildHeader(EspConfig cfg, {required bool compact, required double imageHeight}) {
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(width: imageHeight, height: imageHeight,
                  child: Image.asset('assets/icon.png', fit: BoxFit.cover)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(cfg.name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      letterSpacing: 1.5, color: Color(0xFF5A6278))),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(width: double.infinity, height: imageHeight,
            child: Image.asset('assets/icon.png', fit: BoxFit.contain)),
      ),
    );
  }

  Widget _buildGauges(EspState state, int espIdx,
      {required List<ModuleData> modules}) {
    if (modules.isEmpty) return const SizedBox.shrink();
    if (modules.length <= 1) {
      return GaugeWidget(
        value: modules.isNotEmpty ? (modules.first.ouverture ?? 0) : 0,
        hasValue: modules.isNotEmpty && modules.first.ouverture != null,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ModulesGrid(
        modules: modules,
        selectedNumAction: state.selectedNumAction,
        onSelect: (n) => _selectModule(espIdx, n),
      ),
    );
  }

  Widget _buildEquiv(EspState state, {required List<ModuleData> modules}) {
    if (modules.length <= 1 && modules.isNotEmpty &&
        modules.first.heureEquiv != null) {
      return Text(
        'équivalent à ${modules.first.heureEquiv} à 100%',
        style: const TextStyle(
            fontSize: 12, color: Color(0xFF5A6278), fontFamily: 'monospace'),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildPowerCards(EspState state) {
    return Row(children: [
      Expanded(child: PowerCard(label: 'Soutiré', value: state.pws,
          color: const Color(0xFFF43F5E))),
      const SizedBox(width: 10),
      Expanded(child: PowerCard(label: 'Injecté', value: state.pwi,
          color: const Color(0xFF22D3A8))),
    ]);
  }

  Widget _buildSecondeSonde(EspState state) {
    if (state.nomSonde2.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Ligne de séparation + nom de la sonde
        Row(children: [
          Expanded(child: Divider(color: Colors.white.withOpacity(0.07), height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(state.nomSonde2.toUpperCase(),
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                    letterSpacing: 1.4, color: Color(0xFF5A6278))),
          ),
          Expanded(child: Divider(color: Colors.white.withOpacity(0.07), height: 1)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: PowerCard(label: state.nomPpos,
              value: state.pwsT, color: const Color(0xFFF43F5E))),
          const SizedBox(width: 10),
          Expanded(child: PowerCard(label: state.nomPneg,
              value: state.pwiT, color: const Color(0xFF22D3A8))),
        ]),
      ],
    );
  }

  Widget _buildForceWidget(EspState state, int espIdx,
      ModuleData? selected, bool multiModules) {
    return IgnorePointer(
      ignoring: multiModules && selected == null,
      child: Opacity(
        opacity: (multiModules && selected == null) ? 0.4 : 1.0,
        child: ForceWidget(
          forcage: selected?.forcage ?? 0,
          onForce: (f) => _sendForce(espIdx, f),
        ),
      ),
    );
  }

  Widget _buildStatus(EspState state) {
    final verStr = state.routerVersion != null
        ? 'v$appVersion · RMS ${state.routerVersion}'
        : 'v$appVersion';
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 6, height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: state.ok ? const Color(0xFF22D3A8) : const Color(0xFFF43F5E),
          boxShadow: state.ok ? [BoxShadow(
              color: const Color(0xFF22D3A8).withOpacity(0.6), blurRadius: 6)] : null,
        ),
      ),
      const SizedBox(width: 7),
      Flexible(child: Text(state.statusTxt, textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 11, color: Color(0xFF5A6278), fontFamily: 'monospace'))),
      const SizedBox(width: 12),
      Text(verStr,
          style: const TextStyle(
              fontSize: 11, color: Color(0xFF3A4258), fontFamily: 'monospace')),
    ]);
  }

  Widget _configButton() {
    return Container(
      decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.3), shape: BoxShape.circle),
      child: IconButton(
        onPressed: _showConfig,
        icon: const Icon(Icons.settings_outlined, color: Colors.white),
      ),
    );
  }

  // ── Build principal ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_espConfigs.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Mode page unique
    if (_displayMode == 'single') {
      return Scaffold(body: _buildSinglePageView());
    }

    // Mode multi-pages
    final multiEsp = _espConfigs.length > 1;
    return Scaffold(
      body: Stack(children: [
        PageView.builder(
          controller: _pageController,
          onPageChanged: (i) {
            setState(() => _currentPage = i);
            _startPolling(); // bascule le polling sur le nouvel ESP
          },
          itemCount: _espConfigs.length,
          itemBuilder: (ctx, idx) => _buildEspPage(ctx, idx),
        ),
        if (multiEsp)
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildDots(),
              ),
            ),
          ),
      ]),
    );
  }

  // ── Vue page unique (tous les ESP combinés) ─────────────────────────────────
  // Tableau Soutiré/Injecté pour tous les ESPs en mode page unique
  Widget _buildCombinedPowerCards() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // En-tête
        Row(children: [
          Expanded(child: Row(children: [
            Container(width: 6, height: 6,
                decoration: const BoxDecoration(shape: BoxShape.circle,
                    color: Color(0xFFF43F5E))),
            const SizedBox(width: 5),
            const Text('SOUTIRÉ', style: TextStyle(fontSize: 10,
                fontWeight: FontWeight.w600, letterSpacing: 1.4,
                color: Color(0xFF5A6278))),
          ])),
          Expanded(child: Row(children: [
            Container(width: 6, height: 6,
                decoration: const BoxDecoration(shape: BoxShape.circle,
                    color: Color(0xFF22D3A8))),
            const SizedBox(width: 5),
            const Text('INJECTÉ', style: TextStyle(fontSize: 10,
                fontWeight: FontWeight.w600, letterSpacing: 1.4,
                color: Color(0xFF5A6278))),
          ])),
        ]),
        const SizedBox(height: 8),
        // Une ligne par ESP
        for (var i = 0; i < _espConfigs.length; i++)
          if (i < _espStates.length) ...[
            if (i > 0) const SizedBox(height: 6),
            Row(children: [
              Expanded(child: _espPowerCell(
                  _espConfigs[i].name, _espStates[i].pws, const Color(0xFFF43F5E))),
              Expanded(child: _espPowerCell(
                  _espConfigs[i].name, _espStates[i].pwi, const Color(0xFF22D3A8))),
            ]),
          ],
      ]),
    );
  }

  Widget _espPowerCell(String espName, double value, Color color) {
    return Row(children: [
      Flexible(child: Text(espName,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Color(0xFF5A6278)))),
      const SizedBox(width: 4),
      Text('${value.round()} W',
          style: TextStyle(fontFamily: 'monospace', fontSize: 15,
              fontWeight: FontWeight.w500, color: color)),
    ]);
  }

  // Capteurs de température combinés pour tous les ESPs (mode page unique)
  Widget _buildCombinedTemperatures() {
    final sections = <Widget>[];

    for (var i = 0; i < _espConfigs.length; i++) {
      if (i >= _espStates.length) continue;
      final state = _espStates[i];

      final actifs = <int>[];
      for (var j = 0; j < 4; j++) {
        if (state.capteursInfo.length > j && state.capteursInfo[j].actif &&
            state.temperatures.length > j && state.temperatures[j] != null) {
          final enabled = _espConfigs[i].enabledTempIndices == null ||
              _espConfigs[i].enabledTempIndices!.contains(j);
          if (enabled) actifs.add(j);
        }
      }
      if (actifs.isEmpty) continue;

      sections.add(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sections.isNotEmpty) const SizedBox(height: 8),
          // Nom de l'ESP (si plusieurs ESPs avec capteurs)
          if (_espConfigs.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(_espConfigs[i].name.toUpperCase(),
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                      letterSpacing: 1.3, color: Color(0xFF5A6278))),
            ),
          CapteursRow(
            indices: actifs,
            infos: state.capteursInfo,
            temperatures: state.temperatures,
          ),
        ],
      ));
    }

    if (sections.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: sections);
  }

  Widget _buildSinglePageView() {
    final combined = _buildCombinedModules();
    final sel      = _getSingleSelected();
    final multiMod = combined.length > 1;
    final forcage  = sel?.module.forcage ?? 0;
    final statusOk = _espStates.any((s) => s.ok);
    final statusTxt = statusOk
        ? 'màj ${TimeOfDay.now().format(context)}'
        : 'connexion…';

    final fakeCfg = EspConfig(name: 'F1ATB Monitor', url: '', password: '');

    // Blocs partagés
    Widget gauges = combined.isEmpty
        ? const SizedBox.shrink()
        : !multiMod
        ? GaugeWidget(
      value: combined.first.ouverture ?? 0,
      hasValue: combined.first.ouverture != null,
    )
        : Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ModulesGrid(
        modules: combined,
        selectedNumAction: _singleSelectedId,
        onSelect: (id) => setState(() => _singleSelectedId = id),
      ),
    );

    Widget equiv = (!multiMod && combined.isNotEmpty && combined.first.heureEquiv != null)
        ? Text('équivalent à ${combined.first.heureEquiv} à 100%',
        style: const TextStyle(fontSize: 12, color: Color(0xFF5A6278), fontFamily: 'monospace'))
        : const SizedBox.shrink();

    Widget forceW = IgnorePointer(
      ignoring: multiMod && sel == null,
      child: Opacity(
        opacity: (multiMod && sel == null) ? 0.4 : 1.0,
        child: ForceWidget(
          forcage: forcage,
          onForce: (f) async {
            if (sel != null) {
              await _sendForceSingle(_singleSelectedId!, f);
            } else if (!multiMod && combined.isNotEmpty) {
              await _sendForceSingle(combined.first.numAction, f);
            }
          },
        ),
      ),
    );

    Widget status = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 6, height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: statusOk ? const Color(0xFF22D3A8) : const Color(0xFFF43F5E),
          boxShadow: statusOk ? [BoxShadow(
              color: const Color(0xFF22D3A8).withOpacity(0.6), blurRadius: 6)] : null,
        ),
      ),
      const SizedBox(width: 7),
      Flexible(child: Text(statusTxt,
          style: const TextStyle(fontSize: 11, color: Color(0xFF5A6278), fontFamily: 'monospace'))),
      const SizedBox(width: 12),
      const Text('v$appVersion',
          style: TextStyle(fontSize: 11, color: Color(0xFF3A4258), fontFamily: 'monospace')),
    ]);

    Widget buildPortraitSingle() => Stack(children: [
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: _buildHeader(fakeCfg, compact: true, imageHeight: 80),
          ),
        ),
        Expanded(
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 8),
                gauges,
                const SizedBox(height: 4),
                equiv,
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildCombinedTemperatures(),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _multiSites
                      ? _buildCombinedPowerCards()
                      : _buildPowerCards(_espStates.isNotEmpty ? _espStates.first : EspState()),
                ),
                const SizedBox(height: 12),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: forceW),
                const SizedBox(height: 12),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: status),
                const SizedBox(height: 16),
              ]),
            ),
          ),
        ),
      ]),
      SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 18, 36, 0),
            child: _configButton(),
          ),
        ),
      ),
    ]);

    Widget buildLandscapeSingle() => SafeArea(
      child: Stack(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Gauche : header + jauges + équivalence ──────────────────────
          Expanded(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 8),
                _buildHeader(fakeCfg, compact: true, imageHeight: 60),
                const SizedBox(height: 8),
                gauges,
                const SizedBox(height: 4),
                equiv,
                const SizedBox(height: 8),
              ]),
            ),
          ),
          Container(width: 0.5, color: Colors.white.withOpacity(0.07)),
          // ── Droite : forçage + statut ────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCombinedTemperatures(),
                  const SizedBox(height: 8),
                  _multiSites
                      ? _buildCombinedPowerCards()
                      : _buildPowerCards(_espStates.isNotEmpty ? _espStates.first : EspState()),
                  const SizedBox(height: 12),
                  forceW,
                  const SizedBox(height: 12),
                  status,
                ],
              ),
            ),
          ),
        ]),
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 8, 0),
            child: _configButton(),
          ),
        ),
      ]),
    );

    // Sélection du layout selon l'orientation
    if (_orientationMode == 'portrait')  return buildPortraitSingle();
    if (_orientationMode == 'landscape') return buildLandscapeSingle();
    return OrientationBuilder(builder: (ctx, orientation) =>
    orientation == Orientation.landscape
        ? buildLandscapeSingle()
        : buildPortraitSingle());
  }

  Widget _buildEspPage(BuildContext context, int idx) {
    if (idx >= _espStates.length) return const SizedBox();
    final cfg   = _espConfigs[idx];
    final state = _espStates[idx];

    // Filtrer les modules selon les préférences d'affichage
    final visibleModules = cfg.enabledNumActions == null
        ? state.modules
        : state.modules.where((m) => cfg.enabledNumActions!.contains(m.numAction)).toList();

    // Portrait → toujours compact (image à gauche, titre à droite)
    final multiModules  = visibleModules.length > 1;
    final capteursActifs = <int>[];
    for (var i = 0; i < 4; i++) {
      if (state.capteursInfo.length > i && state.capteursInfo[i].actif &&
          state.temperatures.length > i && state.temperatures[i] != null) {
        // Filtrer selon enabledTempIndices (null=tout, []=aucun, liste=filtrés)
        final enabled = cfg.enabledTempIndices == null ||
            cfg.enabledTempIndices!.contains(i);
        if (enabled) capteursActifs.add(i);
      }
    }
    final hasCapteurs  = capteursActifs.isNotEmpty;

    ModuleData? selected;
    if (state.selectedNumAction != null) {
      for (final m in state.modules) {
        if (m.numAction == state.selectedNumAction) { selected = m; break; }
      }
    }

    // Ajoute du padding en bas si plusieurs ESPs (pour les dots)
    final bottomPad = _espConfigs.length > 1 ? 36.0 : 0.0;

    if (_orientationMode == 'portrait') {
      return _buildPortrait(cfg: cfg, state: state, espIdx: idx,
          capteursActifs: capteursActifs, hasCapteurs: hasCapteurs,
          multiModules: multiModules, visibleModules: visibleModules,
          selected: selected, bottomPad: bottomPad);
    }
    if (_orientationMode == 'landscape') {
      return _buildLandscape(cfg: cfg, state: state, espIdx: idx,
          capteursActifs: capteursActifs, hasCapteurs: hasCapteurs,
          multiModules: multiModules, visibleModules: visibleModules,
          selected: selected, bottomPad: bottomPad);
    }
    return OrientationBuilder(builder: (ctx, orientation) {
      if (orientation == Orientation.landscape) {
        return _buildLandscape(cfg: cfg, state: state, espIdx: idx,
            capteursActifs: capteursActifs, hasCapteurs: hasCapteurs,
            multiModules: multiModules, visibleModules: visibleModules,
            selected: selected, bottomPad: bottomPad);
      }
      return _buildPortrait(cfg: cfg, state: state, espIdx: idx,
          capteursActifs: capteursActifs, hasCapteurs: hasCapteurs,
          multiModules: multiModules, visibleModules: visibleModules,
          selected: selected, bottomPad: bottomPad);
    });
  }

  Widget _buildDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _espConfigs.length; i++)
          GestureDetector(
            onTap: () => _pageController.animateToPage(i,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: i == _currentPage ? 20 : 8,
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: i == _currentPage
                    ? const Color(0xFFF97316)
                    : Colors.white.withOpacity(0.3),
              ),
            ),
          ),
      ],
    );
  }

  // ── Layout Portrait ─────────────────────────────────────────────────────────

  Widget _buildPortrait({
    required EspConfig cfg,
    required EspState state,
    required int espIdx,
    required List<int> capteursActifs,
    required bool hasCapteurs,
    required bool multiModules,
    required List<ModuleData> visibleModules,
    required ModuleData? selected,
    required double bottomPad,
  }) {
    final imageHeight = 100.0;
    return Stack(children: [
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: _buildHeader(cfg, compact: true, imageHeight: imageHeight),
          ),
        ),
        Expanded(
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 8),
                _buildGauges(state, espIdx, modules: visibleModules),
                const SizedBox(height: 4),
                _buildEquiv(state, modules: visibleModules),
                const SizedBox(height: 10),
                if (hasCapteurs) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: CapteursRow(indices: capteursActifs,
                        infos: state.capteursInfo,
                        temperatures: state.temperatures),
                  ),
                  const SizedBox(height: 10),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildPowerCards(state),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildForceWidget(state, espIdx, selected, multiModules),
                ),
                const SizedBox(height: 10),
                if (state.nomSonde2.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _buildSecondeSonde(state),
                  ),
                  const SizedBox(height: 10),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildStatus(state),
                ),
                SizedBox(height: 10 + bottomPad),
              ]),
            ),
          ),
        ),
      ]),
      SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 18, 36, 0),
            child: _configButton(),
          ),
        ),
      ),
    ]);
  }

  // ── Layout Paysage ──────────────────────────────────────────────────────────

  Widget _buildLandscape({
    required EspConfig cfg,
    required EspState state,
    required int espIdx,
    required List<int> capteursActifs,
    required bool hasCapteurs,
    required bool multiModules,
    required List<ModuleData> visibleModules,
    required ModuleData? selected,
    required double bottomPad,
  }) {
    return SafeArea(
      child: Stack(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 8),
                _buildHeader(cfg, compact: true, imageHeight: 60),
                const SizedBox(height: 8),
                _buildGauges(state, espIdx, modules: visibleModules),
                const SizedBox(height: 4),
                _buildEquiv(state, modules: visibleModules),
                SizedBox(height: 8 + bottomPad),
              ]),
            ),
          ),
          Container(width: 0.5, color: Colors.white.withOpacity(0.07)),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasCapteurs) ...[
                    CapteursRow(indices: capteursActifs,
                        infos: state.capteursInfo,
                        temperatures: state.temperatures),
                    const SizedBox(height: 10),
                  ],
                  _buildPowerCards(state),
                  const SizedBox(height: 12),
                  _buildForceWidget(state, espIdx, selected, multiModules),
                  const SizedBox(height: 10),
                  if (state.nomSonde2.isNotEmpty) ...[
                    _buildSecondeSonde(state),
                    const SizedBox(height: 10),
                  ],
                  _buildStatus(state),
                ],
              ),
            ),
          ),
        ]),
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 8, 0),
            child: _configButton(),
          ),
        ),
      ]),
    );
  }
}

// ── Jauge circulaire ───────────────────────────────────────────────────────────
class GaugeWidget extends StatelessWidget {
  final double value;
  final bool hasValue;
  final double size;
  final double valueFontSize;
  final bool showLabel;
  const GaugeWidget({
    super.key,
    required this.value,
    required this.hasValue,
    this.size = 190,
    this.valueFontSize = 46,
    this.showLabel = true,
  });

  // Dégradé rouge (0%, fermé) → orange → jaune → vert (100%, ouvert)
  static const List<Color> _gaugeColors = [
    Color(0xFFEF4444), // rouge
    Color(0xFFF97316), // orange
    Color(0xFFFACC15), // jaune
    Color(0xFF22C55E), // vert
  ];

  Color _colorAt(double t) {
    final clamped = t.clamp(0.0, 1.0);
    final scaled = clamped * (_gaugeColors.length - 1);
    final i = scaled.floor().clamp(0, _gaugeColors.length - 2);
    final localT = scaled - i;
    return Color.lerp(_gaugeColors[i], _gaugeColors[i + 1], localT)!;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size, height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: hasValue ? value / 100 : 0),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOut,
            builder: (_, v, __) => CustomPaint(
              size: Size(size, size),
              painter: _GaugePainter(v, _gaugeColors, _colorAt(v), strokeWidth: size / 13.6),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                hasValue ? '${value.round()}' : '--',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: valueFontSize,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFE8EAF0),
                  height: 1,
                ),
              ),
              if (showLabel)
                const Text(
                  'ouverture %',
                  style: TextStyle(fontSize: 12, color: Color(0xFF5A6278), fontFamily: 'monospace'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double progress; // 0..1
  final List<Color> gaugeColors;
  final Color cursorColor;
  final double strokeWidth;
  const _GaugePainter(this.progress, this.gaugeColors, this.cursorColor, {this.strokeWidth = 14});

  // Arc de 270°, gap de 90° en bas : démarre à -135° (bas-gauche),
  // remonte par la gauche, passe par le haut, redescend à droite
  // jusqu'à +135° (bas-droite). Angles en radians, 0 = droite, sens horaire.
  // SweepGradient exige 0 ≤ startAngle ≤ endAngle ≤ 2π, donc on décale
  // tout le repère de +135° pour rester dans cette plage.
  static const double _angleOffset = 0.75 * pi; // 135°, position de départ réelle
  static const double _startAngle = 0.0;
  static const double _sweepAngle = 1.5 * pi;  // 270°

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - strokeWidth;
    final rect = Rect.fromCircle(center: c, radius: r);

    // Arc en dégradé conique rouge → orange → jaune → vert, limité à 270°
    // Le shader est calculé sur [0, 270°] puis pivoté de +135° via GradientRotation
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: _startAngle,
        endAngle: _startAngle + _sweepAngle,
        transform: GradientRotation(_angleOffset),
        colors: gaugeColors,
        stops: const [0.0, 0.33, 0.66, 1.0],
      ).createShader(rect);

    // StrokeCap.round ajoute un demi-disque de rayon strokeWidth/2 à chaque
    // extrémité du trait. On réduit donc le sweep dessiné de cette quantité
    // (convertie en angle) de part et d'autre pour que le rendu final
    // s'arrête pile aux bornes voulues, sans déborder.
    final capAngle = asin((strokeWidth / 2) / r);
    final drawStart = _angleOffset + capAngle;
    final drawSweep = _sweepAngle - 2 * capAngle;

    canvas.drawArc(rect, drawStart, drawSweep, false, ringPaint);

    // Curseur : pastille blanche + point coloré à la position actuelle
    final cursorAngle = _angleOffset + _sweepAngle * progress;
    final cursorCenter = Offset(
      c.dx + r * cos(cursorAngle),
      c.dy + r * sin(cursorAngle),
    );

    final haloPaint = Paint()..color = Colors.white;
    canvas.drawCircle(cursorCenter, strokeWidth * 0.65, haloPaint);

    final dotPaint = Paint()..color = cursorColor;
    canvas.drawCircle(cursorCenter, strokeWidth * 0.42, dotPaint);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.progress != progress || old.cursorColor != cursorColor || old.strokeWidth != strokeWidth;
}

// ── Card puissance ─────────────────────────────────────────────────────────────
// ── Grille de jauges multi-modules (relais SSR) ────────────────────────────────
class ModulesGrid extends StatelessWidget {
  final List<ModuleData> modules;
  final int? selectedNumAction;
  final void Function(int) onSelect;
  const ModulesGrid({
    super.key,
    required this.modules,
    required this.selectedNumAction,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Répartition :
    //   2 modules → 2/ligne
    //   3 modules → 3/ligne (tout sur une ligne)
    //   4 modules → 2x2
    //   5-9 modules → 3/ligne
    final perRow = (modules.length == 2 || modules.length == 4) ? 2 : 3;

    // Taille jauge selon la densité
    final gaugeSize = perRow == 2 ? 138.0 : 95.0;

    // Construction des lignes avec remplissage null pour la dernière ligne incomplète
    final rows = <List<ModuleData?>>[];
    for (var i = 0; i < modules.length; i += perRow) {
      final row = <ModuleData?>[];
      for (var j = i; j < i + perRow; j++) {
        row.add(j < modules.length ? modules[j] : null);
      }
      rows.add(row);
    }

    return Column(
      children: [
        for (final row in rows) ...[
          Row(
            // Expanded garantit que chaque cellule prend exactement 1/perRow de la largeur
            // → centrage parfait quelle que soit la taille de la jauge
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final m in row)
                Expanded(
                  child: m != null
                      ? _ModuleGaugeTile(
                    module: m,
                    selected: m.numAction == selectedNumAction,
                    onTap: () => onSelect(m.numAction),
                    size: gaugeSize,
                  )
                      : const SizedBox(), // cellule vide pour compléter la dernière ligne
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }
}

class _ModuleGaugeTile extends StatelessWidget {
  final ModuleData module;
  final bool selected;
  final VoidCallback onTap;
  final double size;
  const _ModuleGaugeTile({
    required this.module,
    required this.selected,
    required this.onTap,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? const Color(0xFF3B82F6) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GaugeWidget(
              value: module.ouverture ?? 0,
              hasValue: module.ouverture != null,
              size: size,
              valueFontSize: size / 4.2,
              showLabel: false,
            ),
            const SizedBox(height: 2),
            // Nom du module
            Text(
              module.nom,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: size > 120 ? 11 : 9,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF5A6278),
              ),
            ),
            // Équivalence heure (si disponible)
            if (module.heureEquiv != null) ...[
              const SizedBox(height: 1),
              Text(
                '≡ ${module.heureEquiv}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: size > 120 ? 10 : 8,
                  fontFamily: 'monospace',
                  color: const Color(0xFF3A4258),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Rangée de capteurs température ─────────────────────────────────────────────
class CapteursRow extends StatelessWidget {
  final List<int> indices;       // index (0-3) des capteurs actifs, dans l'ordre
  final List<CapteurInfo> infos; // noms + activation, taille 4
  final List<double?> temperatures; // valeurs, taille 4
  const CapteursRow({
    super.key,
    required this.indices,
    required this.infos,
    required this.temperatures,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < indices.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _CapteurBox(
            nom: infos[indices[i]].nom,
            temp: temperatures[indices[i]]!,
          )),
        ],
      ],
    );
  }
}

class _CapteurBox extends StatelessWidget {
  final String nom;
  final double temp;
  const _CapteurBox({required this.nom, required this.temp});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            nom,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500,
              color: Color(0xFF5A6278), height: 1.15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${temp.round()}°C', // jusqu'à 3 digits (ex: 100°C) sans débordement
            style: const TextStyle(
              fontFamily: 'monospace', fontSize: 17, fontWeight: FontWeight.w500,
              color: Color(0xFFE8EAF0), height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class PowerCard extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  const PowerCard({super.key, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 6, height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
              const SizedBox(width: 5),
              Text(label.toUpperCase(),
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                      letterSpacing: 1.4, color: Color(0xFF5A6278))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${value.round()}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 30,
                      fontWeight: FontWeight.w500, color: color, height: 1)),
              const SizedBox(width: 4),
              const Text('W',
                  style: TextStyle(fontSize: 11, color: Color(0xFF5A6278), fontFamily: 'monospace')),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Feuille de config ──────────────────────────────────────────────────────────
// ── Widget forçage ─────────────────────────────────────────────────────────────
class ForceWidget extends StatelessWidget {
  final int forcage;
  final Future<void> Function(int) onForce;
  const ForceWidget({super.key, required this.forcage, required this.onForce});

  @override
  Widget build(BuildContext context) {
    final isOn  = forcage > 0;
    final isOff = forcage < 0;
    final mins  = forcage.abs();

    // Couleurs selon l'état
    final Color bgColor    = isOn  ? const Color(0xFF14532D)
        : isOff ? const Color(0xFF450A0A)
        : const Color(0xFF111827);
    final Color borderColor = isOn  ? const Color(0xFF22C55E)
        : isOff ? const Color(0xFFF43F5E)
        : Colors.white.withOpacity(0.08);
    final Color labelColor  = isOn  ? const Color(0xFF22C55E)
        : isOff ? const Color(0xFFF43F5E)
        : const Color(0xFF5A6278);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor, width: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          // Label + temps restant
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FORÇAGE',
                  style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w600,
                    letterSpacing: 1.4, color: labelColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isOn  ? '$mins min' :
                  isOff ? '$mins min' : 'Auto',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: isOn || isOff ? 22 : 14,
                    fontWeight: FontWeight.w500,
                    color: labelColor,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Boutons
          if (!isOn && !isOff) ...[
            _ForceBtn(
              label: 'On +30',
              color: const Color(0xFF22C55E),
              bg: const Color(0xFF14532D),
              onTap: () => onForce(1),
            ),
            const SizedBox(width: 8),
            _ForceBtn(
              label: 'Off +30',
              color: const Color(0xFFF43F5E),
              bg: const Color(0xFF450A0A),
              onTap: () => onForce(-1),
            ),
          ] else if (isOn) ...[
            _ForceBtn(
              label: '+30 min',
              color: const Color(0xFF22C55E),
              bg: const Color(0xFF166534),
              onTap: () => onForce(1),  // +30 min supplémentaires
            ),
            const SizedBox(width: 8),
            _ForceBtn(
              label: 'Annuler',
              color: const Color(0xFF5A6278),
              bg: const Color(0xFF1F2937),
              onTap: () => onForce(-1), // opposé → repasse en auto
            ),
          ] else ...[
            _ForceBtn(
              label: '+30 min',
              color: const Color(0xFFF43F5E),
              bg: const Color(0xFF7F1D1D),
              onTap: () => onForce(-1), // +30 min supplémentaires
            ),
            const SizedBox(width: 8),
            _ForceBtn(
              label: 'Annuler',
              color: const Color(0xFF5A6278),
              bg: const Color(0xFF1F2937),
              onTap: () => onForce(1),  // opposé → repasse en auto
            ),
          ],
        ],
      ),
    );
  }
}

class _ForceBtn extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  final VoidCallback onTap;
  const _ForceBtn({required this.label, required this.color, required this.bg, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: color.withOpacity(0.6), width: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: color,
          ),
        ),
      ),
    );
  }
}

// ── Feuille de config ──────────────────────────────────────────────────────────


// ── Choix d'un module (pour les checkboxes dans config) ───────────────────────
class _ModuleChoice {
  final int numAction;
  final String nom;
  bool enabled;
  _ModuleChoice({required this.numAction, required this.nom, required this.enabled});
}

class _TempChoice {
  final int index;    // 0-3
  final String nom;
  bool enabled;
  _TempChoice({required this.index, required this.nom, required this.enabled});
}

// ── Feuille de config multi-ESP ────────────────────────────────────────────────
class ConfigSheet extends StatefulWidget {
  final List<EspConfig> currentConfigs;
  final String currentOrientation;
  final String currentDisplayMode;
  final bool   currentMultiSites;
  final Future<void> Function(List<EspConfig>, String, String, bool) onSave;
  const ConfigSheet({
    super.key,
    required this.currentConfigs,
    required this.currentOrientation,
    required this.currentDisplayMode,
    required this.currentMultiSites,
    required this.onSave,
  });

  @override
  State<ConfigSheet> createState() => _ConfigSheetState();
}

class _ConfigSheetState extends State<ConfigSheet> {
  late List<Map<String, TextEditingController>> _ctrls;
  late String _orientation;
  late String _displayMode;
  late bool   _multiSites;
  late int _count;

  // État du test de connexion par ESP
  late List<List<_ModuleChoice>?> _testedModules; // null=non testé, []= échec
  late List<List<_TempChoice>?>   _testedTemps;   // null=non testé, []= aucun capteur
  late List<bool> _testing;

  @override
  void initState() {
    super.initState();
    _orientation = widget.currentOrientation;
    _displayMode = widget.currentDisplayMode;
    _multiSites  = widget.currentMultiSites;
    _count = widget.currentConfigs.length;
    _ctrls = widget.currentConfigs.map((c) => {
      'name': TextEditingController(text: c.name),
      'url':  TextEditingController(text: c.url),
      'pwd':  TextEditingController(text: c.password),
    }).toList();
    _testedModules = List.generate(_count, (_) => null);
    _testedTemps   = List.generate(_count, (_) => null);
    _testing       = List.generate(_count, (_) => false);

    // Auto-test au chargement pour les ESPs déjà configurés (URL présente)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (var i = 0; i < _ctrls.length; i++) {
        if (_ctrls[i]['url']!.text.isNotEmpty) {
          _testConnection(i);
        }
      }
    });
  }

  @override
  void dispose() {
    for (final m in _ctrls) {
      m['name']!.dispose();
      m['url']!.dispose();
      m['pwd']!.dispose();
    }
    super.dispose();
  }

  void _addEsp() {
    if (_count >= 9) return;
    setState(() {
      _count++;
      _ctrls.add({
        'name': TextEditingController(text: 'ESP $_count'),
        'url':  TextEditingController(),
        'pwd':  TextEditingController(),
      });
      _testedModules.add(null);
      _testedTemps.add(null);
      _testing.add(false);
    });
  }

  void _removeEsp() {
    if (_count <= 1) return;
    setState(() {
      final last = _ctrls.removeLast();
      last.values.forEach((c) => c.dispose());
      _testedModules.removeLast();
      _testedTemps.removeLast();
      _testing.removeLast();
      _count--;
    });
  }

  Future<void> _testConnection(int idx) async {
    var url = _ctrls[idx]['url']!.text.trim().replaceAll(RegExp(r'/$'), '');
    if (url.isEmpty) return;
    if (!url.startsWith('http')) url = 'http://$url';
    final pwd    = _ctrls[idx]['pwd']!.text.trim();
    final cookie = pwd.isNotEmpty ? 'CleAcces=$pwd' : null;

    setState(() => _testing[idx] = true);
    try {
      // Fetch jauges ET capteurs en parallèle
      final results = await Future.wait([
        simpleGet('$url/ajax_etatActions?Force=0&NumAction=0', cookie: cookie),
        simpleGet('$url/ParaFixe', cookie: cookie),
      ]).timeout(const Duration(seconds: 8));

      final modules  = parseActionneurs(results[0]);
      final capteurs = parseCapteursInfo(results[1]);

      final existingEnabled = idx < widget.currentConfigs.length
          ? widget.currentConfigs[idx].enabledNumActions
          : null;
      final existingTemps = idx < widget.currentConfigs.length
          ? widget.currentConfigs[idx].enabledTempIndices
          : null;

      // Capteurs actifs uniquement
      final tempChoices = <_TempChoice>[];
      for (var j = 0; j < capteurs.length; j++) {
        if (capteurs[j].actif) {
          tempChoices.add(_TempChoice(
            index:   j,
            nom:     capteurs[j].nom,
            enabled: existingTemps == null || existingTemps.contains(j),
          ));
        }
      }

      setState(() {
        _testedModules[idx] = modules.map((m) => _ModuleChoice(
          numAction: m.numAction,
          nom:       m.nom,
          enabled:   existingEnabled == null || existingEnabled.contains(m.numAction),
        )).toList();
        _testedTemps[idx] = tempChoices;
        _testing[idx] = false;
      });
    } catch (_) {
      setState(() {
        _testedModules[idx] = [];
        _testedTemps[idx]   = [];
        _testing[idx]       = false;
      });
    }
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFF5A6278)),
    filled: true,
    fillColor: const Color(0xFF0A0F1A),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFFF97316)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Titre + compteur ESP ─────────────────────────────────────────
            Row(children: [
              const Expanded(
                child: Text('Configuration',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        letterSpacing: 2.5, color: Color(0xFF5A6278))),
              ),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0F1A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _stepBtn('−', _count > 1, _removeEsp),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('$_count ESP',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: Color(0xFFE8EAF0))),
                  ),
                  _stepBtn('+', _count < 9, _addEsp),
                ]),
              ),
            ]),
            const SizedBox(height: 16),

            // ── Groupes par ESP ──────────────────────────────────────────────
            for (var i = 0; i < _ctrls.length; i++) ...[
              if (_ctrls.length > 1)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('ESP ${i + 1}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 1.5, color: Color(0xFF5A6278))),
                ),
              // Nom
              const Text('Nom', style: TextStyle(fontSize: 12, color: Color(0xFF5A6278))),
              const SizedBox(height: 4),
              TextField(
                controller: _ctrls[i]['name'],
                style: const TextStyle(fontSize: 14, color: Color(0xFFE8EAF0)),
                decoration: _inputDeco('Mon Routeur Solaire'),
              ),
              const SizedBox(height: 8),
              // URL
              const Text('URL', style: TextStyle(fontSize: 12, color: Color(0xFF5A6278))),
              const SizedBox(height: 4),
              TextField(
                controller: _ctrls[i]['url'],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13,
                    color: Color(0xFFE8EAF0)),
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: _inputDeco('http://192.168.1.X:PORT'),
              ),
              const SizedBox(height: 8),
              // Mot de passe
              const Text('Mot de passe (optionnel)',
                  style: TextStyle(fontSize: 12, color: Color(0xFF5A6278))),
              const SizedBox(height: 4),
              TextField(
                controller: _ctrls[i]['pwd'],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13,
                    color: Color(0xFFE8EAF0)),
                obscureText: true,
                autocorrect: false,
                decoration: _inputDeco('Laisser vide si aucun'),
              ),
              const SizedBox(height: 10),

              // ── Bouton Test ────────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _testing[i] ? null : () => _testConnection(i),
                  icon: _testing[i]
                      ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFFF97316)))
                      : const Icon(Icons.wifi_find_outlined,
                      size: 16, color: Color(0xFFF97316)),
                  label: Text(
                    _testing[i] ? 'Test en cours…' : 'Tester la connexion',
                    style: const TextStyle(fontSize: 13, color: Color(0xFFF97316)),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFF97316), width: 0.5),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),

              // ── Résultat du test ───────────────────────────────────────────
              if (_testedModules[i] != null) ...[
                const SizedBox(height: 8),
                if (_testedModules[i]!.isEmpty)
                // Échec
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF450A0A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF43F5E).withOpacity(0.4)),
                    ),
                    child: const Row(children: [
                      Icon(Icons.error_outline, size: 14, color: Color(0xFFF43F5E)),
                      SizedBox(width: 6),
                      Text('Connexion échouée',
                          style: TextStyle(fontSize: 12, color: Color(0xFFF43F5E))),
                    ]),
                  )
                else ...[
                  // Succès + checkboxes
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF14532D),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF22C55E).withOpacity(0.4)),
                    ),
                    child: const Row(children: [
                      Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF22C55E)),
                      SizedBox(width: 6),
                      Text('Connexion OK — choisir les jauges à afficher :',
                          style: TextStyle(fontSize: 12, color: Color(0xFF22C55E))),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  for (final m in _testedModules[i]!)
                    CheckboxListTile(
                      value: m.enabled,
                      onChanged: (v) => setState(() => m.enabled = v!),
                      title: Text(m.nom,
                          style: const TextStyle(fontSize: 13, color: Color(0xFFE8EAF0))),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: const Color(0xFFF97316),
                      side: BorderSide(color: Colors.white.withOpacity(0.3)),
                      contentPadding: EdgeInsets.zero,
                    ),
                  // ── Capteurs de température ──────────────────────────────
                  if (_testedTemps[i] != null && _testedTemps[i]!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('Capteurs de température',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                            letterSpacing: 1.2, color: Color(0xFF5A6278))),
                    for (final t in _testedTemps[i]!)
                      CheckboxListTile(
                        value: t.enabled,
                        onChanged: (v) => setState(() => t.enabled = v!),
                        title: Text(t.nom,
                            style: const TextStyle(fontSize: 13, color: Color(0xFFE8EAF0))),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: const Color(0xFFF97316),
                        side: BorderSide(color: Colors.white.withOpacity(0.3)),
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ],
              ],
              const SizedBox(height: 16),
              if (i < _ctrls.length - 1)
                Divider(color: Colors.white.withOpacity(0.07), height: 1),
              const SizedBox(height: 16),
            ],

            // ── Affichage (uniquement si plusieurs ESP) ──────────────────────
            if (_count > 1) ...[
              const Text('Affichage',
                  style: TextStyle(fontSize: 12, color: Color(0xFF5A6278))),
              const SizedBox(height: 8),
              _DisplayModeToggle(
                value: _displayMode,
                onChanged: (v) => setState(() => _displayMode = v),
              ),
              const SizedBox(height: 12),
            ],

            // ── Multisites (uniquement si plusieurs ESP en page unique) ──────
            if (_count > 1 && _displayMode == 'single') ...[
              CheckboxListTile(
                value: _multiSites,
                onChanged: (v) => setState(() => _multiSites = v!),
                title: const Text('Multisites',
                    style: TextStyle(fontSize: 13, color: Color(0xFFE8EAF0))),
                subtitle: const Text(
                    'Affiche le Soutiré/Injecté de chaque ESP séparément',
                    style: TextStyle(fontSize: 11, color: Color(0xFF5A6278))),
                activeColor: const Color(0xFFF97316),
                side: BorderSide(color: Colors.white.withOpacity(0.3)),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              const SizedBox(height: 8),
            ],

            // ── Orientation ──────────────────────────────────────────────────
            const Text('Orientation',
                style: TextStyle(fontSize: 12, color: Color(0xFF5A6278))),
            const SizedBox(height: 8),
            _OrientationToggle(
              value: _orientation,
              onChanged: (v) => setState(() => _orientation = v),
            ),
            const SizedBox(height: 20),

            // ── Bouton Valider ───────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final configs = _ctrls.asMap().entries.map((entry) {
                    final i   = entry.key;
                    final m   = entry.value;
                    var url   = m['url']!.text.trim().replaceAll(RegExp(r'/$'), '');
                    if (url.isNotEmpty && !url.startsWith('http')) url = 'http://$url';
                    // Détermine les modules activés
                    List<int>? enabled;
                    final tested = _testedModules[i];
                    if (tested != null && tested.isNotEmpty) {
                      // Test réussi → utilise les checkboxes (peut être [] si tout décoché)
                      enabled = tested.where((m) => m.enabled)
                          .map((m) => m.numAction).toList();
                    } else if (tested != null && tested.isEmpty) {
                      // Test échoué → conserve l'existant
                      enabled = i < widget.currentConfigs.length
                          ? widget.currentConfigs[i].enabledNumActions
                          : null;
                    } else {
                      // Non testé → conserve l'existant (null=tout afficher)
                      enabled = i < widget.currentConfigs.length
                          ? widget.currentConfigs[i].enabledNumActions
                          : null;
                    }
                    // Détermine les capteurs température activés
                    List<int>? enabledTemps;
                    final testedT = _testedTemps[i];
                    if (testedT != null && testedT.isNotEmpty) {
                      enabledTemps = testedT.where((t) => t.enabled)
                          .map((t) => t.index).toList();
                    } else if (testedT != null && testedT.isEmpty) {
                      enabledTemps = i < widget.currentConfigs.length
                          ? widget.currentConfigs[i].enabledTempIndices
                          : null;
                    } else {
                      enabledTemps = i < widget.currentConfigs.length
                          ? widget.currentConfigs[i].enabledTempIndices
                          : null;
                    }
                    return EspConfig(
                      name: m['name']!.text.trim().isEmpty
                          ? 'ESP ${i + 1}' : m['name']!.text.trim(),
                      url: url,
                      password: m['pwd']!.text.trim(),
                      enabledNumActions:  enabled,
                      enabledTempIndices: enabledTemps,
                    );
                  }).toList();
                  await widget.onSave(configs, _orientation, _displayMode, _multiSites);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF97316),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Valider',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepBtn(String label, bool enabled, VoidCallback onTap) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 36, height: 36,
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600,
                color: enabled ? const Color(0xFFE8EAF0) : const Color(0xFF3A4258))),
      ),
    );
  }
}

// ── Toggle 2 positions pour le mode d'affichage ───────────────────────────────
class _DisplayModeToggle extends StatelessWidget {
  final String value; // 'multi' | 'single'
  final void Function(String) onChanged;
  const _DisplayModeToggle({required this.value, required this.onChanged});

  static const _options = [
    ('multi',  '⧉ Multipages'),
    ('single', '▣ Page unique'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(children: [
        for (var i = 0; i < _options.length; i++) ...[
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(_options[i].$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: value == _options[i].$1
                      ? const Color(0xFFF97316) : Colors.transparent,
                  borderRadius: BorderRadius.horizontal(
                    left:  i == 0 ? const Radius.circular(11) : Radius.zero,
                    right: i == _options.length - 1
                        ? const Radius.circular(11) : Radius.zero,
                  ),
                ),
                child: Text(_options[i].$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: value == _options[i].$1
                          ? Colors.white : const Color(0xFF5A6278)),
                ),
              ),
            ),
          ),
          if (i < _options.length - 1)
            Container(width: 0.5, height: 36, color: Colors.white.withOpacity(0.08)),
        ],
      ]),
    );
  }
}

// ── Toggle 3 positions pour l'orientation ──────────────────────────────────────
class _OrientationToggle extends StatelessWidget {
  final String value;
  final void Function(String) onChanged;
  const _OrientationToggle({required this.value, required this.onChanged});

  static const _options = [
    ('portrait',  '⬆ Portrait'),
    ('auto',      '⟳ Auto'),
    ('landscape', '⮕ Paysage'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(children: [
        for (var i = 0; i < _options.length; i++) ...[
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(_options[i].$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: value == _options[i].$1
                      ? const Color(0xFFF97316) : Colors.transparent,
                  borderRadius: BorderRadius.horizontal(
                    left:  i == 0 ? const Radius.circular(11) : Radius.zero,
                    right: i == _options.length - 1
                        ? const Radius.circular(11) : Radius.zero,
                  ),
                ),
                child: Text(_options[i].$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: value == _options[i].$1
                          ? Colors.white : const Color(0xFF5A6278)),
                ),
              ),
            ),
          ),
          if (i < _options.length - 1)
            Container(width: 0.5, height: 36,
                color: Colors.white.withOpacity(0.08)),
        ],
      ]),
    );
  }
}
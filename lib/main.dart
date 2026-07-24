import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
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
const String appVersion = '4.0.27';
const String RS = '\x1e'; // Record Separator

// Couleur des textes secondaires (labels, statuts) — modifiable par l'utilisateur
Color appLabelColor = const Color(0xFF5A6278);

// Presets couleur des labels secondaires (partagés avec ConfigSheet)
const List<(Color, String)> kLabelColorPresets = [
  (Color(0xFF5A6278), 'Défaut'),
  (Color(0xFF8A9BB8), 'Clair'),
  (Color(0xFFB8C5D4), 'Très clair'),
  (Color(0xFFE8EAF0), 'Lumineux'),
  (Color(0xFFFFFFFF), 'Blanc'),
  (Color(0xFFF97316), 'Orange'),
];

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
  final double pwsT;   // puissance soutiree sonde fixe (Triac)
  final double pwiT;   // puissance injectee sonde fixe (Triac)
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
  bool   _multiSites      = false;
  Color  _uiLabelColor    = const Color(0xFF5A6278); // couleur des textes secondaires   // false=site unique, true=multisites
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
        final colorVal = data['text_color'] as int?;
        if (colorVal != null) { _uiLabelColor = Color(colorVal); appLabelColor = Color(colorVal); }
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
      String displayMode, bool multiSites, Color labelColor) async {
    _displayMode    = displayMode;
    _multiSites     = multiSites;
    _uiLabelColor   = labelColor;
    appLabelColor   = labelColor;
    // ── Sauvegarde dans un fichier JSON (synchrone = garanti sur disque) ───
    try {
      final file    = await _configFile;
      final content = jsonEncode({
        'orientation':  orientation,
        'display_mode': _displayMode,
        'multi_sites':  _multiSites,
        'text_color':   _uiLabelColor.value,
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
        nomPpos   = (data['nomSfixePpos']  ?? '').toString();
        nomPneg   = (data['nomSfixePneg']  ?? '').toString();
        // Source sans sonde fixe → pas de 2e sonde
        final source = (data['Source'] ?? '').toString();
        if (source == 'Ext' || source == 'ShellyPro') nomSonde2 = '';
        // Si les deux labels pos et neg sont vides → pas de 2e sonde non plus
        if (nomPpos.isEmpty && nomPneg.isEmpty) nomSonde2 = '';
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
      final alreadySelected = _espStates[espIdx].selectedNumAction == numAction;
      _espStates[espIdx] = alreadySelected
          ? _espStates[espIdx].copyWith(clearSelected: true)
          : _espStates[espIdx].copyWith(selectedNumAction: numAction);
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
        currentLabelColor:  _uiLabelColor,
        onSave: (configs, orientation, displayMode, multiSites, labelColor) async {
          await _saveConfig(configs, orientation, displayMode, multiSites, labelColor);
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
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      letterSpacing: 1.5, color: appLabelColor)),
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
        style: TextStyle(fontSize: 12, color: appLabelColor, fontFamily: 'monospace'),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildPowerCards(EspState state) {
    return Row(children: [
      Expanded(child: PowerCard(label: 'Soutiré', value: state.pws,
          color: const Color(0xFFF43F5E), labelColor: appLabelColor)),
      const SizedBox(width: 10),
      Expanded(child: PowerCard(label: 'Injecté', value: state.pwi,
          color: const Color(0xFF22D3A8), labelColor: appLabelColor)),
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
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                    letterSpacing: 1.4, color: appLabelColor)),
          ),
          Expanded(child: Divider(color: Colors.white.withOpacity(0.07), height: 1)),
        ]),
        const SizedBox(height: 10),
        // Cards : uniquement si le label correspondant est renseigné
        if (state.nomPpos.isNotEmpty || state.nomPneg.isNotEmpty)
          Row(children: [
            if (state.nomPpos.isNotEmpty)
              Expanded(child: PowerCard(label: state.nomPpos,
                  value: state.pwsT, color: const Color(0xFFF43F5E))),
            if (state.nomPpos.isNotEmpty && state.nomPneg.isNotEmpty)
              const SizedBox(width: 10),
            if (state.nomPneg.isNotEmpty)
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
          style: TextStyle(
              fontSize: 11, color: appLabelColor, fontFamily: 'monospace'))),
      const SizedBox(width: 12),
      Text(verStr,
          style: TextStyle(
              fontSize: 11, color: appLabelColor.withOpacity(0.6), fontFamily: 'monospace')),
    ]);
  }

  Widget _chartButton(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.3), shape: BoxShape.circle),
      child: IconButton(
        onPressed: () {
          if (_displayMode == 'single' && _espConfigs.length > 1) {
            _openChartsWithPicker(context);
          } else {
            _openCharts(context, _currentPage);
          }
        },
        icon: const _ChartIcon(),
        tooltip: 'Graphiques',
      ),
    );
  }

  // Colonne boutons droite : ⚙ au-dessus, icône chart en-dessous
  Widget _actionButtons(BuildContext context,
      {double top = 18, double right = 36}) {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, top, right, 0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _configButton(),
          const SizedBox(height: 6),
          _chartButton(context),
        ]),
      ),
    );
  }

  void _openCharts(BuildContext context, int espIdx) {
    if (espIdx >= _espConfigs.length) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ChartsPage(
        config:       _espConfigs[espIdx],
        title:        _espConfigs[espIdx].name,
        initialState: espIdx < _espStates.length ? _espStates[espIdx] : null,
      ),
    ));
  }

  void _openChartsWithPicker(BuildContext context) {
    if (_espConfigs.length == 1) { _openCharts(context, 0); return; }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text('Graphiques de quel ESP ?',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    letterSpacing: 2, color: appLabelColor)),
          ),
          for (var i = 0; i < _espConfigs.length; i++)
            ListTile(
              title: Text(_espConfigs[i].name,
                  style: const TextStyle(color: Color(0xFFE8EAF0))),
              leading: const Icon(Icons.show_chart, color: Color(0xFFF97316)),
              onTap: () { Navigator.pop(context); _openCharts(context, i); },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
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
            Text('SOUTIRÉ', style: TextStyle(fontSize: 10,
                fontWeight: FontWeight.w600, letterSpacing: 1.4,
                color: appLabelColor)),
          ])),
          Expanded(child: Row(children: [
            Container(width: 6, height: 6,
                decoration: const BoxDecoration(shape: BoxShape.circle,
                    color: Color(0xFF22D3A8))),
            const SizedBox(width: 5),
            Text('INJECTÉ', style: TextStyle(fontSize: 10,
                fontWeight: FontWeight.w600, letterSpacing: 1.4,
                color: appLabelColor)),
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
          style: TextStyle(fontSize: 10, color: appLabelColor))),
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
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                      letterSpacing: 1.3, color: appLabelColor)),
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
        onSelect: (id) => setState(() =>
        _singleSelectedId = _singleSelectedId == id ? null : id),
      ),
    );

    Widget equiv = (!multiMod && combined.isNotEmpty && combined.first.heureEquiv != null)
        ? Text('équivalent à ${combined.first.heureEquiv} à 100%',
        style: TextStyle(fontSize: 12, color: appLabelColor, fontFamily: 'monospace'))
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
          style: TextStyle(fontSize: 11, color: appLabelColor, fontFamily: 'monospace'))),
      const SizedBox(width: 12),
      Text('v$appVersion',
          style: TextStyle(fontSize: 11, color: appLabelColor.withOpacity(0.7), fontFamily: 'monospace')),
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
        child: _actionButtons(context, top: 18, right: 36),
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
        _actionButtons(context, top: 4, right: 8),
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
        child: _actionButtons(context, top: 18, right: 36),
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
        _actionButtons(context, top: 4, right: 8),
      ]),
    );
  }
}

// ── Icône graphique custom ─────────────────────────────────────────────────────
class _ChartIcon extends StatelessWidget {
  const _ChartIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(22, 22),
      painter: _ChartIconPainter(),
    );
  }
}

class _ChartIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    final w = size.width, h = size.height;

    // Axes
    final axesPaint = Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, h), Offset(w, h), axesPaint); // X
    canvas.drawLine(Offset(0, 0), Offset(0, h), axesPaint); // Y

    // Courbe sinusoïdale stylisée
    final path = Path();
    final pts = [
      Offset(0,        h * 0.75),
      Offset(w * 0.15, h * 0.70),
      Offset(w * 0.30, h * 0.55),
      Offset(w * 0.45, h * 0.35),
      Offset(w * 0.60, h * 0.20),
      Offset(w * 0.75, h * 0.30),
      Offset(w * 0.90, h * 0.18),
      Offset(w,        h * 0.10),
    ];
    path.moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final cp = Offset((pts[i].dx + pts[i+1].dx) / 2,
          (pts[i].dy + pts[i+1].dy) / 2);
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, cp.dx, cp.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    canvas.drawPath(path, paint);

    // Point final (valeur actuelle)
    canvas.drawCircle(pts.last, 2.2,
        Paint()..color = const Color(0xFFF97316)..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_) => false;
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
                Text(
                  'ouverture %',
                  style: TextStyle(fontSize: 12, color: appLabelColor, fontFamily: 'monospace'),
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
                color: appLabelColor,
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
                  color: appLabelColor.withOpacity(0.7),
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
            style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500,
              color: appLabelColor, height: 1.15,
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
  final Color  color;
  final Color  labelColor;
  const PowerCard({super.key, required this.label, required this.value,
    required this.color, this.labelColor = const Color(0xFF5A6278)});

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
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                      letterSpacing: 1.4, color: labelColor)),
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
              Text('W',
                  style: TextStyle(fontSize: 11, color: labelColor, fontFamily: 'monospace')),
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
        : appLabelColor;

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
              color: appLabelColor,
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
              color: appLabelColor,
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
  final Color  currentLabelColor;
  final Future<void> Function(List<EspConfig>, String, String, bool, Color) onSave;
  const ConfigSheet({
    super.key,
    required this.currentConfigs,
    required this.currentOrientation,
    required this.currentDisplayMode,
    required this.currentMultiSites,
    required this.currentLabelColor,
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
  late Color  _labelColor;
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
    _labelColor  = widget.currentLabelColor;
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
    hintStyle: TextStyle(color: appLabelColor),
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
              Expanded(
                child: Text('Configuration',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        letterSpacing: 2.5, color: appLabelColor)),
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
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 1.5, color: appLabelColor)),
                ),
              // Nom
              Text('Nom', style: TextStyle(fontSize: 12, color: appLabelColor)),
              const SizedBox(height: 4),
              TextField(
                controller: _ctrls[i]['name'],
                style: const TextStyle(fontSize: 14, color: Color(0xFFE8EAF0)),
                decoration: _inputDeco('Mon Routeur Solaire'),
              ),
              const SizedBox(height: 8),
              // URL
              Text('URL', style: TextStyle(fontSize: 12, color: appLabelColor)),
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
              Text('Mot de passe (optionnel)',
                  style: TextStyle(fontSize: 12, color: appLabelColor)),
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
                    Text('Capteurs de température',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                            letterSpacing: 1.2, color: appLabelColor)),
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

            // ── Couleur des textes ───────────────────────────────────────────
            Text('Couleur des textes',
                style: TextStyle(fontSize: 12, color: appLabelColor)),
            const SizedBox(height: 8),
            _LabelColorPicker(
              value: _labelColor,
              onChanged: (c) => setState(() => _labelColor = c),
            ),
            const SizedBox(height: 16),

            // ── Affichage (uniquement si plusieurs ESP) ──────────────────────
            if (_count > 1) ...[
              Text('Affichage',
                  style: TextStyle(fontSize: 12, color: appLabelColor)),
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
                subtitle: Text(
                    'Affiche le Soutiré/Injecté de chaque ESP séparément',
                    style: TextStyle(fontSize: 11, color: appLabelColor)),
                activeColor: const Color(0xFFF97316),
                side: BorderSide(color: Colors.white.withOpacity(0.3)),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              const SizedBox(height: 8),
            ],

            // ── Orientation ──────────────────────────────────────────────────
            Text('Orientation',
                style: TextStyle(fontSize: 12, color: appLabelColor)),
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
                  await widget.onSave(configs, _orientation, _displayMode, _multiSites, _labelColor);
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
                color: enabled ? const Color(0xFFE8EAF0) : appLabelColor.withOpacity(0.7))),
      ),
    );
  }
}

// ── Sélecteur de couleur des textes secondaires ───────────────────────────────
class _LabelColorPicker extends StatelessWidget {
  final Color value;
  final void Function(Color) onChanged;
  const _LabelColorPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final (color, label) in kLabelColorPresets)
          GestureDetector(
            onTap: () => onChanged(color),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 34, height: 34,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: value == color
                        ? const Color(0xFFF97316) : Colors.white.withOpacity(0.15),
                    width: value == color ? 2.5 : 1,
                  ),
                  boxShadow: value == color ? [BoxShadow(
                      color: const Color(0xFFF97316).withOpacity(0.5),
                      blurRadius: 6)] : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(
                  fontSize: 9,
                  color: value == color ? const Color(0xFFF97316) : appLabelColor)),
            ]),
          ),
      ],
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
                          ? Colors.white : appLabelColor),
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
                          ? Colors.white : appLabelColor),
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



// ── Page des graphiques ────────────────────────────────────────────────────────
class ChartsPage extends StatefulWidget {
  final EspConfig config;
  final String    title;
  final EspState? initialState;
  const ChartsPage({super.key, required this.config, required this.title,
    this.initialState});

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage>
    with SingleTickerProviderStateMixin {

  late TabController _tabCtrl;
  Timer? _timer2s;
  Timer? _timer5min;

  String _nomSonde1 = '';
  String _nomSonde2 = '';
  List<CapteurInfo> _capteurInfos =
  List.generate(4, (_) => const CapteurInfo(nom: '', actif: false));
  bool _paraFixeFetched = false;

  // 10mn
  List<double> _pwM10 = [], _pvaM10 = [], _pwT10 = [], _pvaT10 = [];
  final List<List<double>> _tempBufs10 = [[], [], [], []];
  final Map<int, List<double>> _ouvBufs = {};   // 10mn (333 pts max)
  final Map<int, List<double>> _ouvBufs48 = {}; // 48h  (576 pts max, 1 pt/5min)
  List<ModuleData> _modules = [];
  static const int kMax10 = 333;

  // 48h
  List<double> _pwM48 = [], _pvaM48 = [], _pwT48 = [], _pvaT48 = [];
  List<List<double>> _temps48 = [];
  List<List<double>> _ouvs48  = [];
  List<String>       _ouvNoms48 = [];

  // 1an
  List<_Histo1anEntry> _entries1an = [];

  bool   _loading10 = true,  _loading48 = true,  _loading1an = true;
  String _status10  = '…',   _status48  = '…',   _status1an  = '…';

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    if (widget.initialState != null) {
      _nomSonde1    = widget.initialState!.nomSonde1;
      _nomSonde2    = widget.initialState!.nomSonde2;
      if (widget.initialState!.capteursInfo.isNotEmpty)
        _capteurInfos = widget.initialState!.capteursInfo;
      _modules = widget.initialState!.modules;
    }
    _refresh10(); _refresh48(); _refresh1an();
    _timer2s   = Timer.periodic(const Duration(seconds: 2),  (_) => _refresh10());
    _timer5min = Timer.periodic(const Duration(minutes: 5),  (_) { _refresh48(); _refresh1an(); _sampleOuv48(); });
  }

  @override
  void dispose() {
    _tabCtrl.dispose(); _timer2s?.cancel(); _timer5min?.cancel();
    super.dispose();
  }

  String  get _base   => widget.config.url.trimRight().replaceAll(RegExp(r'/$'), '');
  String? get _cookie => widget.config.password.isNotEmpty ? 'CleAcces=${widget.config.password}' : null;

  Future<void> _ensureParaFixe() async {
    if (_paraFixeFetched) return;
    try {
      final pf   = await simpleGet('$_base/ParaFixe', cookie: _cookie).timeout(const Duration(seconds: 5));
      final data = jsonDecode(pf) as Map<String, dynamic>;
      _nomSonde1 = (data['nomSondeMobile'] ?? '').toString();
      _nomSonde2 = (data['nomSondeFixe']   ?? '').toString();
      final src  = (data['Source'] ?? '').toString();
      if (src == 'Ext' || src == 'ShellyPro') _nomSonde2 = '';
      if ((data['nomSfixePpos'] ?? '').toString().isEmpty &&
          (data['nomSfixePneg'] ?? '').toString().isEmpty) _nomSonde2 = '';
      _capteurInfos    = parseCapteursInfo(pf);
      _paraFixeFetched = true;
    } catch (_) {}
  }

  // ── Parser ajax_data10mn (format simple : GS entre groupes) ─────────────────
  List<List<double>> _parsePower(String body) {
    List<List<double>> pg(String raw) {
      final v  = raw.split(',').map((s) => double.tryParse(s.trim()) ?? 0.0).toList();
      final w  = <double>[], va = <double>[];
      for (var i = 0; i + 1 < v.length; i += 2) { w.add(v[i]); va.add(v[i+1]); }
      return [w, va];
    }
    final g = body.split(GS);
    if (g.length < 2) return [[], [], [], []];
    final g1 = pg(g[1]);
    final g2 = g.length >= 3 ? pg(g[2]) : [<double>[], <double>[]];
    return [g1[0], g1[1], g2[0], g2[1]];
  }

  // ── Parser ajax_histo48h / ajax_histo1an ─────────────────────────────────
  // GS peut être :
  //   - fragmentation réseau (même type de données des deux côtés) → fusionner
  //   - séparateur structurel (transition int→float ou float→int) → nouvelle série
  // Le token '-' seul sépare les sous-séries à l'intérieur des blocs entiers
  Map<String, List<double>> _parseHisto(String body) {
    final chunks = body.split(GS);
    if (chunks.length < 2) return {};

    bool looksFloat(String s) {
      final first = s.trim().split(',').first.trim();
      return first.contains('.') && double.tryParse(first) != null;
    }

    // Traiter chunk par chunk en détectant les transitions de type
    final allSeries = <List<double>>[];
    List<double> current = [];
    String? prevType; // 'int' | 'float'

    void commitCurrent() {
      if (current.isNotEmpty) { allSeries.add(List.of(current)); current.clear(); }
    }

    for (var i = 1; i < chunks.length; i++) { // chunks[0] = métadonnées
      final s = chunks[i];
      if (s.trim().isEmpty) continue;
      final curType = looksFloat(s) ? 'float' : 'int';

      // Changement de type → séparateur structurel → nouvelle série
      if (prevType != null && curType != prevType) commitCurrent();

      for (final t in s.split(',')) {
        final v = t.trim();
        if (v == '-') {
          // Séparateur de sous-série dans les blocs entiers
          commitCurrent();
        } else {
          final d = double.tryParse(v);
          if (d != null) current.add(d);
        }
      }
      prevType = curType;
    }
    commitCurrent();

    // Classer les séries par leur position et type
    // Floats → températures | Entiers avant floats → puissance | Après floats → ouvertures
    final pwSeries   = <List<double>>[];
    final tempSeries = <List<double>>[];
    final ouvSeries  = <List<double>>[];
    bool floatFound  = false;

    for (final s in allSeries) {
      if (s.length < 5) continue; // ignorer les fragments trop courts
      final hasFloat = s.any((v) => v != v.truncate()); // valeur non entière
      if (hasFloat) {
        floatFound = true;
        tempSeries.add(s);
      } else if (floatFound) {
        ouvSeries.add(s);
      } else {
        pwSeries.add(s);
      }
    }

    final result = <String, List<double>>{};
    for (var i = 0; i < pwSeries.length;   i++) result['pw_$i']   = pwSeries[i];
    for (var i = 0; i < tempSeries.length; i++) result['temp_$i'] = tempSeries[i];
    for (var i = 0; i < ouvSeries.length;  i++) result['ouv_$i']  = ouvSeries[i];
    return result;
  }

  Future<void> _refresh10() async {
    await _ensureParaFixe();
    try {
      final r = await Future.wait([
        simpleGet('$_base/ajax_data10mn', cookie: _cookie),
        simpleGet('$_base/ajax_data',     cookie: _cookie),
        simpleGet('$_base/ajax_etatActions?Force=0&NumAction=0', cookie: _cookie),
      ]).timeout(const Duration(seconds: 5));
      final pw = _parsePower(r[0]);
      final tp = parseTemperatures(r[1]);
      final mo = parseActionneurs(r[2]);
      if (!mounted) return;
      setState(() {
        _pwM10 = pw[0]; _pvaM10 = pw[1]; _pwT10 = pw[2]; _pvaT10 = pw[3];
        for (var i = 0; i < 4; i++) {
          if (tp[i] != null) { _tempBufs10[i].add(tp[i]!); if (_tempBufs10[i].length > kMax10) _tempBufs10[i].removeAt(0); }
        }
        _modules = mo;
        for (final m in mo) {
          _ouvBufs.putIfAbsent(m.numAction, () => []);
          _ouvBufs[m.numAction]!.add(m.ouverture ?? 0);
          if (_ouvBufs[m.numAction]!.length > kMax10) _ouvBufs[m.numAction]!.removeAt(0);
        }
        _loading10 = false; _status10 = TimeOfDay.now().format(context);
      });
    } catch (_) { if (mounted) setState(() => _status10 = 'erreur'); }
  }

  // ── Parser ouvertures 48h ─────────────────────────────────────────────────
  // Structure : [power_data] | [capteurs]
  // Capteurs : GS val1 RS val2 RS ... RS NomModule GS val1 RS ... RS NomModule2
  List<({List<double> values, String nom})> _parseOuvertures48h(String body) {
    // 1. Prendre tout ce qui est après le dernier '|'
    final lastPipe = body.lastIndexOf('|');
    if (lastPipe < 0) return [];
    final section = body.substring(lastPipe + 1);

    // 2. Chaque capteur commence par GS
    final chunks = section.split(GS)
        .where((s) => s.trim().isNotEmpty).toList();

    final result = <({List<double> values, String nom})>[];

    for (final chunk in chunks) {
      // 3. Les champs sont séparés par RS
      final fields = chunk.split(RS)
          .map((f) => f.trim()).where((f) => f.isNotEmpty).toList();
      if (fields.length < 2) continue;

      // 4. Dernier champ = nom du module
      final nom    = fields.last;
      if (double.tryParse(nom) != null) continue; // sécurité : doit être du texte

      // 5. Champs précédents = valeurs d'ouverture (entiers 0-100)
      final values = fields.sublist(0, fields.length - 1)
          .map((v) => double.tryParse(v))
          .where((v) => v != null && v >= 0 && v <= 100)
          .cast<double>().toList();

      if (values.isNotEmpty) result.add((values: values, nom: nom));
    }
    return result;
  }


  Future<void> _refresh48() async {
    await _ensureParaFixe();
    try {
      final body    = await simpleGet('$_base/ajax_histo48h', cookie: _cookie)
          .timeout(const Duration(seconds: 10));
      final pw      = _parsePower(body);
      final parsed  = _parseHisto(body);
      final ouvData = _parseOuvertures48h(body);
      if (!mounted) return;
      setState(() {
        _pwM48     = pw[0]; _pvaM48 = pw[1];
        _pwT48     = pw[2]; _pvaT48 = pw[3];
        _temps48   = parsed.entries
            .where((e) => e.key.startsWith('temp_'))
            .map((e) => e.value).toList();
        _ouvs48    = ouvData.map((o) => o.values).toList();
        _ouvNoms48 = ouvData.map((o) => o.nom).toList();
        _loading48 = false;
        _status48  = TimeOfDay.now().format(context);
      });
    } catch (_) {
      if (mounted) setState(() { _loading48 = false; _status48 = 'erreur'; });
    }
  }

  Future<void> _refresh1an() async {
    try {
      final body    = await simpleGet('$_base/ajax_histo1an', cookie: _cookie)
          .timeout(const Duration(seconds: 10));
      final entries = _parse1an(body);
      if (!mounted) return;
      setState(() {
        _entries1an = entries;
        _loading1an = false;
        _status1an  = TimeOfDay.now().format(context);
      });
    } catch (_) {
      if (mounted) setState(() { _loading1an = false; _status1an = 'erreur'; });
    }
  }

  List<_Histo1anEntry> _parse1an(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final list = (data['EnergieJour'] as List).cast<String>();

      // Grouper par date : garder la meilleure entrée (non-reset ou durée max)
      final byDate = <String, _Histo1anEntry>{};

      for (final r in list) {
        final f = r.split(',');
        if (f.length < 3) continue;
        final date = f[0].trim();
        if (!RegExp(r'^\d{8}$').hasMatch(date)) continue;

        final sout  = double.tryParse(f[1].trim()) ?? 0.0;
        final inj   = double.tryParse(f[2].trim()) ?? 0.0;
        final sout2 = f.length > 3 && f[3].trim().isNotEmpty
            ? (double.tryParse(f[3].trim()) ?? 0.0) : 0.0;
        final inj2  = f.length > 4 && f[4].trim().isNotEmpty
            ? (double.tryParse(f[4].trim()) ?? 0.0) : 0.0;
        final duration = f.length > 5 ? (double.tryParse(f[5].trim()) ?? 0.0) : 0.0;
        final endField = f.length > 6 ? f.sublist(6).join(',').trim() : '';
        final isReset  = endField.toLowerCase().contains('reset') ||
            endField.toLowerCase().contains('restart');

        final entry = _Histo1anEntry(
          date: date, soutire: sout, injecte: inj,
          soutire2: sout2, injecte2: inj2,
          duration: duration, isReset: isReset,
        );

        // Préférer : non-reset > reset, puis durée la plus longue
        final existing = byDate[date];
        if (existing == null ||
            (!isReset && existing.isReset) ||
            (isReset == existing.isReset && duration > existing.duration)) {
          byDate[date] = entry;
        }
      }

      // Trier par date chronologique
      final sorted = byDate.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return sorted.map((e) => e.value).toList();

    } catch (e) {
      return [];
    }
  }

  // Échantillonnage toutes les 5min des ouvertures pour le graphique 48h
  void _sampleOuv48() {
    for (final m in _modules) {
      _ouvBufs48.putIfAbsent(m.numAction, () => []);
      _ouvBufs48[m.numAction]!.add(m.ouverture ?? 0);
      if (_ouvBufs48[m.numAction]!.length > 576) { // 48h × 12 pts/h
        _ouvBufs48[m.numAction]!.removeAt(0);
      }
    }
  }

  Widget _buildChart({required String title, required List<List<double>> series,
    required List<Color> colors, required List<String> labels, String unit = 'W',
    double? forceMinY, double? forceMaxY}) {
    if (series.every((s) => s.isEmpty)) return const SizedBox.shrink();
    double maxY = 0, minY = 0;
    for (final s in series) for (final v in s) { if (v > maxY) maxY = v; if (v < minY) minY = v; }
    maxY = forceMaxY ?? (maxY < 10 ? 10 : maxY * 1.15);
    minY = forceMinY ?? (minY > -10 ? (minY < 0 ? minY * 1.15 : 0) : minY * 1.15);
    final bars = <LineChartBarData>[];
    for (var i = 0; i < series.length; i++) {
      if (series[i].isEmpty) continue;
      bars.add(LineChartBarData(
        spots: series[i].asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
        isCurved: true, curveSmoothness: 0.25, color: colors[i % colors.length],
        barWidth: series[i].length > 100 ? 1.5 : 2, dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: true, color: colors[i % colors.length].withOpacity(0.08)),
      ));
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      decoration: BoxDecoration(color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.08))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 10,
              fontWeight: FontWeight.w600, letterSpacing: 1.5, color: appLabelColor))),
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Container(width: 8, height: 8, decoration: BoxDecoration(
                color: colors[i % colors.length], shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(labels[i], style: TextStyle(fontSize: 10, color: appLabelColor)),
          ],
        ]),
        const SizedBox(height: 10),
        SizedBox(height: 130, child: LineChart(LineChartData(
          clipData: const FlClipData.all(),
          gridData: FlGridData(show: true, drawVerticalLine: false,
              getDrawingHorizontalLine: (v) => FlLine(
                  color: v == 0 && minY < 0 ? Colors.white.withOpacity(0.2) : Colors.white.withOpacity(0.05),
                  strokeWidth: v == 0 && minY < 0 ? 1.5 : 1)),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 38,
                getTitlesWidget: (v, _) => Text('${v.toInt()}$unit',
                    style: TextStyle(fontSize: 9, color: appLabelColor)))),
            rightTitles:  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          minY: minY, maxY: maxY, lineBarsData: bars,
          lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => spots.map((s) => LineTooltipItem(
                  '${s.y.toStringAsFixed(0)}$unit',
                  TextStyle(color: colors[s.barIndex % colors.length],
                      fontSize: 11, fontWeight: FontWeight.w600))).toList())),
        ))),
      ]),
    );
  }

  // ── Histogramme annuel ────────────────────────────────────────────────────
  Widget _buildHistoBar(List<_Histo1anEntry> entries) {
    if (entries.isEmpty) {
      return Center(child: Text('Aucune donnée ($_status1an)',
          style: TextStyle(fontSize: 12, color: appLabelColor)));
    }

    String labelDate(String d) =>
        d.length == 8 ? '${d.substring(6)}/${d.substring(4, 6)}' : d;

    double maxY = 0;
    for (final e in entries) { if (e.soutire > maxY) maxY = e.soutire; }
    maxY = maxY < 100 ? 100 : maxY * 1.15;

    final barWidth = (entries.length > 60 ? 5.0 : entries.length > 30 ? 8.0 : 12.0);
    final chartWidth = entries.length * (barWidth + 3) + 60;

    Widget chart = BarChart(BarChartData(
      maxY:  maxY,
      minY: -maxY * 0.3,
      gridData: FlGridData(
        show: true, drawVerticalLine: false,
        getDrawingHorizontalLine: (v) => FlLine(
          color: v == 0 ? Colors.white.withOpacity(0.2) : Colors.white.withOpacity(0.05),
          strokeWidth: v == 0 ? 1.5 : 1,
        ),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true, reservedSize: 44,
          getTitlesWidget: (v, _) => Text('${(v/1000).toStringAsFixed(1)}k',
              style: TextStyle(fontSize: 9, color: appLabelColor)),
        )),
        rightTitles:  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles:    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true, reservedSize: 22,
          getTitlesWidget: (v, _) {
            final i = v.toInt();
            if (i < 0 || i >= entries.length) return const SizedBox();
            // Afficher le label tous les 7 jours environ
            final step = entries.length > 60 ? (entries.length ~/ 12) : 7;
            if (i % step != 0) return const SizedBox();
            return Transform.rotate(
              angle: -0.5,
              child: Text(labelDate(entries[i].date),
                  style: TextStyle(fontSize: 8, color: appLabelColor)),
            );
          },
        )),
      ),
      barGroups: entries.asMap().entries.map((e) {
        final alpha = e.value.isReset ? 0.45 : 1.0;
        return BarChartGroupData(
          x: e.key,
          barRods: [
            BarChartRodData(fromY: 0, toY: e.value.soutire,
                color: const Color(0xFFF43F5E).withOpacity(alpha),
                width: barWidth,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
            if (e.value.injecte > 0)
              BarChartRodData(fromY: -e.value.injecte, toY: 0,
                  color: const Color(0xFF22D3A8).withOpacity(alpha),
                  width: barWidth,
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(2))),
          ],
        );
      }).toList(),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          fitInsideVertically: true,
          fitInsideHorizontally: true,
          getTooltipItem: (group, _, rod, rodIndex) {
            final e      = entries[group.x];
            final label  = labelDate(e.date);
            final reset  = e.isReset ? '\n⚠ ${e.duration.toStringAsFixed(1)}h' : '';
            return BarTooltipItem(
              '$label\n',
              const TextStyle(color: Color(0xFFE8EAF0),
                  fontSize: 11, fontWeight: FontWeight.w600),
              children: [
                TextSpan(
                    text: '↑ ${(e.soutire / 1000).toStringAsFixed(2)} kWh',
                    style: const TextStyle(color: Color(0xFFF43F5E),
                        fontSize: 11, fontWeight: FontWeight.w600)),
                TextSpan(
                    text: '\n↓ ${(e.injecte / 1000).toStringAsFixed(2)} kWh$reset',
                    style: const TextStyle(color: Color(0xFF22D3A8),
                        fontSize: 11, fontWeight: FontWeight.w600)),
              ],
            );
          },
        ),
      ),
    ));

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('ÉNERGIE JOUR · 1 AN',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                  letterSpacing: 1.5, color: appLabelColor))),
          Container(width: 8, height: 8, decoration: const BoxDecoration(
              color: Color(0xFFF43F5E), shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text('Wh soutire', style: TextStyle(fontSize: 10, color: appLabelColor)),
          const SizedBox(width: 10),
          Container(width: 8, height: 8, decoration: const BoxDecoration(
              color: Color(0xFF22D3A8), shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text('Wh injecte', style: TextStyle(fontSize: 10, color: appLabelColor)),
        ]),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: max(chartWidth, 300),
            height: 150,
            child: chart,
          ),
        ),
      ]),
    );
  }

  Widget _buildTabContent({
    required bool loading, required String status,
    required List<double> pwM, required List<double> pvaM,
    required List<double> pwT, required List<double> pvaT,
    List<List<double>>? tempBufs,    // 10mn : buffer par index capteur
    List<List<double>>? tempsList,   // 48h : liste de séries de températures
    Map<int, List<double>>? ouvBufs, // 10mn : buffer par numAction
    List<List<double>>? ouvsList,    // 48h : liste de séries d'ouvertures
    List<String>?       ouvsNoms,    // 48h : noms des modules d'ouvertures
    List<ModuleData>? modules, required String windowLabel,
  }) {
    if (loading) return const Center(child: CircularProgressIndicator(color: Color(0xFFF97316), strokeWidth: 2));
    final nomS1 = _nomSonde1.isNotEmpty ? _nomSonde1.toUpperCase() : 'SONDE';
    final nomS2 = _nomSonde2.isNotEmpty ? _nomSonde2.toUpperCase() : '';
    final hasVAM = pvaM.any((v) => v > 0), hasVAT = pvaT.any((v) => v > 0);
    final tc = [const Color(0xFFF97316), const Color(0xFF22D3A8), const Color(0xFF3B82F6), const Color(0xFFA855F7)];
    final oc = [const Color(0xFFF97316), const Color(0xFF3B82F6), const Color(0xFF22D3A8), const Color(0xFFA855F7)];
    final charts = <Widget>[];
    if (pwM.isNotEmpty) charts.add(_buildChart(
        title: 'PUISSANCE $nomS1 · $windowLabel',
        series: [pwM, if (hasVAM) pvaM],
        colors: [const Color(0xFFF43F5E), const Color(0xFF22D3A8)],
        labels: ['W', if (hasVAM) 'VA']));
    if (pwT.isNotEmpty && nomS2.isNotEmpty) charts.add(_buildChart(
        title: 'PUISSANCE $nomS2 · $windowLabel',
        series: [pwT, if (hasVAT) pvaT],
        colors: [const Color(0xFF3B82F6), const Color(0xFFA855F7)],
        labels: ['W', if (hasVAT) 'VA']));
    if (tempBufs != null) for (var i = 0; i < 4; i++) {
      if (tempBufs[i].isNotEmpty && i < _capteurInfos.length && _capteurInfos[i].actif)
        charts.add(_buildChart(
            title: 'TEMPÉRATURE · ${_capteurInfos[i].nom.toUpperCase()}',
            series: [tempBufs[i]], colors: [tc[i]], labels: [_capteurInfos[i].nom], unit: '°C'));
    }
    // Températures depuis histo (48h/1an)
    if (tempsList != null) for (var i = 0; i < tempsList.length; i++) {
      if (tempsList[i].isNotEmpty) {
        final nom = i < _capteurInfos.length ? _capteurInfos[i].nom : 'Capteur ${i+1}';
        charts.add(_buildChart(
            title: 'TEMPÉRATURE · ${nom.toUpperCase()}',
            series: [tempsList[i]], colors: [tc[i % tc.length]], labels: [nom], unit: '°C'));
      }
    }
    // Ouvertures depuis buffer 10mn
    if (ouvBufs != null && modules != null) for (var mi = 0; mi < modules.length; mi++) {
      final buf = ouvBufs[modules[mi].numAction] ?? [];
      if (buf.isNotEmpty) charts.add(_buildChart(
          title: 'OUVERTURE · ${modules[mi].nom.toUpperCase()}',
          series: [buf], colors: [oc[mi % oc.length]], labels: [modules[mi].nom],
          unit: '%', forceMinY: 0, forceMaxY: 100));
    }
    // Ouvertures depuis histo (48h/1an)
    if (ouvsList != null) for (var i = 0; i < ouvsList.length; i++) {
      if (ouvsList[i].isNotEmpty) {
        // Utiliser ouvsNoms si disponible (48h avec noms réels), sinon fallback modules
        final nom = (ouvsNoms != null && i < ouvsNoms.length)
            ? ouvsNoms[i]
            : (i < _modules.length ? _modules[i].nom : 'Module ${i+1}');
        charts.add(_buildChart(
            title: 'OUVERTURE · ${nom.toUpperCase()}',
            series: [ouvsList[i]], colors: [oc[i % oc.length]], labels: [nom],
            unit: '%', forceMinY: 0, forceMaxY: 100));
      }
    }
    if (charts.isEmpty) return Center(child: Text('Aucune donnée ($status)',
        style: TextStyle(fontSize: 12, color: appLabelColor)));
    return SingleChildScrollView(padding: const EdgeInsets.only(top: 16, bottom: 24),
        child: Column(children: charts));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827), elevation: 0,
        leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new, color: appLabelColor, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(widget.title, style: const TextStyle(fontSize: 13,
            fontWeight: FontWeight.w600, letterSpacing: 1.5, color: Color(0xFFE8EAF0))),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: const Color(0xFFF97316),
          labelColor: const Color(0xFFF97316),
          unselectedLabelColor: appLabelColor,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          tabs: const [Tab(text: '10 MN'), Tab(text: '48 H'), Tab(text: '1 AN')],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          _buildTabContent(loading: _loading10, status: _status10,
              pwM: _pwM10, pvaM: _pvaM10, pwT: _pwT10, pvaT: _pvaT10,
              tempBufs: _tempBufs10, ouvBufs: _ouvBufs, modules: _modules,
              windowLabel: '10 MN'),
          _buildTabContent(loading: _loading48, status: _status48,
              pwM: _pwM48, pvaM: _pvaM48, pwT: _pwT48, pvaT: _pvaT48,
              tempsList: _temps48, ouvsList: _ouvs48, ouvsNoms: _ouvNoms48,
              windowLabel: '48 H'),
          // ── Onglet 1 AN ─────────────────────────────────────────────────
          _loading1an
              ? const Center(child: CircularProgressIndicator(
              color: Color(0xFFF97316), strokeWidth: 2))
              : SingleChildScrollView(
            padding: const EdgeInsets.only(top: 16, bottom: 24),
            child: Column(children: [
              _buildHistoBar(_entries1an),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Entrée historique annuelle ─────────────────────────────────────────────────
class _Histo1anEntry {
  final String date;     // "20260717"
  final double soutire;  // Wh soutires sonde mobile
  final double injecte;  // Wh injectes sonde mobile
  final double soutire2; // Wh soutires sonde fixe
  final double injecte2; // Wh injectes sonde fixe
  final double duration; // Durée de mesure en heures (~24h normalement)
  final bool   isReset;  // true si journée incomplète suite à reset
  const _Histo1anEntry({
    required this.date,
    required this.soutire,
    required this.injecte,
    this.soutire2 = 0.0,
    this.injecte2 = 0.0,
    this.duration = 24.0,
    this.isReset  = false,
  });
}
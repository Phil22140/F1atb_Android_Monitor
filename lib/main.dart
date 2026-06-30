import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const ChauffeEauApp());
}

// ── Séparateurs ASCII (identiques au firmware F1ATB) ──────────────────────────
const String GS = '\x1d'; // Group Separator
const String appVersion = '2.4.0';
const String RS = '\x1e'; // Record Separator

// ── Parsing /ajax_data ────────────────────────────────────────────────────────
Map<String, double> parsePuissances(String body) {
  final groupes = body.split(GS);
  if (groupes.length < 2) return {'pws': 0, 'pwi': 0};
  final g1 = groupes[1].split(RS);
  return {
    'pws': double.tryParse(g1[0].trim()) ?? 0,
    'pwi': g1.length > 1 ? (double.tryParse(g1[1].trim()) ?? 0) : 0,
  };
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

// ── Parsing /ajax_etatActions ─────────────────────────────────────────────────
class ActionData {
  final double? ouverture;
  final String? heureEquiv;
  final int forcage; // 0=auto, >0=forcé ON (minutes restantes), <0=forcé OFF
  const ActionData({this.ouverture, this.heureEquiv, this.forcage = 0});
}

ActionData parseActionneur(String body) {
  final groupes = body.split(GS);
  if (groupes.length < 5) return const ActionData();
  final data = groupes[4].split(RS);
  if (data.length < 3) return const ActionData();

  // data[2] = ouverture (%, 'On', 'Off')
  final v = data[2].trim();
  double? ouverture;
  if (v == 'On')       ouverture = 100;
  else if (v == 'Off') ouverture = 0;
  else                 ouverture = double.tryParse(v);

  // data[3] = forçage en minutes (0=auto, >0=forcé ON, <0=forcé OFF)
  int forcage = 0;
  if (data.length >= 4) {
    forcage = int.tryParse(data[3].trim()) ?? 0;
  }

  // data[4] = équivalence heure
  String? heureEquiv;
  if (data.length >= 5) {
    final raw = data[4].trim();
    if (raw.isNotEmpty) heureEquiv = equivToHmn(raw);
  }

  return ActionData(ouverture: ouverture, heureEquiv: heureEquiv, forcage: forcage);
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

// ── Écran principal ────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _esp32Url = '';
  String _password = '';
  double? _ce;
  String? _heureEquiv;
  int _forcage = 0;
  List<CapteurInfo> _capteursInfo = List.generate(4, (i) => const CapteurInfo(nom: '', actif: false));
  List<double?> _temperatures = [null, null, null, null];
  double _pws = 0;
  double _pwi = 0;
  bool _ok = false;
  String _statusTxt = 'connexion…';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('esp32_url') ?? '';
    final pwd = prefs.getString('esp32_pwd') ?? '';
    if (url.isNotEmpty) {
      setState(() { _esp32Url = url; _password = pwd; });
      _startPolling();
    } else {
      _showConfig();
    }
  }

  Future<void> _saveConfig(String url, String pwd) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('esp32_url', url);
    await prefs.setString('esp32_pwd', pwd);
    setState(() { _esp32Url = url; _password = pwd; });
    _startPolling();
  }

  void _startPolling() {
    _timer?.cancel();
    _fetchCapteursInfo(); // une seule fois, infos statiques
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _fetchCapteursInfo() async {
    try {
      final base = _esp32Url.trimRight().replaceAll(RegExp(r'/$'), '');
      final cookie = _password.isNotEmpty ? 'CleAcces=$_password' : null;
      final body = await simpleGet('$base/ParaFixe', cookie: cookie)
          .timeout(const Duration(seconds: 8));
      final infos = parseCapteursInfo(body);
      if (mounted) setState(() => _capteursInfo = infos);
    } catch (_) {
      // pas bloquant : sans ces infos, les capteurs ne s'affichent simplement pas
    }
  }

  Future<void> _refresh() async {
    try {
      final base = _esp32Url.trimRight().replaceAll(RegExp(r'/$'), '');
      final cookie = _password.isNotEmpty ? 'CleAcces=$_password' : null;
      final results = await Future.wait([
        simpleGet('$base/ajax_data', cookie: cookie),
        simpleGet('$base/ajax_etatActions?Force=0&NumAction=0', cookie: cookie),
      ]).timeout(const Duration(seconds: 10));

      final pw = parsePuissances(results[0]);
      final action = parseActionneur(results[1]);
      final temps = parseTemperatures(results[0]);

      setState(() {
        _pws = pw['pws']!;
        _pwi = pw['pwi']!;
        _ce = action.ouverture;
        _heureEquiv = action.heureEquiv;
        _forcage = action.forcage;
        _temperatures = temps;
        _ok = true;
        _statusTxt = 'màj ${TimeOfDay.now().format(context)}';
      });
    } catch (e) {
      setState(() {
        _ok = false;
        _statusTxt = 'erreur : $e';
      });
    }
  }

  Future<void> _sendForce(int force) async {
    try {
      final base = _esp32Url.trimRight().replaceAll(RegExp(r'/$'), '');
      final cookie = _password.isNotEmpty ? 'CleAcces=$_password' : null;
      await simpleGet('$base/ajax_etatActions?Force=$force&NumAction=0', cookie: cookie);
      await _refresh(); // rafraîchit immédiatement après l'action
    } catch (_) {}
  }

  void _showConfig() {
    _timer?.cancel();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ConfigSheet(
        currentUrl: _esp32Url,
        currentPwd: _password,
        onSave: (url, pwd) {
          Navigator.pop(context);
          _saveConfig(url, pwd);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capteursActifs = <int>[];
    for (var i = 0; i < 4; i++) {
      if (_capteursInfo[i].actif && _temperatures[i] != null) {
        capteursActifs.add(i);
      }
    }
    final hasCapteurs = capteursActifs.isNotEmpty;
    final imageHeight = hasCapteurs ? 100.0 : 150.0;

    return Scaffold(
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Bandeau image en haut, sous la barre de statut
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: hasCapteurs
                  // Layout compact : image à gauche + texte centré à droite
                      ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: SizedBox(
                          width: imageHeight,
                          height: imageHeight,
                          child: Image.asset(
                            'assets/icon.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Text(
                          'F1ATB MONITOR',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2.0,
                            color: Color(0xFF5A6278),
                          ),
                        ),
                      ),
                    ],
                  )
                  // Layout standard : image pleine largeur
                      : ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: SizedBox(
                      width: double.infinity,
                      height: imageHeight,
                      child: Image.asset(
                        'assets/icon.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SafeArea(
                  top: false,
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(height: hasCapteurs ? 10 : 20),
                          if (!hasCapteurs) ...[
                            const Text(
                              'F1ATB MONITOR',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 2.5,
                                color: Color(0xFF5A6278),
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],
                          // Jauge circulaire
                          GaugeWidget(value: _ce ?? 0, hasValue: _ce != null),
                          SizedBox(height: hasCapteurs ? 2 : 8),
                          // Équivalence heure (ex: 0:08 = 8 min à 100%)
                          if (_heureEquiv != null)
                            Text(
                              'équivalent à $_heureEquiv à 100%',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF5A6278),
                                fontFamily: 'monospace',
                              ),
                            ),
                          SizedBox(height: hasCapteurs ? 10 : 16),
                          // Capteurs température (si actifs)
                          if (hasCapteurs)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: CapteursRow(
                                indices: capteursActifs,
                                infos: _capteursInfo,
                                temperatures: _temperatures,
                              ),
                            ),
                          if (hasCapteurs) const SizedBox(height: 10),
                          // Cards puissance
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Row(
                              children: [
                                Expanded(child: PowerCard(
                                  label: 'Soutiré',
                                  value: _pws,
                                  color: const Color(0xFFF43F5E),
                                )),
                                const SizedBox(width: 10),
                                Expanded(child: PowerCard(
                                  label: 'Injecté',
                                  value: _pwi,
                                  color: const Color(0xFF22D3A8),
                                )),
                              ],
                            ),
                          ),
                          SizedBox(height: hasCapteurs ? 12 : 18),
                          // Widget forçage
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: ForceWidget(
                              forcage: _forcage,
                              onForce: _sendForce,
                            ),
                          ),
                          SizedBox(height: hasCapteurs ? 10 : 14),
                          // Statut
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  width: 6, height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _ok ? const Color(0xFF22D3A8) : const Color(0xFFF43F5E),
                                    boxShadow: _ok ? [BoxShadow(
                                      color: const Color(0xFF22D3A8).withOpacity(0.6),
                                      blurRadius: 6,
                                    )] : null,
                                  ),
                                ),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: Text(_statusTxt,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 11, color: Color(0xFF5A6278),
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'v$appVersion',
                                  style: TextStyle(
                                    fontSize: 11, color: Color(0xFF3A4258),
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: hasCapteurs ? 10 : 16),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // Bouton config
          SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 18, 36, 0),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.3),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: _showConfig,
                    icon: const Icon(Icons.settings_outlined, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Jauge circulaire ───────────────────────────────────────────────────────────
class GaugeWidget extends StatelessWidget {
  final double value;
  final bool hasValue;
  const GaugeWidget({super.key, required this.value, required this.hasValue});

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
      width: 190, height: 190,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: hasValue ? value / 100 : 0),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOut,
            builder: (_, v, __) => CustomPaint(
              size: const Size(190, 190),
              painter: _GaugePainter(v, _gaugeColors, _colorAt(v)),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                hasValue ? '${value.round()}' : '--',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 46,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFE8EAF0),
                  height: 1,
                ),
              ),
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
  const _GaugePainter(this.progress, this.gaugeColors, this.cursorColor);

  static const double _strokeWidth = 14;
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
    final r = size.width / 2 - _strokeWidth;
    final rect = Rect.fromCircle(center: c, radius: r);

    // Arc en dégradé conique rouge → orange → jaune → vert, limité à 270°
    // Le shader est calculé sur [0, 270°] puis pivoté de +135° via GradientRotation
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
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
    final capAngle = asin((_strokeWidth / 2) / r);
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
    canvas.drawCircle(cursorCenter, _strokeWidth * 0.65, haloPaint);

    final dotPaint = Paint()..color = cursorColor;
    canvas.drawCircle(cursorCenter, _strokeWidth * 0.42, dotPaint);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.progress != progress || old.cursorColor != cursorColor;
}

// ── Card puissance ─────────────────────────────────────────────────────────────
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
class ConfigSheet extends StatefulWidget {
  final String currentUrl;
  final String currentPwd;
  final void Function(String url, String pwd) onSave;
  const ConfigSheet({super.key, required this.currentUrl, required this.currentPwd, required this.onSave});

  @override
  State<ConfigSheet> createState() => _ConfigSheetState();
}

class _ConfigSheetState extends State<ConfigSheet> {
  late TextEditingController _urlCtrl;
  late TextEditingController _pwdCtrl;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.currentUrl);
    _pwdCtrl = TextEditingController(text: widget.currentPwd);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFF5A6278)),
    filled: true,
    fillColor: const Color(0xFF0A0F1A),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFF97316)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24, right: 24, top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Configuration',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 2.5, color: Color(0xFF5A6278))),
          const SizedBox(height: 16),
          const Text('URL de l\'ESP32',
              style: TextStyle(fontSize: 13, color: Color(0xFF5A6278))),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 15, color: Color(0xFFE8EAF0)),
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: _inputDeco('http://192.168.1.X:PORT'),
          ),
          const SizedBox(height: 6),
          const Text('Avec http:// et le port si nécessaire',
              style: TextStyle(fontSize: 11, color: Color(0xFF5A6278))),
          const SizedBox(height: 16),
          const Text('Mot de passe (optionnel)',
              style: TextStyle(fontSize: 13, color: Color(0xFF5A6278))),
          const SizedBox(height: 8),
          TextField(
            controller: _pwdCtrl,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 15, color: Color(0xFFE8EAF0)),
            obscureText: true,
            autocorrect: false,
            decoration: _inputDeco('Laisser vide si aucun'),
          ),
          const SizedBox(height: 6),
          const Text('Requis pour le forçage ON/OFF',
              style: TextStyle(fontSize: 11, color: Color(0xFF5A6278))),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                var url = _urlCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
                if (!url.startsWith('http')) url = 'http://$url';
                widget.onSave(url, _pwdCtrl.text.trim());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF97316),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Connecter', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
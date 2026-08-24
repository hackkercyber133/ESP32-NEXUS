import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'theme_controller.dart';
import 'history_service.dart';
import 'schedule_service.dart';
import 'notification_service.dart';
import 'backup_service.dart';
import 'history_page.dart';
import 'schedule_page.dart';

// =======================================================================
// ===== MODEL: satu "Cooler" yang sudah dipasangkan (paired) dengan HP =====
// Supaya banyak HP & banyak cooler tidak tumbukan, setiap cooler dikenali
// lewat deviceId unik (dari chip ESP32-nya sendiri), bukan lewat topic
// global. HP hanya bisa kontrol cooler yang sudah eksplisit ditambahkan.
// =======================================================================
class Cooler {
  String id; // deviceId unik dari firmware, mis. "A1B2C3"
  String nickname; // nama custom dari user, mis. "Cooler Kamar"
  String mode; // "WiFi" (MQTT) atau "Bluetooth" (BLE)
  String? bleRemoteId; // MAC BLE, hanya diisi kalau mode == Bluetooth

  Cooler({required this.id, required this.nickname, required this.mode, this.bleRemoteId});

  Map<String, dynamic> toJson() =>
      {"id": id, "nickname": nickname, "mode": mode, "bleRemoteId": bleRemoteId};

  factory Cooler.fromJson(Map<String, dynamic> j) => Cooler(
        id: j["id"],
        nickname: j["nickname"],
        mode: j["mode"],
        bleRemoteId: j["bleRemoteId"],
      );
}

const String kAppVersion = "1.3.0";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.load();
  await NotificationService.init();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Dengarkan perubahan mode tema (terang/gelap) supaya seluruh app
    // langsung rebuild begitu user toggle di drawer.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Mod And TroubleShoot',
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: mode,
          home: SplashScreen(),
        );
      },
    );
  }
}

// =======================================================================
// ===== SPLASH SCREEN — ANIMASI PEMBUKA BERGAYA GAMING (MLBB/FF STYLE) ===
// =======================================================================
class _SplashParticle {
  final double x; // posisi horizontal awal (0..1)
  final double speed; // faktor kecepatan naik
  final double size; // ukuran partikel
  final double phase; // offset siklus awal (0..1)
  final double drift; // amplitudo goyangan horizontal

  _SplashParticle({
    required this.x,
    required this.speed,
    required this.size,
    required this.phase,
    required this.drift,
  });
}

class SplashScreen extends StatefulWidget {
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  // Controller utama: menjalankan urutan animasi satu-kali selama 5.2 detik.
  late final AnimationController _mainCtrl;
  // Controller loop: partikel, cincin energi, dan efek "shine" berjalan terus-menerus.
  late final AnimationController _loopCtrl;
  late final List<_SplashParticle> _particles;

  @override
  void initState() {
    super.initState();

    final rnd = Random(7);
    _particles = List.generate(42, (i) {
      return _SplashParticle(
        x: rnd.nextDouble(),
        speed: 0.35 + rnd.nextDouble() * 0.9,
        size: 1.2 + rnd.nextDouble() * 2.6,
        phase: rnd.nextDouble(),
        drift: rnd.nextDouble() * 18 - 9,
      );
    });

    _mainCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 15000));
    _loopCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 5000))..repeat();

    _mainCtrl.forward();
    _mainCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        Future.delayed(const Duration(milliseconds: 400), _goToApp);
      }
    });
  }

  void _goToApp() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 650),
        pageBuilder: (_, anim, __) => ControllerPage(),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween(begin: 1.06, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _loopCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color neon = Color(0xFF33F0FF);

    return Scaffold(
      backgroundColor: const Color(0xFF03040A),
      body: AnimatedBuilder(
        animation: Listenable.merge([_mainCtrl, _loopCtrl]),
        builder: (context, _) {
          final t = _mainCtrl.value.clamp(0.0, 1.0);
          final loop = _loopCtrl.value;

          double stage(double begin, double end, {Curve curve = Curves.linear}) {
            return curve.transform(Interval(begin, end, curve: Curves.linear).transform(t)).clamp(0.0, 1.0);
          }

          final ringIntro = stage(0.0, 0.45, curve: Curves.easeOutExpo);
          final logoScale = stage(0.05, 0.55, curve: Curves.elasticOut);
          final logoFade = stage(0.0, 0.30);
          final titleT = stage(0.35, 0.70, curve: Curves.easeOutCubic);
          final subtitleT = stage(0.50, 0.80, curve: Curves.easeOutCubic);
          final barT = stage(0.05, 0.97, curve: Curves.easeInOutSine);
          final flashT = stage(0.94, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              // latar gradasi radial gelap ala HUD game
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.1),
                    radius: 1.15,
                    colors: [Color(0xFF0C1B2A), Color(0xFF03040A)],
                  ),
                ),
              ),
              // partikel energi melayang naik
              CustomPaint(
                painter: _ParticlePainter(particles: _particles, loop: loop, color: neon),
                size: Size.infinite,
              ),
              // cincin gelombang energi di belakang logo
              Center(
                child: CustomPaint(
                  painter: _RingPainter(loopValue: loop, intro: ringIntro, color: neon),
                  size: const Size(320, 320),
                ),
              ),
              // bingkai hexagon berputar (efek "circuit")
              Center(
                child: Transform.rotate(
                  angle: loop * 2 * pi,
                  child: Opacity(
                    opacity: (0.28 * ringIntro).clamp(0.0, 0.28),
                    child: CustomPaint(
                      painter: _HexPainter(color: neon),
                      size: const Size(210, 210),
                    ),
                  ),
                ),
              ),
              // konten utama: logo, judul, subjudul, progress bar
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: logoFade,
                      child: Transform.scale(
                        scale: 0.4 + 0.6 * logoScale,
                        child: Container(
                          width: 108,
                          height: 108,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [neon.withOpacity(0.9), Colors.blueAccent.withOpacity(0.6)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: neon.withOpacity(0.5 + 0.25 * sin(loop * 2 * pi).abs()),
                                blurRadius: 42,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.ac_unit, color: Colors.white, size: 56),
                        ),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Opacity(
                      opacity: titleT,
                      child: Transform.translate(
                        offset: Offset(0, (1 - titleT) * 18),
                        child: ShaderMask(
                          shaderCallback: (bounds) {
                            final sweep = (loop * 2.4) % 2.4 - 0.7;
                            return LinearGradient(
                              colors: const [Colors.white, Color(0xFFBFF7FF), Colors.white],
                              stops: [
                                (sweep - 0.25).clamp(0.0, 1.0),
                                sweep.clamp(0.0, 1.0),
                                (sweep + 0.25).clamp(0.0, 1.0),
                              ],
                            ).createShader(bounds);
                          },
                          child: const Text(
                            'COOLER CONTROLLER',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Opacity(
                      opacity: subtitleT,
                      child: Text(
                        'GAME-GRADE VOLTAGE ENGINE',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 4,
                          color: neon.withOpacity(0.8),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 34),
                    Opacity(
                      opacity: barT > 0 ? 1 : 0,
                      child: Column(
                        children: [
                          Container(
                            width: 190,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: barT,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    gradient: LinearGradient(colors: [neon, Colors.blueAccent]),
                                    boxShadow: [BoxShadow(color: neon.withOpacity(0.7), blurRadius: 8)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'LOADING ${(barT * 100).toInt()}%',
                            style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // versi aplikasi di bagian bawah
              Positioned(
                bottom: 26,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: subtitleT,
                  child: Center(
                    child: Text(
                      'v$kAppVersion',
                      style: const TextStyle(color: Colors.white30, fontSize: 12, letterSpacing: 1),
                    ),
                  ),
                ),
              ),
              // kilatan putih halus saat transisi keluar dari splash
              if (flashT > 0)
                IgnorePointer(
                  child: Opacity(
                    opacity: (flashT * 0.85).clamp(0.0, 0.85),
                    child: Container(color: Colors.white),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  final List<_SplashParticle> particles;
  final double loop;
  final Color color;
  _ParticlePainter({required this.particles, required this.loop, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in particles) {
      final progress = (loop + p.phase) % 1.0;
      final y = size.height * (1 - progress);
      final x = p.x * size.width + sin((progress + p.phase) * 2 * pi) * p.drift;
      final opacity = sin(progress * pi).clamp(0.0, 1.0);
      paint.color = color.withOpacity(0.55 * opacity);
      canvas.drawCircle(Offset(x, y), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}

class _RingPainter extends CustomPainter {
  final double loopValue;
  final double intro;
  final Color color;
  _RingPainter({required this.loopValue, required this.intro, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    for (int i = 0; i < 3; i++) {
      final progress = (loopValue + i / 3) % 1.0;
      final radius = maxRadius * progress * intro;
      final opacity = ((1 - progress) * 0.5 * intro).clamp(0.0, 0.5);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withOpacity(opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => true;
}

class _HexPainter extends CustomPainter {
  final Color color;
  _HexPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (pi / 3) * i - pi / 2;
      final point = Offset(center.dx + radius * cos(angle), center.dy + radius * sin(angle));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HexPainter oldDelegate) => false;
}

class ControllerPage extends StatefulWidget {
  @override
  _ControllerPageState createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  // ===== DAFTAR COOLER YANG SUDAH DIPASANGKAN (persist ke HP) =====
  // Ini kuncinya supaya tidak tumbukan: app hanya mau ngirim perintah ke
  // cooler yang eksplisit ada di daftar ini (dikenali dari deviceId unik).
  List<Cooler> pairedCoolers = [];
  Cooler? activeCooler;

  // Getter kompatibilitas dengan kode lama yang masih pakai "connectionMode"
  String get connectionMode => activeCooler?.mode ?? "WiFi";

  // ===== TEMA WARNA (custom) =====
  Color accentColor = Colors.cyanAccent;
  final List<Color> colorPalette = [
    Colors.cyanAccent,
    Colors.purpleAccent,
    Colors.greenAccent,
    Colors.orangeAccent,
    Colors.pinkAccent,
    Colors.blueAccent,
    Colors.amberAccent,
    Colors.tealAccent,
    Colors.redAccent,
    Colors.lightGreenAccent,
  ];

  // ===== MQTT =====
  MqttServerClient? mqttClient;
  final String broker = "broker.emqx.io";
  // Topic sekarang per-cooler (pakai deviceId), BUKAN global lagi.
  // Ini kunci supaya HP A tidak bisa mengontrol Cooler B secara tidak sengaja.
  String get cmdTopic => "cooler/${activeCooler?.id}/command";
  String get statusTopic => "cooler/${activeCooler?.id}/status";

  // ===== BLUETOOTH =====
  BluetoothDevice? bleDevice;
  bool isScanning = false;
  List<ScanResult> scanResults = [];
  bool bleConnected = false;

  // ===== DATA VOLTASE =====
  // Hardware (board decoy PD3.1/QC3.0) mendukung 4 level tegangan
  // tetap secara fisik: 5V / 9V / 12V / 15V. Tidak ada mode kontinu.
  double setVolt = 5.0; // voltase yang sedang aktif/terkirim
  String ledMode = "off"; // "off" | "static" | "running" | "disco" | "bounce"
  String lastLedEffect = "running"; // efek terakhir dipilih, dipakai saat tombol ON
  String uptime = "00:00:00";
  String status = "🔴 Offline";

  // ===== WIFI SETUP =====
  List<Map<String, dynamic>> wifiList = [];
  bool isScanningWifi = false;
  String selectedSSID = "";
  TextEditingController passwordController = TextEditingController();

  // ===== JADWAL OTOMATIS & DETEKSI OFFLINE =====
  List<ScheduleRule> _schedules = [];
  Timer? _scheduleTimer;
  Timer? _offlineCheckTimer;
  DateTime? _lastOnlineAt;
  bool _offlineNotified = false;
  final int offlineThresholdMinutes = 5;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    _offlineCheckTimer?.cancel();
    mqttClient?.disconnect();
    super.dispose();
  }

  Future<void> _initApp() async {
    // Minta izin Bluetooth & Lokasi dulu (wajib di Android 12+), kalau tidak
    // diminta di sini, scan BLE akan gagal diam-diam.
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();

    await _loadPairedCoolers();
    _schedules = await ScheduleService.loadAll();

    // Cek jadwal tiap 30 detik, cek status offline tiap 1 menit — cukup
    // ringan tapi tetap responsif untuk kasus "jam 22:00 turun ke 5V".
    _scheduleTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkSchedules());
    _offlineCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkOfflineNotification());

    if (activeCooler != null) {
      _connectActiveCooler();
    }
  }

  // ===== JADWAL OTOMATIS: dicek berkala, kirim perintah kalau waktunya cocok =====
  void _checkSchedules() {
    if (activeCooler == null || _schedules.isEmpty) return;
    final now = DateTime.now();
    final todayKey = "${now.year}-${now.month}-${now.day}";
    bool changed = false;
    for (final r in _schedules) {
      if (!r.enabled || r.coolerId != activeCooler!.id) continue;
      if (!r.days.contains(now.weekday)) continue;
      if (r.hour != now.hour || r.minute != now.minute) continue;
      if (r.lastFiredDateKey == todayKey) continue; // sudah jalan hari ini
      r.lastFiredDateKey = todayKey;
      changed = true;
      sendVoltage(r.voltage);
      NotificationService.show(
        id: r.id.hashCode,
        title: "Jadwal Otomatis",
        body: "${activeCooler!.nickname}: voltase otomatis diubah ke ${r.voltage.toStringAsFixed(0)}V",
      );
    }
    if (changed) ScheduleService.saveAll(_schedules);
  }

  // ===== NOTIFIKASI COOLER OFFLINE =====
  void _checkOfflineNotification() {
    if (activeCooler == null) return;
    final online = status == "🟢 Online";
    if (online) {
      _lastOnlineAt = DateTime.now();
      _offlineNotified = false;
      return;
    }
    _lastOnlineAt ??= DateTime.now();
    final offlineFor = DateTime.now().difference(_lastOnlineAt!);
    if (!_offlineNotified && offlineFor.inMinutes >= offlineThresholdMinutes) {
      _offlineNotified = true;
      NotificationService.show(
        id: 9001,
        title: "Cooler Offline",
        body: "${activeCooler!.nickname} tidak terhubung selama lebih dari $offlineThresholdMinutes menit.",
      );
    }
  }

  // ===== PENYIMPANAN DAFTAR COOLER (persist antar sesi app) =====
  Future<void> _loadPairedCoolers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('paired_coolers');
    final lastActiveId = prefs.getString('active_cooler_id');
    if (raw != null) {
      List<dynamic> list = jsonDecode(raw);
      setState(() {
        pairedCoolers = list.map((e) => Cooler.fromJson(e)).toList();
        if (pairedCoolers.isNotEmpty) {
          activeCooler = pairedCoolers.firstWhere(
            (c) => c.id == lastActiveId,
            orElse: () => pairedCoolers.first,
          );
        }
      });
    }
  }

  Future<void> _savePairedCoolers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'paired_coolers', jsonEncode(pairedCoolers.map((c) => c.toJson()).toList()));
    if (activeCooler != null) {
      await prefs.setString('active_cooler_id', activeCooler!.id);
    }
  }

  // ===== SAMBUNGKAN KE COOLER YANG SEDANG AKTIF =====
  void _connectActiveCooler() {
    if (activeCooler == null) return;
    if (activeCooler!.mode == "WiFi") {
      connectMQTT();
    } else {
      _connectBleById(activeCooler!.bleRemoteId);
    }
  }

  Future<void> _connectBleById(String? remoteId) async {
    if (remoteId == null) return;
    try {
      final device = BluetoothDevice.fromId(remoteId);
      await connectBLE(device);
    } catch (e) {
      _showSnack("⚠️ Gagal konek ulang ke ${activeCooler?.nickname}, coba scan ulang");
    }
  }

  // ===== SWITCH COOLER AKTIF (dipanggil dari drawer) =====
  void switchActiveCooler(Cooler cooler) {
    // Putuskan koneksi cooler sebelumnya dulu supaya tidak nyangkut
    if (activeCooler?.mode == "Bluetooth" && bleDevice != null) {
      bleDevice!.disconnect();
    }
    if (activeCooler?.mode == "WiFi" && _mqttConnected) {
      mqttClient?.disconnect();
    }
    setState(() {
      activeCooler = cooler;
      status = "🔴 Offline";
      bleConnected = false;
    });
    _lastOnlineAt = null;
    _offlineNotified = false;
    _savePairedCoolers();
    _connectActiveCooler();
  }

  void removeCooler(Cooler cooler) {
    setState(() {
      pairedCoolers.removeWhere((c) => c.id == cooler.id);
      if (activeCooler?.id == cooler.id) {
        activeCooler = pairedCoolers.isNotEmpty ? pairedCoolers.first : null;
        status = "🔴 Offline";
      }
    });
    _savePairedCoolers();
    if (activeCooler != null) _connectActiveCooler();
  }

  void addCooler(Cooler cooler) {
    setState(() {
      pairedCoolers.removeWhere((c) => c.id == cooler.id); // hindari duplikat
      pairedCoolers.add(cooler);
      activeCooler = cooler;
      status = "🔴 Offline";
    });
    _savePairedCoolers();
    _connectActiveCooler();
  }

  // ===== MQTT =====
  void connectMQTT() async {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    // Client ID unik per-cooler per-sesi supaya tidak saling "menendang"
    // koneksi kalau ada beberapa HP nyambung ke broker yang sama.
    final clientId = 'flutter_${activeCooler!.id}_${DateTime.now().millisecondsSinceEpoch}';
    mqttClient = MqttServerClient(broker, clientId);
    mqttClient!.port = 1883;
    mqttClient!.keepAlivePeriod = 20;
    mqttClient!.onConnected = () {
      setState(() => status = "🟢 Online");
      mqttClient!.subscribe(statusTopic, MqttQos.atLeastOnce);
    };
    mqttClient!.onDisconnected = () {
      setState(() => status = "🔴 Offline");
      if (activeCooler != null) {
        HistoryService.recordStatus(coolerId: activeCooler!.id, online: false, voltage: setVolt);
      }
    };
    mqttClient!.updates!.listen((msgs) {
      final msg = msgs[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(msg.payload.message);
      try {
        var data = jsonDecode(payload);
        // Jaga-jaga: pastikan status ini benar dari cooler yang sedang aktif,
        // bukan nyasar dari cooler lain (mis. saat baru switch cooler).
        if (data['deviceId'] != null && data['deviceId'] != activeCooler?.id) return;
        setState(() {
          setVolt = (data['setVoltage'] ?? setVolt).toDouble();
          ledMode = data['ledMode'] ?? ledMode;
          uptime = data['uptime'] ?? "00:00:00";
          // Sinkronkan "efek terakhir" dari status device asli, supaya tombol
          // "Nyala" tidak salah kirim efek lama setelah reconnect/restart app.
          if (ledMode != "off") lastLedEffect = ledMode;
        });
        // Catat status ASLI ini ke riwayat pemakaian (data lokal di HP).
        if (activeCooler != null) {
          HistoryService.recordStatus(coolerId: activeCooler!.id, online: true, voltage: setVolt);
        }
      } catch (e) {}
    });
    try {
      await mqttClient!.connect();
    } catch (e) {
      setState(() => status = "🔴 Offline");
    }
  }

  bool get _mqttConnected =>
      mqttClient != null &&
      mqttClient!.connectionStatus!.state == MqttConnectionState.connected;

  void sendCommandMQTT(double volt) async {
    if (!_mqttConnected) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Tidak terhubung ke broker MQTT");
      return;
    }
    var builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"voltage": volt}));
    mqttClient!.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!);
    setState(() {
      setVolt = volt;
    });
  }

  void sendLedCommandMQTT(String mode) async {
    if (!_mqttConnected) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Tidak terhubung ke broker MQTT");
      return;
    }
    var builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"ledMode": mode}));
    mqttClient!.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!);
    setState(() {
      ledMode = mode;
    });
  }

  // ===== BLUETOOTH =====
  void scanBLE({VoidCallback? onUpdate}) async {
    setState(() {
      isScanning = true;
      scanResults.clear();
    });
    onUpdate?.call();
    FlutterBluePlus.startScan(timeout: Duration(seconds: 5));
    FlutterBluePlus.onScanResults.listen((results) {
      setState(() {
        // Nama unik per-unit ("ESP32-Cooler-XXXXXX") -> tiap fisik cooler
        // muncul sebagai entri terpisah di daftar, tidak bakal ketuker.
        scanResults =
            results.where((r) => r.device.platformName.contains("ESP32-Cooler-")).toList();
      });
      onUpdate?.call();
    });
    await Future.delayed(Duration(seconds: 6));
    setState(() {
      isScanning = false;
    });
    onUpdate?.call();
  }

  // Ambil ID unik cooler dari nama BLE-nya, mis. "ESP32-Cooler-A1B2C3" -> "A1B2C3"
  String extractDeviceId(String bleName) {
    final parts = bleName.split("ESP32-Cooler-");
    return parts.length > 1 ? parts[1].trim() : bleName;
  }

  Future<void> connectBLE(BluetoothDevice device) async {
    try {
      await device.connect();
      setState(() {
        bleDevice = device;
        bleConnected = true;
        status = "🟢 Online";
      });
      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.setNotifyValue(true);
            characteristic.onValueReceived.listen((value) {
              String payload = utf8.decode(value);
              try {
                var data = jsonDecode(payload);
                if (data['deviceId'] != null && data['deviceId'] != activeCooler?.id) return;
                setState(() {
                  setVolt = (data['setVoltage'] ?? setVolt).toDouble();
                  ledMode = data['ledMode'] ?? ledMode;
                  uptime = data['uptime'] ?? "00:00:00";
                  if (ledMode != "off") lastLedEffect = ledMode;
                });
                if (activeCooler != null) {
                  HistoryService.recordStatus(coolerId: activeCooler!.id, online: true, voltage: setVolt);
                }
              } catch (e) {}
            });
          }
        }
      }
    } catch (e) {
      setState(() {
        bleConnected = false;
        status = "🔴 Offline";
      });
      if (activeCooler != null) {
        HistoryService.recordStatus(coolerId: activeCooler!.id, online: false, voltage: setVolt);
      }
    }
  }

  void sendCommandBLE(double volt) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    try {
      List<BluetoothService> services = await bleDevice!.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.write(utf8.encode(jsonEncode({"voltage": volt})));
            setState(() {
              setVolt = volt;
            });
            return;
          }
        }
      }
    } catch (e) {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLedCommandBLE(String mode) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    try {
      List<BluetoothService> services = await bleDevice!.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.write(utf8.encode(jsonEncode({"ledMode": mode})));
            setState(() {
              ledMode = mode;
            });
            return;
          }
        }
      }
    } catch (e) {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLed(String mode) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    if (mode != "off") lastLedEffect = mode; // ingat efek terakhir buat tombol ON
    if (connectionMode == "WiFi") {
      sendLedCommandMQTT(mode);
    } else {
      sendLedCommandBLE(mode);
    }
  }

  void sendVoltage(double volt) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    volt = double.parse(volt.toStringAsFixed(1));
    if (connectionMode == "WiFi") {
      sendCommandMQTT(volt);
    } else {
      sendCommandBLE(volt);
    }
  }

  // ===== WIFI SETUP =====
  Future<void> scanWiFi() async {
    setState(() {
      isScanningWifi = true;
      wifiList.clear();
    });
    try {
      var response =
          await http.get(Uri.parse("http://192.168.4.1/scanwifi")).timeout(Duration(seconds: 5));
      if (response.statusCode == 200) {
        if (response.body.contains("scanning")) {
          await Future.delayed(Duration(seconds: 3));
          await scanWiFi();
          return;
        }
        List<dynamic> data = jsonDecode(response.body);
        setState(() {
          wifiList = data.map((e) => {"ssid": e['ssid'], "rssi": e['rssi']}).toList();
          isScanningWifi = false;
        });
      }
    } catch (e) {
      setState(() {
        isScanningWifi = false;
      });
      _showSnack("⚠️ Pastikan HP terhubung ke ESP32-Config");
    }
  }

  Future<void> connectWiFi(String ssid, String password) async {
    try {
      // Pakai Uri.http(...) dengan Map query parameters supaya ssid/password
      // otomatis di-encode dengan benar (sebelumnya string mentah disambung
      // langsung, jadi rusak kalau ssid/password ada spasi atau karakter
      // spesial seperti & + # %).
      var url = Uri.http("192.168.4.1", "/setwifi", {"ssid": ssid, "password": password});
      var response = await http.get(url);
      if (response.statusCode == 200) {
        _showSnack("✅ ESP32 berhasil terhubung ke $ssid");
        Navigator.pop(context);
        await Future.delayed(Duration(seconds: 5));
        connectMQTT();
      } else {
        _showSnack("❌ Gagal terhubung, coba lagi");
      }
    } catch (e) {
      _showSnack("⚠️ Pastikan HP terhubung ke ESP32-Config");
    }
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ===== EXPORT / IMPORT KONFIGURASI =====
  void _showBackupDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF12181f),
        title: Text("Export / Import Konfigurasi", style: TextStyle(color: Colors.white)),
        content: Text(
          "Export: simpan daftar cooler, tema, dan jadwal otomatis ke file .json di penyimpanan app.\n\n"
          "Import: baca file .json backup dan gantikan konfigurasi yang sedang dipakai sekarang.",
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text("Batal")),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _doImportConfig();
            },
            child: Text("Import", style: TextStyle(color: Colors.orangeAccent)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: accentColor),
            onPressed: () async {
              Navigator.pop(ctx);
              await _doExportConfig();
            },
            child: Text("Export", style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  Future<void> _doExportConfig() async {
    try {
      final schedules = await ScheduleService.loadAll();
      final payload = BackupService.buildPayload(
        coolers: pairedCoolers.map((c) => c.toJson()).toList(),
        accentColorValue: accentColor.value,
        themeMode: ThemeController.isDark ? "dark" : "light",
        schedules: schedules.map((s) => s.toJson()).toList(),
      );
      final path = await BackupService.exportToFile(payload);
      _showSnack("✅ Backup tersimpan di: $path");
    } catch (e) {
      _showSnack("❌ Gagal export konfigurasi: $e");
    }
  }

  Future<void> _doImportConfig() async {
    final payload = await BackupService.importFromFile();
    if (payload == null) {
      _showSnack("⚠️ Import dibatalkan atau file tidak valid");
      return;
    }
    try {
      final coolersJson = (payload["coolers"] as List?) ?? [];
      final importedCoolers = coolersJson.map((e) => Cooler.fromJson(e)).toList();
      final importedAccent = payload["accentColor"] as int?;
      final importedTheme = payload["themeMode"] as String?;
      final schedulesJson = (payload["schedules"] as List?) ?? [];
      final importedSchedules = schedulesJson.map((e) => ScheduleRule.fromJson(e)).toList();

      // Putuskan koneksi lama sebelum daftar cooler diganti total.
      if (activeCooler?.mode == "Bluetooth" && bleDevice != null) {
        bleDevice!.disconnect();
      }
      if (activeCooler?.mode == "WiFi" && _mqttConnected) {
        mqttClient?.disconnect();
      }

      setState(() {
        pairedCoolers = importedCoolers;
        if (importedAccent != null) accentColor = Color(importedAccent);
        activeCooler = pairedCoolers.isNotEmpty ? pairedCoolers.first : null;
        status = "🔴 Offline";
      });
      await _savePairedCoolers();
      await ScheduleService.saveAll(importedSchedules);
      _schedules = importedSchedules;
      if (importedTheme != null) {
        await ThemeController.setDark(importedTheme != "light");
      }
      if (activeCooler != null) _connectActiveCooler();
      _showSnack("✅ Konfigurasi berhasil diimport (${importedCoolers.length} cooler)");
    } catch (e) {
      _showSnack("❌ File backup tidak valid: $e");
    }
  }

  // ===== CACHE =====
  void clearAppCache() {
    setState(() {
      wifiList.clear();
      scanResults.clear();
      selectedSSID = "";
      passwordController.clear();
    });
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack("🧹 Cache aplikasi berhasil dibersihkan");
  }

  void clearEsp32Cache() {
    if (connectionMode == "WiFi") {
      if (_mqttConnected) {
        var builder = MqttClientPayloadBuilder();
        builder.addString(jsonEncode({"action": "clear_cache"}));
        mqttClient!.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!);
        _showSnack("🧹 Perintah bersihkan cache modul ESP32 terkirim");
      } else {
        _showSnack("⚠️ Tidak terhubung ke ESP32, cache tidak bisa dibersihkan");
      }
    } else {
      if (bleConnected) {
        sendBLERaw({"action": "clear_cache"});
        _showSnack("🧹 Perintah bersihkan cache modul ESP32 terkirim");
      } else {
        _showSnack("⚠️ Tidak terhubung ke ESP32, cache tidak bisa dibersihkan");
      }
    }
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> sendBLERaw(Map<String, dynamic> payload) async {
    if (!bleConnected || bleDevice == null) return;
    try {
      List<BluetoothService> services = await bleDevice!.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.write(utf8.encode(jsonEncode(payload)));
            return;
          }
        }
      }
    } catch (e) {}
  }

  // ===== DIALOG: SETUP WIFI =====
  void showWiFiSetupDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          return AlertDialog(
            backgroundColor: Color(0xFF11161f),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.wifi, color: accentColor),
                SizedBox(width: 8),
                Expanded(
                    child: Text("Hubungkan Internet ESP32",
                        style: TextStyle(color: Colors.white, fontSize: 16))),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 380,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text("📶 WiFi di sekitar",
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white70)),
                      ),
                      IconButton(
                        icon: Icon(Icons.refresh, color: accentColor),
                        onPressed: () => scanWiFi(),
                      ),
                    ],
                  ),
                  Expanded(
                    child: isScanningWifi
                        ? Center(child: CircularProgressIndicator(color: accentColor))
                        : wifiList.isEmpty
                            ? Center(
                                child: Text(
                                    "Tidak ada WiFi ditemukan\nPastikan HP terhubung ke ESP32-Config",
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white54)))
                            : ListView.builder(
                                itemCount: wifiList.length,
                                itemBuilder: (ctx, index) {
                                  var wifi = wifiList[index];
                                  bool isSelected = selectedSSID == wifi['ssid'];
                                  return Card(
                                    color: isSelected ? accentColor.withOpacity(0.15) : Colors.grey.shade900,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      side: BorderSide(
                                          color: isSelected ? accentColor : Colors.transparent, width: 1.4),
                                    ),
                                    child: ListTile(
                                      leading: Icon(Icons.wifi, color: accentColor),
                                      title: Text(wifi['ssid'], style: TextStyle(color: Colors.white)),
                                      trailing:
                                          Text("${wifi['rssi']}dBm", style: TextStyle(color: Colors.grey)),
                                      onTap: () {
                                        setStateDialog(() {
                                          selectedSSID = wifi['ssid'];
                                        });
                                      },
                                    ),
                                  );
                                },
                              ),
                  ),
                  if (selectedSSID.isNotEmpty) ...[
                    Divider(color: Colors.white24),
                    TextField(
                      controller: passwordController,
                      style: TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Password WiFi",
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: Colors.white24)),
                        focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: accentColor)),
                      ),
                      obscureText: true,
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          if (passwordController.text.isNotEmpty) {
                            connectWiFi(selectedSSID, passwordController.text);
                          } else {
                            _showSnack("Masukkan password!");
                          }
                        },
                        child: Text("🔗 Hubungkan"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentColor,
                          foregroundColor: Colors.black,
                          padding: EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Tutup", style: TextStyle(color: accentColor)),
              ),
            ],
          );
        },
      ),
    );
  }

  // ===== DIALOG: ABOUT / CHANGELOG =====
  void showAboutChangelogDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF11161f),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.info_outline, color: accentColor),
            SizedBox(width: 8),
            Text("About", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: SingleChildScrollView(
          child: DefaultTextStyle(
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Cooler Controller App",
                    style: TextStyle(color: accentColor, fontSize: 16, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Version: $kAppVersion"),
                Divider(color: Colors.white24, height: 20),
                Text("Developer", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Nama: Apri Ansyah"),
                Text("Telegram Dev: t.me/bujanginm"),
                Text("Group Telegram:"),
                Text("https://t.me/forumdiskusitele/371474"),
                Divider(color: Colors.white24, height: 20),
                Text("Tujuan Aplikasi", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text(
                    "Aplikasi ini dibuat hanya untuk tujuan edukasi/pembelajaran, mengenai cara kerja fan cooler apabila dikontrol menggunakan aplikasi."),
                Divider(color: Colors.white24, height: 20),
                Text("Cara Penggunaan (Dari Awal sampai Selesai)",
                    style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 6),
                Text("A. Persiapan Awal",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "1. Pastikan modul ESP32-C3 sudah terpasang & menyala (lampu indikator hidup).\n"
                    "2. Buka aplikasi ini, lalu izinkan permission Bluetooth & Lokasi saat diminta (wajib supaya fitur scan Bluetooth berfungsi)."),
                SizedBox(height: 8),
                Text("B. Menghubungkan ESP32 ke WiFi Rumah (sekali saja)",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "3. Kalau ESP32 belum pernah disetel WiFi, dia otomatis memancarkan hotspot bernama \"ESP32-Config\" (password: 12345678). Sambungkan WiFi HP ke hotspot itu dulu.\n"
                    "4. Di aplikasi, buka menu ☰ (kanan atas / drawer) → \"Setup WiFi ESP32\".\n"
                    "5. Tekan ikon refresh untuk scan WiFi sekitar, pilih nama WiFi rumah dari daftar, masukkan passwordnya, lalu tekan \"🔗 Hubungkan\".\n"
                    "6. Tunggu notifikasi berhasil terhubung. ESP32 akan restart & tersambung ke WiFi rumah, status akan berubah jadi \"🟢 Online\"."),
                SizedBox(height: 8),
                Text("C. Menambahkan Cooler ke Aplikasi",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "7. Buka menu ☰ → \"Tambah Cooler Baru\".\n"
                    "8. Isi nama cooler (bebas, mis. \"Cooler Kamar\").\n"
                    "9. Pilih salah satu cara pairing:\n"
                    "   • Scan Bluetooth: tunggu daftar perangkat muncul, ketuk perangkat yang sesuai.\n"
                    "   • Manual (WiFi): masukkan ID Perangkat (dilihat di layar Setup WiFi ESP32 / serial monitor), lalu tekan \"Tambah\".\n"
                    "10. Cooler yang baru ditambahkan otomatis jadi cooler aktif (bisa dicek/diganti lewat menu ☰ → \"Cooler Saya\")."),
                SizedBox(height: 8),
                Text("D. Mengatur Voltase Kipas",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "11. Pastikan status di atas menunjukkan \"🟢 Online\" (cooler sudah terhubung).\n"
                    "12. Di halaman utama, pilih salah satu preset tegangan: 5V / 9V / 12V / 15V.\n"
                    "13. Tekan tombol \"Pilih\" pada preset yang diinginkan — tombol akan berubah jadi \"Terpilih\" dan kipas akan menyesuaikan tegangan.\n"
                    "14. Selesai — kipas kini berjalan sesuai voltase yang dipilih."),
                SizedBox(height: 8),
                Text("E. Fitur Tambahan (opsional)",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "• Ganti warna tema aplikasi lewat menu ☰ → \"Tampilan\".\n"
                    "• \"Bersihkan Cache Aplikasi\" untuk menghapus data scan WiFi/Bluetooth sementara.\n"
                    "• \"Bersihkan Cache Modul ESP32\" untuk kirim perintah reset cache ke ESP32.\n"
                    "• Bisa menambahkan & berpindah antar beberapa cooler lewat menu ☰ → \"Cooler Saya\"."),
                Divider(color: Colors.white24, height: 20),
                Text("Status", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Aplikasi ini FREE dan TIDAK untuk diperjualbelikan."),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Tutup", style: TextStyle(color: accentColor)),
          ),
        ],
      ),
    );
  }

  // ===== DIALOG: KONFIRMASI CACHE =====
  void _confirmClear(String title, String message, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF11161f),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: TextStyle(color: Colors.white)),
        content: Text(message, style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Batal", style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: onConfirm,
            style: ElevatedButton.styleFrom(backgroundColor: accentColor, foregroundColor: Colors.black),
            child: Text("Ya, Bersihkan"),
          ),
        ],
      ),
    );
  }

  // ===== DRAWER (MENU GARIS 3) =====
  // ===== DIALOG: TAMBAH COOLER BARU =====
  // Dua cara: (1) scan Bluetooth lalu pilih unit fisik yang mau dipasangkan,
  // atau (2) masukkan manual ID cooler (dari layar Setup WiFi ESP32 / serial
  // monitor) untuk dikontrol lewat WiFi/MQTT.
  void showAddCoolerDialog() {
    final nicknameController = TextEditingController();
    final manualIdController = TextEditingController();
    int tab = 0; // 0 = Bluetooth, 1 = Manual (WiFi)
    bool scanStarted = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (!scanStarted) {
            scanStarted = true;
            // Baru mulai scan setelah dialog ini benar-benar terbentuk, supaya
            // update hasil scan (lewat onUpdate di bawah) bisa memicu
            // setDialogState -> dialog ikut rebuild. Kalau scan dimulai
            // sebelum showDialog (seperti sebelumnya), hasil scan yang masuk
            // belakangan hanya me-rebuild widget utama, bukan dialog ini,
            // sehingga dialog macet selamanya di "Mencari cooler di sekitar...".
            WidgetsBinding.instance.addPostFrameCallback((_) {
              scanBLE(onUpdate: () {
                if (ctx.mounted) setDialogState(() {});
              });
            });
          }
          return AlertDialog(
            backgroundColor: Color(0xFF11161f),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text("Tambah Cooler Baru", style: TextStyle(color: Colors.white)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nicknameController,
                      style: TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Nama cooler (mis. Cooler Kamar)",
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      ),
                    ),
                    SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: Text("Scan Bluetooth"),
                            selected: tab == 0,
                            onSelected: (_) => setDialogState(() => tab = 0),
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: ChoiceChip(
                            label: Text("Manual (WiFi)"),
                            selected: tab == 1,
                            onSelected: (_) => setDialogState(() => tab = 1),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 14),
                    if (tab == 0) ...[
                      if (isScanning)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(children: [
                            SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: accentColor)),
                            SizedBox(width: 10),
                            Text("Mencari cooler di sekitar...", style: TextStyle(color: Colors.white54)),
                          ]),
                        ),
                      if (!isScanning && scanResults.isEmpty)
                        Text("Tidak ada cooler ditemukan. Pastikan Bluetooth aktif & cooler menyala.",
                            style: TextStyle(color: Colors.white38, fontSize: 12)),
                      ...scanResults.map((r) {
                        final id = extractDeviceId(r.device.platformName);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.bluetooth, color: accentColor),
                          title: Text(r.device.platformName, style: TextStyle(color: Colors.white)),
                          subtitle: Text("ID: $id", style: TextStyle(color: Colors.white38, fontSize: 11)),
                          onTap: () async {
                            String nickname =
                                nicknameController.text.trim().isEmpty ? r.device.platformName : nicknameController.text.trim();
                            Navigator.pop(ctx);
                            final cooler = Cooler(
                                id: id, nickname: nickname, mode: "Bluetooth", bleRemoteId: r.device.remoteId.str);
                            addCooler(cooler);
                            await connectBLE(r.device);
                          },
                        );
                      }).toList(),
                      TextButton.icon(
                        onPressed: () => scanBLE(onUpdate: () {
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        icon: Icon(Icons.refresh, color: accentColor, size: 18),
                        label: Text("Scan ulang", style: TextStyle(color: accentColor)),
                      ),
                    ] else ...[
                      Text(
                        "Buka menu \"Setup WiFi ESP32\" atau layar konfigurasi cooler (192.168.4.1) untuk melihat ID Perangkat-nya, lalu masukkan di sini.",
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      SizedBox(height: 10),
                      TextField(
                        controller: manualIdController,
                        style: TextStyle(color: Colors.white, letterSpacing: 2),
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: "ID Perangkat (mis. A1B2C3)",
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Batal", style: TextStyle(color: Colors.white54)),
              ),
              if (tab == 1)
                TextButton(
                  onPressed: () {
                    final id = manualIdController.text.trim().toUpperCase();
                    if (id.isEmpty) {
                      _showSnack("Masukkan ID Perangkat dulu!");
                      return;
                    }
                    String nickname =
                        nicknameController.text.trim().isEmpty ? "Cooler $id" : nicknameController.text.trim();
                    Navigator.pop(ctx);
                    addCooler(Cooler(id: id, nickname: nickname, mode: "WiFi"));
                  },
                  child: Text("Tambah", style: TextStyle(color: accentColor)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDrawer() {
    final isDark = ThemeController.isDark;
    return Drawer(
      backgroundColor: AppColors.surface(isDark),
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(20, 28, 20, 20),
              decoration: BoxDecoration(color: Colors.black26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.ac_unit, color: accentColor, size: 34),
                  SizedBox(height: 10),
                  Text("Cooler Controller",
                      style: TextStyle(color: AppColors.text(isDark), fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 2),
                  Text(
                      activeCooler != null
                          ? "${activeCooler!.nickname} • $status"
                          : status,
                      style: TextStyle(
                          fontSize: 12,
                          color: status == "🟢 Online" ? Colors.greenAccent : Colors.redAccent)),
                ],
              ),
            ),
            _drawerSectionTitle("Cooler Saya"),
            if (pairedCoolers.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  "Belum ada cooler yang ditambahkan. Tambah dulu supaya HP ini tahu cooler mana yang mau dikontrol.",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 12),
                ),
              ),
            ...pairedCoolers.map((cooler) {
              bool selected = activeCooler?.id == cooler.id;
              return ListTile(
                leading: Icon(cooler.mode == "WiFi" ? Icons.wifi : Icons.bluetooth,
                    color: selected ? accentColor : AppColors.textFaint(isDark)),
                title: Text(cooler.nickname,
                    style: TextStyle(
                        color: AppColors.text(isDark),
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                subtitle: Text("ID: ${cooler.id} • ${cooler.mode}",
                    style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) Icon(Icons.check_circle, color: accentColor, size: 20),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: AppColors.textFaint(isDark), size: 20),
                      onPressed: () {
                        Navigator.pop(context);
                        removeCooler(cooler);
                      },
                    ),
                  ],
                ),
                onTap: () {
                  Navigator.pop(context);
                  if (!selected) switchActiveCooler(cooler);
                },
              );
            }).toList(),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    side: BorderSide(color: accentColor),
                  ),
                  icon: Icon(Icons.add),
                  label: Text("Tambah Cooler Baru"),
                  onPressed: () {
                    Navigator.pop(context);
                    showAddCoolerDialog();
                  },
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.settings_ethernet, color: AppColors.textFaint(isDark)),
              title: Text("Setup WiFi ESP32", style: TextStyle(color: AppColors.text(isDark))),
              onTap: () {
                Navigator.pop(context);
                showWiFiSetupDialog();
              },
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Data & Otomasi"),
            ListTile(
              leading: Icon(Icons.bar_chart, color: AppColors.textFaint(isDark)),
              title: Text("Riwayat Pemakaian", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Grafik voltase & durasi nyala per hari",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                if (activeCooler == null) {
                  _showSnack("⚠️ Pilih atau tambah cooler dulu");
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HistoryPage(
                      coolerId: activeCooler!.id,
                      coolerName: activeCooler!.nickname,
                      accentColor: accentColor,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.schedule, color: AppColors.textFaint(isDark)),
              title: Text("Jadwal Otomatis", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Atur perubahan voltase otomatis per jam",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () async {
                Navigator.pop(context);
                if (activeCooler == null) {
                  _showSnack("⚠️ Pilih atau tambah cooler dulu");
                  return;
                }
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SchedulePage(
                      coolerId: activeCooler!.id,
                      accentColor: accentColor,
                      availableVoltages: const [5.0, 9.0, 12.0, 15.0],
                    ),
                  ),
                );
                // Muat ulang cache jadwal yang dipakai timer background.
                _schedules = await ScheduleService.loadAll();
              },
            ),
            ListTile(
              leading: Icon(Icons.import_export, color: AppColors.textFaint(isDark)),
              title: Text("Export / Import Konfigurasi", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Backup daftar cooler & tema ke file .json",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                _showBackupDialog();
              },
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Tampilan"),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(isDark ? Icons.dark_mode : Icons.light_mode, color: AppColors.textFaint(isDark), size: 18),
                  SizedBox(width: 8),
                  Text("Mode Gelap", style: TextStyle(color: AppColors.text(isDark), fontSize: 13)),
                  Spacer(),
                  Switch(
                    value: isDark,
                    activeColor: accentColor,
                    onChanged: (v) async {
                      await ThemeController.setDark(v);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: colorPalette.map((c) {
                  bool selected = accentColor.value == c.value;
                  return GestureDetector(
                    onTap: () => setState(() => accentColor = c),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: selected ? AppColors.text(isDark) : Colors.transparent, width: 3),
                      ),
                      child: selected ? Icon(Icons.check, size: 16, color: Colors.black) : null,
                    ),
                  );
                }).toList(),
              ),
            ),
            SizedBox(height: 16),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Perawatan"),
            ListTile(
              leading: Icon(Icons.cleaning_services, color: AppColors.textFaint(isDark)),
              title: Text("Bersihkan Cache Aplikasi", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Hapus data sementara di aplikasi",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () => _confirmClear(
                  "Bersihkan Cache Aplikasi",
                  "Data pencarian WiFi/Bluetooth sementara akan dihapus. Lanjutkan?",
                  clearAppCache),
            ),
            ListTile(
              leading: Icon(Icons.memory, color: AppColors.textFaint(isDark)),
              title: Text("Bersihkan Cache Modul ESP32", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Kirim perintah reset cache ke modul ESP32",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () => _confirmClear(
                  "Bersihkan Cache Modul ESP32",
                  "Perintah pembersihan cache akan dikirim ke modul ESP32 melalui koneksi $connectionMode. Lanjutkan?",
                  clearEsp32Cache),
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Developer"),
            ListTile(
              leading: Icon(Icons.code_rounded, color: AppColors.textFaint(isDark)),
              title: Text("NEXUS DEV", style: TextStyle(color: AppColors.text(isDark), fontWeight: FontWeight.w700)),
              subtitle: Text("Developer aplikasi & firmware", style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
            ),
            ListTile(
              leading: Icon(Icons.send_rounded, color: AppColors.textFaint(isDark)),
              title: Text("Telegram Developer", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("@your_username", style: TextStyle(color: accentColor, fontSize: 11)),
            ),
            ListTile(
              leading: Icon(Icons.groups_rounded, color: AppColors.textFaint(isDark)),
              title: Text("Group Developer", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("@your_group", style: TextStyle(color: accentColor, fontSize: 11)),
            ),
            ListTile(
              leading: Icon(Icons.info_outline_rounded, color: AppColors.textFaint(isDark)),
              title: Text("Tujuan Aplikasi", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Kontrol dan monitoring ESP32-C3 Mini dengan mode 5V / 9V / 12V / 15V.", style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Lainnya"),
            ListTile(
              leading: Icon(Icons.info_outline, color: AppColors.textFaint(isDark)),
              title: Text("Tentang", style: TextStyle(color: AppColors.text(isDark))),
              onTap: () {
                Navigator.pop(context);
                showAboutChangelogDialog(context);
              },
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _drawerSectionTitle(String text) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              color: AppColors.textFaint(ThemeController.isDark),
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.bold)),
    );
  }

  // ===== UI UTAMA: ESP32 NEXUS GAMING 2026 =====
  @override
  Widget build(BuildContext context) {
    final isDark = ThemeController.isDark;
    final online = status == "🟢 Online";
    final bg = AppColors.bg(isDark);
    final surface = AppColors.surface(isDark);
    return Scaffold(
      backgroundColor: bg,
      endDrawer: _buildDrawer(),
      appBar: AppBar(
        backgroundColor: surface.withOpacity(.94),
        elevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 18,
        title: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: accentColor.withOpacity(.12),
              border: Border.all(color: accentColor.withOpacity(.25)),
            ),
            child: Icon(Icons.memory_rounded, color: accentColor),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ESP32 NEXUS', style: TextStyle(color: AppColors.text(isDark), fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.0)),
            Text('GAMING CONTROL • 2026', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8, letterSpacing: 1.4)),
          ]),
        ]),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: (online ? Colors.greenAccent : Colors.redAccent).withOpacity(.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: (online ? Colors.greenAccent : Colors.redAccent).withOpacity(.3)),
            ),
            child: Row(children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: online ? Colors.greenAccent : Colors.redAccent, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(online ? 'ONLINE' : 'OFFLINE', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: online ? Colors.greenAccent : Colors.redAccent)),
            ]),
          ),
          Builder(builder: (ctx) => IconButton(
            tooltip: 'Menu',
            icon: Icon(Icons.menu_rounded, color: accentColor, size: 30),
            onPressed: () => Scaffold.of(ctx).openEndDrawer(),
          )),
        ],
      ),
      body: Stack(children: [
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _NexusGridPainter(accentColor)))),
        SafeArea(child: RefreshIndicator(
          color: accentColor,
          onRefresh: () async { if (activeCooler != null) _connectActiveCooler(); await Future.delayed(const Duration(milliseconds: 500)); },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              _nexusTicker(isDark),
              const SizedBox(height: 12),
              _nexusDeviceCard(isDark, online),
              const SizedBox(height: 12),
              _nexusHero(isDark, online),
              const SizedBox(height: 12),
              _nexusVoltageGrid(isDark),
              const SizedBox(height: 12),
              _nexusMetrics(isDark),
              const SizedBox(height: 12),
              _nexusRgbCard(isDark),
              const SizedBox(height: 12),
              _nexusQuickMenu(isDark),
              const SizedBox(height: 12),
              _nexusConnectionActions(isDark),
              const SizedBox(height: 20),
              Center(child: Text('ESP32-C3 MINI • PD3.1 / QC3.0 • LOCAL CONTROL', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8, letterSpacing: 1.4))),
            ],
          ),
        )),
      ]),
    );
  }

  Widget _nexusTicker(bool isDark) {
    return Container(
      height: 38,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: accentColor.withOpacity(.045),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: accentColor.withOpacity(.18)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(children: [
          _tickerChip('5V', 'ECO', Colors.greenAccent),
          _tickerChip('9V', 'BOOST', Colors.amberAccent),
          _tickerChip('12V', 'TURBO', Colors.purpleAccent),
          _tickerChip('15V', 'OVERDRIVE', Colors.redAccent),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('NEXUS CONTROL CORE', style: TextStyle(color: accentColor, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.5))),
        ]),
      ),
    );
  }

  Widget _tickerChip(String v, String label, Color c) => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: Text('• $v $label', style: TextStyle(color: c, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1)),
  );

  Widget _nexusDeviceCard(bool isDark, bool online) {
    return _nexusCard(isDark, child: Row(children: [
      Icon(connectionMode == 'WiFi' ? Icons.wifi_rounded : Icons.bluetooth_rounded, color: accentColor),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(activeCooler?.nickname ?? 'NO DEVICE SELECTED', style: TextStyle(color: AppColors.text(isDark), fontWeight: FontWeight.w900, fontSize: 12)),
        Text(activeCooler == null ? 'Tambahkan ESP32 melalui menu' : 'ID ${activeCooler!.id} • $connectionMode', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9)),
      ])),
      IconButton(onPressed: () { if (activeCooler == null) showAddCoolerDialog(); else _connectActiveCooler(); }, icon: Icon(activeCooler == null ? Icons.add_link : Icons.sync_rounded, color: accentColor)),
    ]));
  }

  Widget _nexusHero(bool isDark, bool online) {
    final modeLabel = setVolt == 5 ? 'ECO' : setVolt == 9 ? 'BOOST' : setVolt == 12 ? 'TURBO' : 'OVERDRIVE';
    final c = setVolt == 5 ? Colors.greenAccent : setVolt == 9 ? Colors.amberAccent : setVolt == 12 ? Colors.purpleAccent : Colors.redAccent;
    return _nexusCard(isDark, accent: c, child: Column(children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CURRENT MODE', style: TextStyle(color: c, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 6),
          Text('${setVolt.toStringAsFixed(0)}V $modeLabel', style: TextStyle(color: AppColors.text(isDark), fontSize: 28, fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          Text(online ? 'CONTROL LINK ESTABLISHED' : 'WAITING FOR DEVICE LINK', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9, letterSpacing: 1)),
        ])),
        SizedBox(width: 92, height: 92, child: Stack(alignment: Alignment.center, children: [
          CircularProgressIndicator(value: setVolt / 15.0, strokeWidth: 7, backgroundColor: c.withOpacity(.08), color: c),
          Icon(Icons.bolt_rounded, color: c, size: 32),
        ])),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: _miniMetric(isDark, 'VOLTAGE', '${setVolt.toStringAsFixed(0)}V', c)),
        Expanded(child: _miniMetric(isDark, 'UPTIME', uptime, accentColor)),
        Expanded(child: _miniMetric(isDark, 'LINK', online ? 'READY' : '--', online ? Colors.greenAccent : Colors.redAccent)),
      ]),
    ]));
  }

  Widget _miniMetric(bool isDark, String label, String value, Color c) => Column(children: [
    Text(label, style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 7, letterSpacing: 1.3)),
    const SizedBox(height: 5),
    Text(value, overflow: TextOverflow.ellipsis, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w900)),
  ]);

  Widget _nexusVoltageGrid(bool isDark) {
    final modes = <Map<String, dynamic>>[
      {'v': 5.0, 'label': 'ECO', 'c': Colors.greenAccent},
      {'v': 9.0, 'label': 'BOOST', 'c': Colors.amberAccent},
      {'v': 12.0, 'label': 'TURBO', 'c': Colors.purpleAccent},
      {'v': 15.0, 'label': 'OVERDRIVE', 'c': Colors.redAccent},
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _nexusSectionTitle(isDark, 'VOLTAGE LOADOUT', 'Pilih mode output perangkat'),
      const SizedBox(height: 10),
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.45,
        children: modes.map((m) {
          final double v = m['v']; final Color c = m['c']; final selected = setVolt == v;
          return GestureDetector(
            onTap: () => sendVoltage(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: selected ? c.withOpacity(.13) : AppColors.card(isDark),
                borderRadius: BorderRadius.circular(19),
                border: Border.all(color: selected ? c : c.withOpacity(.16), width: selected ? 1.7 : 1),
                boxShadow: selected ? [BoxShadow(color: c.withOpacity(.12), blurRadius: 24)] : [],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Row(children: [Icon(Icons.bolt_rounded, color: c, size: 17), const Spacer(), if (selected) Icon(Icons.check_circle_rounded, color: c, size: 17)]),
                const Spacer(),
                Text('${v.toStringAsFixed(0)}V', style: TextStyle(color: c, fontSize: 27, fontWeight: FontWeight.w900)),
                Text(m['label'], style: TextStyle(color: AppColors.text(isDark), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.3)),
              ]),
            ),
          );
        }).toList(),
      ),
    ]);
  }

  Widget _nexusMetrics(bool isDark) => _nexusCard(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _nexusSectionTitle(isDark, 'SYSTEM STATUS', 'Data dari ESP32 aktual'),
    const SizedBox(height: 14),
    Row(children: [
      Expanded(child: _metricBox(isDark, Icons.bolt, 'SET VOLTAGE', '${setVolt.toStringAsFixed(0)}V')),
      const SizedBox(width: 9),
      Expanded(child: _metricBox(isDark, Icons.timer_outlined, 'UPTIME', uptime)),
      const SizedBox(width: 9),
      Expanded(child: _metricBox(isDark, Icons.wifi_tethering, 'MODE', connectionMode)),
    ]),
  ]));

  Widget _metricBox(bool isDark, IconData icon, String label, String value) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(color: accentColor.withOpacity(.035), borderRadius: BorderRadius.circular(14), border: Border.all(color: accentColor.withOpacity(.09))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: accentColor, size: 18), const SizedBox(height: 8),
      Text(value, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.text(isDark), fontSize: 11, fontWeight: FontWeight.w900)),
      const SizedBox(height: 2), Text(label, style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 7, letterSpacing: .8)),
    ]),
  );

  Widget _nexusRgbCard(bool isDark) => _nexusCard(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _nexusSectionTitle(isDark, 'RGB ENGINE', 'Efek LED dari firmware ESP32'),
    const SizedBox(height: 12),
    Row(children: [
      _rgbButton(isDark, 'OFF', 'off', Icons.power_settings_new_rounded),
      _rgbButton(isDark, 'STATIC', 'static', Icons.circle),
      _rgbButton(isDark, 'RUN', 'running', Icons.motion_photos_on_rounded),
      _rgbButton(isDark, 'DISCO', 'disco', Icons.celebration_rounded),
      _rgbButton(isDark, 'BOUNCE', 'bounce', Icons.swap_horiz_rounded),
    ]),
  ]));

  Widget _rgbButton(bool isDark, String label, String mode, IconData icon) {
    final selected = ledMode == mode;
    return Expanded(child: GestureDetector(
      onTap: () => sendLed(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.symmetric(horizontal: 2), padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        decoration: BoxDecoration(color: selected ? accentColor.withOpacity(.16) : AppColors.card(isDark), borderRadius: BorderRadius.circular(12), border: Border.all(color: selected ? accentColor : Colors.transparent)),
        child: Column(children: [Icon(icon, color: selected ? accentColor : AppColors.textFaint(isDark), size: 16), const SizedBox(height: 4), Text(label, style: TextStyle(color: selected ? accentColor : AppColors.textFaint(isDark), fontSize: 7, fontWeight: FontWeight.w900))]),
      ),
    ));
  }

  Widget _nexusQuickMenu(bool isDark) => Row(children: [
    _quickTile(isDark, Icons.analytics_rounded, 'DATA', () {
      if (activeCooler == null) return _showSnack('Pilih device dulu');
      Navigator.push(context, MaterialPageRoute(builder: (_) => HistoryPage(coolerId: activeCooler!.id, coolerName: activeCooler!.nickname, accentColor: accentColor)));
    }),
    _quickTile(isDark, Icons.schedule_rounded, 'SCHEDULE', () {
      if (activeCooler == null) return _showSnack('Pilih device dulu');
      Navigator.push(context, MaterialPageRoute(builder: (_) => SchedulePage(coolerId: activeCooler!.id, accentColor: accentColor, availableVoltages: const [5,9,12,15])));
    }),
    _quickTile(isDark, Icons.palette_outlined, 'THEME', () => _showThemeSheet()),
  ]);

  Widget _quickTile(bool isDark, IconData icon, String label, VoidCallback onTap) => Expanded(child: GestureDetector(
    onTap: onTap,
    child: _nexusCard(isDark, child: Column(children: [Icon(icon, color: accentColor, size: 22), const SizedBox(height: 7), Text(label, style: TextStyle(color: AppColors.text(isDark), fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: 1))])),
  ));

  Widget _nexusConnectionActions(bool isDark) => Row(children: [
    Expanded(child: OutlinedButton.icon(onPressed: () { if (activeCooler == null) showAddCoolerDialog(); else _connectActiveCooler(); }, icon: Icon(Icons.sync_rounded, color: accentColor), label: Text('REFRESH', style: TextStyle(color: accentColor, fontSize: 10, fontWeight: FontWeight.w900)), style: OutlinedButton.styleFrom(side: BorderSide(color: accentColor.withOpacity(.4)), padding: const EdgeInsets.symmetric(vertical: 14)))),
    const SizedBox(width: 10),
    Expanded(child: OutlinedButton.icon(onPressed: showWiFiSetupDialog, icon: Icon(Icons.wifi_tethering_rounded, color: accentColor), label: Text('SETUP WIFI', style: TextStyle(color: accentColor, fontSize: 10, fontWeight: FontWeight.w900)), style: OutlinedButton.styleFrom(side: BorderSide(color: accentColor.withOpacity(.4)), padding: const EdgeInsets.symmetric(vertical: 14)))),
  ]);

  Widget _nexusSectionTitle(bool isDark, String title, String subtitle) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(color: AppColors.text(isDark), fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4)),
      const SizedBox(height: 3), Text(subtitle, style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8)),
    ])),
    Container(width: 7, height: 7, decoration: BoxDecoration(color: accentColor, shape: BoxShape.circle, boxShadow: [BoxShadow(color: accentColor.withOpacity(.5), blurRadius: 9)])),
  ]);

  Widget _nexusCard(bool isDark, {required Widget child, Color? accent}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface(isDark).withOpacity(.88),
      borderRadius: BorderRadius.circular(21),
      border: Border.all(color: (accent ?? accentColor).withOpacity(.14)),
      boxShadow: [BoxShadow(color: (accent ?? accentColor).withOpacity(.045), blurRadius: 24, spreadRadius: 1)],
    ),
    child: child,
  );

  void _showThemeSheet() {
    final isDark = ThemeController.isDark;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface(isDark),
      showDragHandle: true,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('THEME LAB', style: TextStyle(color: AppColors.text(isDark), fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text('Pilih tampilan dan accent color', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('Dark Mode', style: TextStyle(color: AppColors.text(isDark))), value: isDark, activeColor: accentColor, onChanged: (v) async { await ThemeController.setDark(v); if (mounted) setState(() {}); setSheet(() {}); }),
          const SizedBox(height: 8),
          Text('ACCENT COLOR', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9, letterSpacing: 1.5)),
          const SizedBox(height: 10),
          Wrap(spacing: 11, runSpacing: 11, children: colorPalette.map((c) => GestureDetector(
            onTap: () { setState(() => accentColor = c); setSheet(() {}); },
            child: CircleAvatar(radius: 18, backgroundColor: c, child: accentColor.value == c.value ? const Icon(Icons.check, color: Colors.black, size: 17) : null),
          )).toList()),
        ]),
      )),
    );
  }
}

class _NexusGridPainter extends CustomPainter {
  final Color color;
  _NexusGridPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color.withOpacity(.035)..strokeWidth = 1;
    const gap = 34.0;
    for (double x = 0; x < size.width; x += gap) canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y < size.height; y += gap) canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    final glow = Paint()..color = color.withOpacity(.06);
    for (int i = 0; i < 8; i++) {
      final x = (size.width / 8) * i + 10;
      final y = (size.height / 7) * ((i * 3) % 7);
      canvas.drawCircle(Offset(x, y), 1.7, glow);
    }
  }
  @override
  bool shouldRepaint(covariant _NexusGridPainter oldDelegate) => oldDelegate.color != color;
}

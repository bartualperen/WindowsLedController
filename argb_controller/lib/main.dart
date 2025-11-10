import 'dart:async';
import 'dart:io'; // RAM ölçmek için
import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  windowManager.setPreventClose(true);

  const windowOptions = WindowOptions(
    size: Size(950, 720),
    center: true,
    title: 'Windows LED Controller',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ArgbApp());
}

class ArgbApp extends StatelessWidget {
  const ArgbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Windows LED Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.cyanAccent),
      ),
      home: const ArgbHomePage(),
    );
  }
}

enum EffectMode {
  staticColor,
  breathing,
  rainbow,
  circularTwoColor, // eski flash yerine
  twoColor,
  warmFlicker,
}

class ArgbHomePage extends StatefulWidget {
  const ArgbHomePage({super.key});

  @override
  State<ArgbHomePage> createState() => _ArgbHomePageState();
}

class _ArgbHomePageState extends State<ArgbHomePage>
    with TrayListener, WindowListener {
  SerialPort? _port;
  String? _selectedPort;

  // circular modda aynı şeyi tekrar tekrar göndermemek için
  Color? _lastDualC1;
  Color? _lastDualC2;
  int? _lastDualSpeedMs;

  Color _currentColor = Colors.blue;
  Color _secondaryColor = Colors.purple;
  double _brightness = 70;
  final double _maxPercent = 70;
  EffectMode _mode = EffectMode.staticColor;
  double _effectSpeed = 1.0;

  Timer? _effectTimer;
  double _t = 0;
  final _rnd = Random();

  // ayar kaydetme
  Timer? _saveDebounce;

  // hafif perf izleme
  Timer? _perfTimer;
  int _ramMb = 0;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initTray();

    _loadSettings().then((_) {
      _autoSelectPort();
      _startEffectLoop();
    });

    // RAM'i hafifçe izle
    _perfTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final rss = ProcessInfo.currentRss; // bytes
      setState(() {
        _ramMb = (rss / (1024 * 1024)).round();
      });
    });
  }

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray_icon.ico');

    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Göster'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Programdan Çık'),
        ],
      ),
    );
  }

  // tray icon sol tık
  @override
  void onTrayIconMouseDown() async {
    final isVisible = await windowManager.isVisible();
    if (isVisible) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }

  // tray icon sağ tık
  @override
  void onTrayIconRightMouseUp() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'exit':
        await trayManager.destroy();
        windowManager.setPreventClose(false);
        await windowManager.close();
        break;
    }
  }

  // ayarları yükle
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('led_settings');
    if (json == null) return;

    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      setState(() {
        _brightness = (data['brightness'] ?? 70).toDouble();
        _effectSpeed = (data['effectSpeed'] ?? 1.0).toDouble();
        _selectedPort = data['port'] as String?;
        _mode = EffectMode.values[data['mode'] ?? 0];
        _currentColor = _colorFromHex(data['currentColor'] as String?);
        _secondaryColor = _colorFromHex(data['secondaryColor'] as String?);
      });
    } catch (_) {
      // bozuksa boşver
    }
  }

  void _sendDualColor(Color c1, Color c2) {
    final port = _port;
    if (port == null || !port.isOpen) return;

    final clamped = _brightness.clamp(0, _maxPercent);
    final scale = clamped / 100.0;

    final r1 = (c1.red * scale).round();
    final g1 = (c1.green * scale).round();
    final b1 = (c1.blue * scale).round();

    final r2 = (c2.red * scale).round();
    final g2 = (c2.green * scale).round();
    final b2 = (c2.blue * scale).round();

    final speedMs = _mapSpeedToMs(_effectSpeed);

    // değişmediyse hiç yollama
    if (_lastDualC1 == c1 &&
        _lastDualC2 == c2 &&
        _lastDualSpeedMs == speedMs) {
      return;
    }

    final cmd = 'D $r1 $g1 $b1 $r2 $g2 $b2 $speedMs\n';
    final data = Uint8List.fromList(cmd.codeUnits);
    try {
      port.write(data);
      _lastDualC1 = c1;
      _lastDualC2 = c2;
      _lastDualSpeedMs = speedMs;
    } catch (e) {
      debugPrint('Yazma hatası: $e');
    }
  }

  void _scheduleSaveSettings() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), _saveSettings);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'brightness': _brightness,
      'effectSpeed': _effectSpeed,
      'port': _selectedPort,
      'mode': _mode.index,
      'currentColor': _colorToHex(_currentColor),
      'secondaryColor': _colorToHex(_secondaryColor),
    };
    await prefs.setString('led_settings', jsonEncode(data));
  }

  String _colorToHex(Color c) =>
      '#${c.alpha.toRadixString(16).padLeft(2, '0')}${c.red.toRadixString(16).padLeft(2, '0')}${c.green.toRadixString(16).padLeft(2, '0')}${c.blue.toRadixString(16).padLeft(2, '0')}';

  Color _colorFromHex(String? s) {
    if (s == null) return Colors.blue;
    final buffer = StringBuffer();
    if (s.length == 7) {
      buffer.write('ff'); // alpha
      buffer.write(s.replaceFirst('#', ''));
    } else {
      buffer.write(s.replaceFirst('#', ''));
    }
    return Color(int.parse(buffer.toString(), radix: 16));
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _saveDebounce?.cancel();
    _effectTimer?.cancel();
    _perfTimer?.cancel();
    _port?.close();
    super.dispose();
  }

  int _mapSpeedToMs(double s) {
    // s: 0.1 .. 3.0
    // ms: 200 .. 30 (ters orantı)
    const minMs = 30;
    const maxMs = 200;
    final clamped = s.clamp(0.1, 3.0);
    // 0.1 -> 1.0, 3.0 -> 0.0 gibi bir ters normalize
    final t = (clamped - 0.1) / (3.0 - 0.1); // 0..1
    final inverted = 1.0 - t; // 1..0
    final ms = maxMs * inverted + minMs * (1 - inverted);
    return ms.round();
  }

  // pencere kapatılınca gizle
  @override
  Future<void> onWindowClose() async {
    await windowManager.hide();
  }

  Future<void> _exitApp() async {
    await trayManager.destroy();
    windowManager.setPreventClose(false);
    await windowManager.close();
  }

  void _startEffectLoop() {
    _effectTimer =
        Timer.periodic(const Duration(milliseconds: 33), (_) => _tickEffect());
  }

  void _tickEffect() {
    Color toSend;
    final speed = _effectSpeed.clamp(0.1, 3.0);

    switch (_mode) {
      case EffectMode.staticColor:
        toSend = _currentColor;
        break;

      case EffectMode.breathing:
        _t += 0.03 * speed;
        final s = (sin(_t) + 1) / 2;
        final factor = 0.25 + s * 0.75;
        toSend = _scaleColor(_currentColor, factor);
        break;

      case EffectMode.rainbow:
        _t += 0.01 * speed;
        final hue = (_t % 1.0);
        toSend = HSVColor.fromAHSV(1, hue * 360, 1, 1).toColor();
        break;

      case EffectMode.circularTwoColor:
        // Arduino kendi döndürüyor, burada seri spam yok
        return;

      case EffectMode.twoColor:
        _t += 0.015 * speed;
        final s2 = (sin(_t) + 1) / 2;
        toSend = Color.lerp(_currentColor, _secondaryColor, s2) ?? _currentColor;
        break;

      case EffectMode.warmFlicker:
        _t += 0.02 * speed;
        final base = const Color(0xFFFF3402);
        final jitter = 0.85 + _rnd.nextDouble() * 0.15;
        toSend = _scaleColor(base, jitter);
        break;
    }

    _sendColor(toSend);
  }

  Color _scaleColor(Color c, double f) {
    return Color.fromARGB(
      c.alpha,
      (c.red * f).clamp(0, 255).round(),
      (c.green * f).clamp(0, 255).round(),
      (c.blue * f).clamp(0, 255).round(),
    );
  }

  void _autoSelectPort() {
    final ports = SerialPort.availablePorts;
    String? found;
    for (final p in ports) {
      if (p.toUpperCase().contains('COM15')) {
        found = p;
        break;
      }
    }
    found ??= ports.isNotEmpty ? ports.first : null;
    if (found != null) {
      _openPort(found);
    }
  }

  bool _openPort(String portName) {
    try {
      _port?.close();
    } catch (_) {}
    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      debugPrint('Port açılamadı: $portName');
      return false;
    }

    final cfg = SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..stopBits = 1
      ..parity = SerialPortParity.none;
    port.config = cfg;

    setState(() {
      _port = port;
      _selectedPort = portName;
    });

    _scheduleSaveSettings();
    return true;
  }

  void _sendColor(Color color) {
    final port = _port;
    if (port == null || !port.isOpen) return;

    final clamped = _brightness.clamp(0, _maxPercent);
    final scale = clamped / 100.0;
    final r = (color.red * scale).round();
    final g = (color.green * scale).round();
    final b = (color.blue * scale).round();

    final cmd = 'S $r $g $b\n';
    final data = Uint8List.fromList(cmd.codeUnits);

    try {
      port.write(data);
    } catch (e) {
      debugPrint('Yazma hatası: $e');
    }
  }

  void _openColorPicker({bool secondary = false}) {
    Color tempColor = secondary ? _secondaryColor : _currentColor;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: Text(secondary ? 'İkincil renk seç' : 'Renk seç'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: tempColor,
              onColorChanged: (c) => tempColor = c,
              enableAlpha: false,
              labelTypes: const [],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Vazgeç'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  if (secondary) {
                    _secondaryColor = tempColor;
                  } else {
                    _currentColor = tempColor;
                  }
                });
                // circular moddaysak değişikliği gönder
                if (_mode == EffectMode.circularTwoColor) {
                  _sendDualColor(_currentColor, _secondaryColor);
                } else if (!secondary && _mode == EffectMode.staticColor) {
                  // statik modda ana renk değiştiyse hemen gönder
                  _sendColor(tempColor);
                }
                _scheduleSaveSettings();
                Navigator.of(ctx).pop();
              },
              child: const Text('Uygula'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ports = SerialPort.availablePorts;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ALPORA LED Controller',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        backgroundColor: Colors.black.withOpacity(0.4),
        elevation: 0,
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white24,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => _openColorPicker(),
            icon: const Icon(Icons.palette),
            label: const Text('Renk'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white24,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => _openColorPicker(secondary: true),
            icon: const Icon(Icons.color_lens),
            label: const Text('İkincil'),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.exit_to_app, color: Colors.white),
            tooltip: 'Çıkış',
            onPressed: _exitApp,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('Port:', style: TextStyle(fontSize: 16)),
                    const SizedBox(width: 12),
                    DropdownButton<String>(
                      value: _selectedPort,
                      hint: const Text('Port seç'),
                      dropdownColor: const Color(0xFF1E293B),
                      items: ports.map((p) {
                        return DropdownMenuItem(value: p, child: Text(p));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          final ok = _openPort(val);
                          if (ok && _mode == EffectMode.staticColor) {
                            _sendColor(_currentColor);
                          }
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _modeButton('Statik', EffectMode.staticColor),
                    _modeButton('Nefes', EffectMode.breathing),
                    _modeButton('Rainbow', EffectMode.rainbow),
                    _modeButton('Dairesel 2', EffectMode.circularTwoColor),
                    _modeButton('2 Renk', EffectMode.twoColor),
                    _modeButton('Warm', EffectMode.warmFlicker),
                  ],
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Parlaklık: ${_brightness.toStringAsFixed(0)}% (maks: ${_maxPercent.toStringAsFixed(0)}%)',
                      style: const TextStyle(fontSize: 14),
                    ),
                    Slider(
                      value: _brightness,
                      min: 0,
                      max: 70,
                      divisions: 100,
                      label: _brightness.toStringAsFixed(0),
                      onChanged: (val) {
                        setState(() {
                          _brightness = val;
                        });
                        if (_mode == EffectMode.staticColor) {
                          _sendColor(_currentColor);
                        } else if (_mode == EffectMode.circularTwoColor) {
                          _sendDualColor(_currentColor, _secondaryColor);
                        }
                        _scheduleSaveSettings();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Efekt hızı: ${_effectSpeed.toStringAsFixed(2)}x',
                      style: const TextStyle(fontSize: 14),
                    ),
                    Slider(
                      value: _effectSpeed,
                      min: 0.1,
                      max: 3.0,
                      divisions: 29,
                      label: _effectSpeed.toStringAsFixed(2),
                      onChanged: (val) {
                        setState(() {
                          _effectSpeed = val;
                        });
                        if (_mode == EffectMode.circularTwoColor) {
                          _sendDualColor(_currentColor, _secondaryColor);
                        }
                        _scheduleSaveSettings();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  height: 110,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _currentColor.withOpacity(0.1),
                        _currentColor,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Text(
                      _mode.name.toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // sol alt RAM göstergesi
          Positioned(
            left: 16,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.cyanAccent.withOpacity(0.6)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.memory, size: 16, color: Colors.white70),
                  const SizedBox(width: 6),
                  Text(
                    'RAM: $_ramMb MB',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeButton(String label, EffectMode mode) {
    final selected = _mode == mode;
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: selected ? Colors.cyan : const Color(0xFF1E293B),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: () {
        setState(() {
          _mode = mode;
        });
        if (mode == EffectMode.circularTwoColor) {
          _sendDualColor(_currentColor, _secondaryColor);
        }
        _scheduleSaveSettings();
      },
      child: Text(label),
    );
  }
}

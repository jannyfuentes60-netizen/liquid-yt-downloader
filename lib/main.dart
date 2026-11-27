import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'yt_service.dart';

// ---------------------------------------------------------------------------
// Registro de errores que SÍ sobrevive a un cierre nativo.
// ---------------------------------------------------------------------------
// Por qué el crash.log de la v1.0.6 no existía:
//  1. Un crash NATIVO (Python/yt-dlp) mata el proceso entero: ningún
//     handler de Dart (runZonedGuarded, FlutterError, onError) se ejecuta.
//  2. _writeCrashLog era async y se llamaba con unawaited: si el proceso
//     muere, el write nunca se descarga (flush) a disco.
//  3. En Android 13+ la app NO puede escribir directo en
//     /storage/emulated/0/Download/ sin permiso especial: el write fallaba
//     en silencio y el fallback caía en la carpeta privada de la app, que
//     el usuario no puede ver en el explorador.
// Por eso ahora todo se escribe SÍNCRONO (writeAsStringSync + flush) y en
// varios lugares: la carpeta de salida conocida, Descargas y la carpeta
// externa de la app (Android/data/.../files), que sí se puede abrir.

/// Carpeta donde sí se pudo escribir la última vez (la fija _outputDir).
String? _logDirPath;

/// Escribe [text] en el archivo [name], de forma síncrona y con flush,
/// probando varias carpetas. Devuelve la ruta donde quedó, o null.
/// Nunca tira excepciones.
String? _syncWriteLog(String name, String text, {bool append = true}) {
  final candidates = <String?>[
    _logDirPath,
    '/storage/emulated/0/Download/LiquidYT',
    '/storage/emulated/0/Android/data/com.linejaque.liquidyt/files',
  ];
  for (final base in candidates) {
    if (base == null || base.isEmpty) continue;
    try {
      final dir = Directory(base);
      dir.createSync(recursive: true);
      final file = File('${dir.path}/$name');
      file.writeAsStringSync(
        text,
        mode: append ? FileMode.append : FileMode.write,
        flush: true,
      );
      return file.path;
    } catch (_) {}
  }
  return null;
}

/// Error de Dart: se guarda (síncrono) en crash.log.
Future<void> _writeCrashLog(String text) async {
  final line = '[${DateTime.now().toIso8601String()}] $text\n';
  _syncWriteLog('crash.log', line, append: true);
}

/// Última acción antes de una llamada nativa (init / resolve / download).
/// Se SOBRESCRIBE cada vez, así si la app muere en esa llamada, el archivo
/// dice exactamente qué estaba haciendo. Se escribe ANTES de la llamada.
void _writeLastAction(String action) {
  final line = '[${DateTime.now().toIso8601String()}] $action\n';
  _syncWriteLog('last_action.log', line, append: false);
}

String? _findLogFile(String name) {
  final candidates = <String?>[
    _logDirPath,
    '/storage/emulated/0/Download/LiquidYT',
    '/storage/emulated/0/Android/data/com.linejaque.liquidyt/files',
  ];
  for (final base in candidates) {
    if (base == null || base.isEmpty) continue;
    try {
      final f = File('$base/$name');
      if (f.existsSync()) return f.path;
    } catch (_) {}
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tipografía v1.0.7: tamaños explícitos y modestos. Nada queda al tamaño
// por defecto del sistema: el usuario reportó letras gigantes, y en este
// teléfono la escala de fuente del sistema las inflaba.
// ---------------------------------------------------------------------------
const _sScreenTitle = TextStyle(
  fontSize: 26,
  fontWeight: FontWeight.w800,
  height: 1.15,
  color: Colors.white,
);
const _sTitle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w800,
  height: 1.3,
  color: Colors.white,
);
const _sSection = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w700,
  height: 1.35,
  color: Colors.white,
);
const _sBody = TextStyle(
  fontSize: 13.5,
  fontWeight: FontWeight.w500,
  height: 1.45,
  color: Colors.white,
);
const _sCaption = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w500,
  height: 1.4,
  color: Colors.white70,
);
const _sChip = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.2);
const _sButton =
    TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.2);

/// Ajuste de glass para que las tarjetas NO se vean lavadas/transparentes:
/// fondo de respaldo oscuro y opaco, más blur y saturación, luz de borde.
/// Se usa con useOwnLayer: true para que cada tarjeta aplique su propio
/// ajuste (en modo agrupado los ajustes por widget se ignoran).
const _cardGlassSettings = LiquidGlassSettings(
  blur: 14,
  frost: 10,
  saturation: 1.6,
  glassColor: Color(0x33FFFFFF),
  backerColor: Color(0xB3141B3D),
  rimLight: 0.5,
  rimShade: 0.35,
  glowIntensity: 0.5,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Si un widget falla al dibujar, mostrar un mensaje legible en vez de
  // una pantalla negra / cierre silencioso.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFF0B1026),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Algo falló al dibujar la pantalla.\n${details.exception}',
              textAlign: TextAlign.center,
              style: _sBody,
            ),
          ),
        ),
      );

  FlutterError.onError = (details) {
    unawaited(_writeCrashLog(
        'flutter-error: ${details.exception}\n${details.stack}'));
    FlutterError.presentError(details);
  };
  // Errores async sin atrapar: guardarlos y NO matar el isolate.
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    unawaited(_writeCrashLog('uncaught-async: $error\n$stack'));
    return true;
  };

  // El precache de shaders del glass no debe matar la app si falla.
  bool glassOk = false;
  try {
    await LiquidGlassWidgets.initialize(
      warmUpMode: GlassWarmUpMode.never,
    ).timeout(const Duration(seconds: 10));
    glassOk = true;
  } catch (e, st) {
    await _writeCrashLog('glass-init falló: $e\n$st');
    glassOk = false;
  }

  runZonedGuarded(
    () {
      runApp(
        glassOk
            ? LiquidGlassWidgets.wrap(
                brightnessResolver: Theme.maybeBrightnessOf,
                theme: const GlassThemeData.ios27(),
                // En Android gama baja: arrancar en calidad estándar y
                // dejar que el paquete suba/baje según el GPU real.
                adaptiveQuality: true,
                child: const LiquidYtApp(),
              )
            : const LiquidYtApp(),
      );
    },
    (error, stack) {
      unawaited(_writeCrashLog('uncaught-zone: $error\n$stack'));
    },
  );
}

class LiquidYtApp extends StatelessWidget {
  const LiquidYtApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liquid YT',
      debugShowCheckedModeBanner: false,
      // La escala de fuente del sistema no puede inflar la UI: se limita
      // entre 0.9x y 1.1x. Esto es lo que hacía gigantes las letras.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.9,
        maxScaleFactor: 1.1,
        child: child!,
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F7CFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _shareChannel = MethodChannel('liquid_yt/share');

  final YtService _yt = YtService();
  final TextEditingController _queryController = TextEditingController();

  int _tabIndex = 0;
  bool _engineReady = false;
  // El motor ya NO se inicia en el arranque ni al tocar una rola: solo
  // al presionar Descargar en un formato que lo necesita (MP3 / MP4
  // 720p / 480p). Tocar una canción solo pinta la tarjeta con metadatos
  // HTTP; el log del usuario lo confirmó: la v1.0.8 moría en
  // "iniciando motor yt-dlp" justo al tocar la tarjeta, porque
  // _fetchRealFormats llamaba a _ensureEngine en ese camino.
  bool _engineBusy = false;
  Future<bool>? _engineInitFuture;
  String? _engineError;
  String _engineVersions = '';
  String? _crashLogPath;
  String? _lastActionPath;

  bool _searching = false;
  bool _resolving = false;
  String? _resolveToken;
  String? _fetchingDirectFormatsUrl;
  List<SearchItem> _results = [];
  ResolvedVideo? _resolved;
  FormatOption _selectedFormat = YtService.presets().first;
  FormatOption? _selectedDirectFormat;
  // Formatos de descarga directa (manifiesto HTTP, sin motor) del video
  // que está en la tarjeta. Llegan en segundo plano; si YouTube no los
  // da, la lista queda vacía y se usan los formatos fijos con motor.
  List<FormatOption> _directFormats = [];

  String? _activeProcessId;
  String _activeTitle = '';
  double _progress = 0;
  int _etaSeconds = 0;
  String _activeStatus = '';

  List<DownloadRecord> _history = [];
  String _outputDirLabel = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText' && call.arguments is String) {
        _handleSharedText(call.arguments as String);
      }
      return null;
    });
    // Arranque DESPUÉS del primer frame: la UI ya pintó antes de pedir
    // permisos, leer el historial o tocar el motor. Nada de esto puede
    // impedir que la app se abra.
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _queryController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSharedText();
    }
  }

  Future<void> _boot() async {
    // Cada paso va en su propio try/catch: si uno falla, se registra y se
    // sigue con los demás. Un error aquí ya no puede cerrar la app.
    try {
      try {
        await Permission.storage.request().timeout(
              const Duration(seconds: 5),
              onTimeout: () => PermissionStatus.denied,
            );
      } catch (e, st) {
        unawaited(_writeCrashLog('permiso storage falló: $e\n$st'));
      }
      try {
        await _loadHistory();
      } catch (e, st) {
        unawaited(_writeCrashLog('historial falló: $e\n$st'));
      }
      try {
        await _refreshOutputDirLabel();
      } catch (e, st) {
        unawaited(_writeCrashLog('carpeta salida falló: $e\n$st'));
      }
      await _checkCrashLog();
    } catch (e, st) {
      unawaited(_writeCrashLog('boot falló: $e\n$st'));
      if (mounted) {
        setState(() {
          _engineBusy = false;
          _engineError = 'Falló el arranque: $e';
        });
      }
    }
    _listenToDownloads();
    await _checkSharedText();
  }

  /// Prepara el motor yt-dlp SOLO cuando el usuario presiona Descargar
  /// en un formato que lo necesita. Nunca se llama al tocar una rola,
  /// buscar o resolver. Una sola inicialización en vuelo: los demás
  /// esperan el mismo Future. Con el fork local el init corre en
  /// segundo plano (ya no en el hilo principal), así que la UI no se
  /// congela; si falla, reintenta una vez y si vuelve a fallar avisa
  /// sin cerrar la app.
  Future<bool> _ensureEngine() async {
    if (_engineReady) return true;
    final inFlight = _engineInitFuture;
    if (inFlight != null) return inFlight;
    final fut = _initEngineWithRetry();
    _engineInitFuture = fut;
    final ok = await fut;
    if (!ok) _engineInitFuture = null; // permitir reintentar
    return ok;
  }

  Future<bool> _initEngineWithRetry() async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      final ok = await _initEngine(attempt: attempt);
      if (ok) return true;
      if (attempt == 1) {
        _writeLastAction('init motor intento 1 falló, reintentando en 2 s');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }

  Future<bool> _initEngine({int attempt = 1}) async {
    if (!mounted) return false;
    setState(() {
      _engineBusy = true;
      _engineError = null;
    });
    bool ok = false;
    try {
      // last_action ANTES de la llamada nativa: si el proceso muere aquí,
      // el archivo dice en qué paso estaba. Con el fork el init corre en
      // segundo plano, así que esto ya no debería matar la app.
      _writeLastAction(
          'iniciando motor yt-dlp (intento $attempt, paso 1: Python)');
      ok = await _yt
          .init()
          .timeout(const Duration(seconds: 90), onTimeout: () => false);
      _writeLastAction(ok
          ? 'motor listo (yt-dlp + FFmpeg, intento $attempt)'
          : 'motor falló / timeout (intento $attempt)');
    } catch (e, st) {
      _writeLastAction('init motor falló (intento $attempt): $e');
      unawaited(_writeCrashLog('init motor falló: $e\n$st'));
      ok = false;
    }
    if (!mounted) return ok;
    setState(() {
      _engineReady = ok;
      _engineBusy = false;
      _engineError =
          ok ? null : (_yt.engineError ?? 'No se pudo iniciar yt-dlp');
    });
    if (ok) {
      try {
        _engineVersions = await _yt.engineVersions();
        if (mounted) setState(() {});
      } catch (_) {}
      // OJO v1.0.7: ya NO se actualiza yt-dlp automáticamente al iniciar.
      // En v1.0.6 updateEngine() corría sin await justo antes de resolver,
      // y reemplazaba los archivos de yt-dlp mientras getVideoInfo los
      // estaba usando: esa carrera es una causa probable del cierre al
      // elegir una canción. El yt-dlp incluido en el APK basta.
    }
    return ok;
  }

  /// Si existe un crash.log o last_action.log anterior, recordar su ruta
  /// para mostrarla en la pestaña Descargas.
  Future<void> _checkCrashLog() async {
    try {
      final crash = _findLogFile('crash.log');
      final last = _findLogFile('last_action.log');
      // También buscar en la carpeta privada de documentos (fallback viejo).
      String? docsCrash;
      try {
        final docs = await getApplicationDocumentsDirectory();
        final p = File('${docs.path}/crash.log');
        if (await p.exists()) docsCrash = p.path;
      } catch (_) {}
      if (mounted) {
        setState(() {
          _crashLogPath = crash ?? docsCrash;
          _lastActionPath = last;
        });
      }
    } catch (_) {}
  }

  void _listenToDownloads() {
    _yt.progressStream.listen((p) {
      if (p.processId == _activeProcessId && mounted) {
        setState(() {
          _progress = p.progress.clamp(0, 100);
          _etaSeconds = p.etaInSeconds;
        });
      }
    });
    _yt.stateStream.listen((s) {
      if (s.processId == _activeProcessId && mounted) {
        setState(() => _activeStatus = s.state.toString());
      }
    });
    _yt.errorStream.listen((e) {
      if (e.processId == _activeProcessId && mounted) {
        setState(() {
          _activeProcessId = null;
          _activeStatus = '';
        });
        _snack('Error: ${e.error}');
      }
    });
  }

  Future<void> _checkSharedText() async {
    try {
      final text = await _shareChannel.invokeMethod<String>('getSharedText');
      if (text != null && text.isNotEmpty) _handleSharedText(text);
    } catch (_) {
      // El canal nativo aún no tiene nada compartido; no es un error.
    }
  }

  void _handleSharedText(String text) {
    final url = YtService.extractYoutubeUrl(text);
    if (url == null) {
      _snack('Ese enlace no es de YouTube');
      return;
    }
    _resolveAndOpenSheet(url);
  }

  Future<Directory> _outputDir() async {
    // 1) Carpeta pública Descargas/LiquidYT (la que ves en el explorador).
    final public = Directory('/storage/emulated/0/Download/LiquidYT');
    try {
      if (await public.create(recursive: true).then((d) => d.exists())) {
        return public;
      }
    } catch (_) {
      // Android no dejó escribir ahí: se usa el almacenamiento de la app.
    }
    // 2) Carpeta externa de la app. getExternalStorageDirectory() PUEDE
    // devolver null (sin almacenamiento externo): antes había un `ext!`
    // que cerraba la app en ese caso. Ahora se comprueba y se cae a la
    // carpeta de documentos de la app, que siempre existe.
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dir = Directory('${ext.path}/LiquidYT');
        await dir.create(recursive: true);
        return dir;
      }
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/LiquidYT');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _refreshOutputDirLabel() async {
    final dir = await _outputDir();
    _logDirPath = dir.path;
    if (mounted) setState(() => _outputDirLabel = dir.path);
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final saved =
        DownloadRecord.decodeList(prefs.getString('liquidyt_history') ?? '[]');
    final dir = await _outputDir();
    _logDirPath = dir.path;
    final onDisk = <DownloadRecord>[];
    try {
      for (final f in dir.listSync()) {
        if (f is File &&
            (f.path.endsWith('.mp3') ||
                f.path.endsWith('.m4a') ||
                f.path.endsWith('.mp4'))) {
          final name = f.path.split('/').last;
          if (saved.any((r) => r.path == f.path)) continue;
          onDisk.add(DownloadRecord(
            title: name.replaceAll(RegExp(r'\.(mp3|m4a|mp4)$'), ''),
            url: '',
            path: f.path,
            formatLabel: name.split('.').last.toUpperCase(),
            dateMs: f.lastModifiedSync().millisecondsSinceEpoch,
            sizeBytes: f.lengthSync(),
          ));
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _history = [...saved, ...onDisk]
          ..sort((a, b) => b.dateMs.compareTo(a.dateMs));
      });
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'liquidyt_history', DownloadRecord.encodeList(_history));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: _sBody),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _search() async {
    if (_searching) return;
    final q = _queryController.text.trim();
    if (q.isEmpty) {
      _snack('Escribe algo para buscar o pega un link');
      return;
    }
    if (YtService.looksLikeYoutubeUrl(q)) {
      _resolveAndShow(q);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _results = [];
      _resolved = null;
    });
    try {
      final items = await _yt.search(q);
      if (!mounted) return;
      setState(() => _results = items);
      if (items.isEmpty) _snack('No salió nada para "$q"');
    } catch (e) {
      if (mounted) {
        _snack('La búsqueda falló. Pega el link directo del video.');
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Resolver un video sin depender del código nativo para pintar la
  /// tarjeta NI para los formatos. v1.0.9: tocar una canción SOLO pinta
  /// la tarjeta con metadatos ligeros (youtube_explode, solo HTTP, nada
  /// nativo). La v1.0.8 se cerraba al tocar la tarjeta porque
  /// _fetchRealFormats llamaba a _ensureEngine() en ese camino y el init
  /// del motor en el hilo principal mataba la app (log del usuario:
  /// "iniciando motor yt-dlp"). Ese camino ya no existe: los formatos
  /// "reales" ahora vienen del manifiesto HTTP (_fetchDirectFormats) y
  /// el motor solo se inicia al presionar Descargar.
  Future<void> _resolveAndShow(String url, {SearchItem? fromSearch}) async {
    if (_resolving) return; // doble toque: no resolver dos veces a la vez
    final token = DateTime.now().millisecondsSinceEpoch.toString();
    _resolveToken = token;

    if (fromSearch != null) {
      // Ya tenemos título/canal/miniatura/duración de la búsqueda.
      final meta = ResolvedVideo(
        url: fromSearch.url,
        title: fromSearch.title,
        channel: fromSearch.channel,
        thumbnailUrl: fromSearch.thumbnailUrl,
        durationSeconds: fromSearch.duration?.inSeconds,
        formats: const [],
      );
      if (mounted) {
        setState(() {
          _resolved = meta;
          _selectedDirectFormat = null;
          _selectedFormat = YtService.presets().first;
          _directFormats = [];
        });
      }
      // Solo HTTP, sin motor: si falla, la tarjeta se queda con los
      // formatos fijos y la descarga usa el motor al presionar Descargar.
      unawaited(_fetchDirectFormats(fromSearch.videoId, token));
      return;
    }

    setState(() {
      _resolving = true;
      _resolved = null;
      _selectedDirectFormat = null;
      _selectedFormat = YtService.presets().first;
      _directFormats = [];
    });
    try {
      _writeLastAction('resolviendo metadatos $url');
      final meta = await _yt
          .videoMeta(url)
          .timeout(const Duration(seconds: 20));
      if (!mounted || _resolveToken != token) return;
      setState(() => _resolved = meta);
      final videoId = YtService.videoIdFromUrl(url);
      if (videoId != null) {
        unawaited(_fetchDirectFormats(videoId, token));
      }
    } catch (e, st) {
      _writeLastAction('metadatos fallaron $url: $e');
      await _writeCrashLog('resolve-meta falló $url: $e\n$st');
      if (mounted) _snack('No se pudo leer ese video. Prueba con otro link.');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Formatos de descarga directa (manifiesto HTTP, sin motor nativo) en
  /// segundo plano. Es un bonus, nunca un motivo de cierre: si YouTube
  /// no entrega el manifiesto para esa rola, la lista queda vacía y la
  /// tarjeta se queda con los formatos fijos (MP3 / MP4 720p / 480p /
  /// 360p), que usan el motor al presionar Descargar.
  Future<void> _fetchDirectFormats(String videoId, String token) async {
    if (_fetchingDirectFormatsUrl == videoId) return;
    _fetchingDirectFormatsUrl = videoId;
    try {
      _writeLastAction('buscando formatos directos (HTTP) $videoId');
      final formats = await _yt
          .directFormats(videoId)
          .timeout(const Duration(seconds: 20));
      if (!mounted || _resolveToken != token) return;
      setState(() {
        _directFormats = formats;
      });
      _writeLastAction(
          'formatos directos listos $videoId (${formats.length})');
    } catch (e, st) {
      _writeLastAction('formatos directos fallaron $videoId: $e');
      await _writeCrashLog('formatos directos fallaron $videoId: $e\n$st');
      // La tarjeta se queda con los formatos fijos: descargar sigue ok.
    } finally {
      if (_fetchingDirectFormatsUrl == videoId) {
        _fetchingDirectFormatsUrl = null;
      }
    }
  }

  Future<void> _resolveAndOpenSheet(String url) async {
    await _resolveAndShow(url);
    if (!mounted || _resolved == null) return;
    _openDownloadSheet(_resolved!);
  }

  /// Descargar. Dos caminos:
  ///  - Formato DIRECTO (directUrl): descarga por HTTP, SIN motor nativo.
  ///    No puede cerrar la app y no necesita preparar nada.
  ///  - Formato con motor (MP3 / MP4 720p / 480p): AQUÍ es el único lugar
  ///    donde se inicia el motor, con la UI ya pintando "Preparando
  ///    motor…" (se deja pintar un frame antes de llamar al init) y con
  ///    reintento. Si el init falla, se avisa y la app sigue viva.
  Future<void> _startDownload(ResolvedVideo video, FormatOption option) async {
    if (_activeProcessId != null) {
      _snack('Ya hay una descarga en curso, espera a que termine');
      return;
    }
    if (option.isDirect) {
      await _downloadDirect(video, option);
      return;
    }
    // El botón queda en "Preparando motor…" y se deja pintar el frame
    // antes de llamar al init, para que el usuario vea qué pasa y no
    // toque la pantalla mientras se prepara el motor. Si el motor ya
    // estaba listo, no se muestra nada: se descarga directo.
    final needsPrep = !_engineReady;
    if (needsPrep) {
      setState(() {
        _engineBusy = true;
        _activeTitle = video.title;
        _activeStatus = 'Preparando motor…';
      });
      await Future.delayed(const Duration(milliseconds: 300));
    }
    final ready = await _ensureEngine();
    if (!mounted) return;
    if (!ready) {
      setState(() {
        _engineBusy = false;
        _activeStatus = '';
      });
      _snack('No se pudo preparar el motor yt-dlp. Prueba con un '
          'formato de descarga directa (M4A o MP4 360p) o reintenta.');
      return;
    }
    final dir = await _outputDir();
    final processId = 'dl_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _activeProcessId = processId;
      _activeTitle = video.title;
      _progress = 0;
      _etaSeconds = 0;
      _activeStatus = 'Descargando…';
    });
    try {
      // last_action ANTES de la llamada nativa de descarga.
      _writeLastAction(
          'descargando "${video.title}" formato ${option.id} ${video.url}');
      final result = await _yt.download(
        url: video.url,
        outputDir: dir.path,
        option: option,
        processId: processId,
      );
      if (!mounted) return;
      setState(() {
        _activeProcessId = null;
        _activeStatus = '';
      });
      if (result.status == OperationStatus.success) {
        final path = result.outputPath ?? '';
        int size = 0;
        try {
          size = await File(path).length();
        } catch (_) {}
        final record = DownloadRecord(
          title: video.title,
          url: video.url,
          path: path,
          formatLabel: option.label,
          dateMs: DateTime.now().millisecondsSinceEpoch,
          sizeBytes: size,
        );
        setState(() {
          _history = [record, ..._history];
        });
        await _saveHistory();
        _snack('Listo: ${video.title}');
      } else {
        final msg = result.errorMessage ?? 'Descarga fallida';
        _snack(_friendlyError(msg));
      }
    } catch (e, st) {
      _writeLastAction('descarga falló "${video.title}": $e');
      await _writeCrashLog('descarga falló ${video.url}: $e\n$st');
      if (!mounted) return;
      setState(() {
        _activeProcessId = null;
        _activeStatus = '';
      });
      _snack(_friendlyError(e.toString()));
    }
  }

  /// Descarga directa por HTTP (sin motor nativo). El nombre del archivo
  /// se limpia para que sea válido en Android.
  String _sanitizeFileName(String name) {
    var clean = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    clean = clean.replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) clean = 'LiquidYT';
    if (clean.length > 120) clean = clean.substring(0, 120).trim();
    return clean;
  }

  Future<void> _downloadDirect(ResolvedVideo video, FormatOption option) async {
    final dir = await _outputDir();
    final processId = 'dl_${DateTime.now().millisecondsSinceEpoch}';
    final fileName = '${_sanitizeFileName(video.title)}.${option.directExt}';
    final outputPath = '${dir.path}/$fileName';
    setState(() {
      _activeProcessId = processId;
      _activeTitle = video.title;
      _progress = 0;
      _etaSeconds = 0;
      _activeStatus = 'Descargando directo…';
    });
    try {
      _writeLastAction('descarga directa "${video.title}" ${option.id}');
      final path = await _yt.downloadHttp(
        url: option.directUrl!,
        outputPath: outputPath,
        onProgress: (received, total) {
          if (mounted && _activeProcessId == processId && total > 0) {
            setState(() => _progress = (received / total * 100).clamp(0, 100));
          }
        },
      );
      if (!mounted) return;
      int size = 0;
      try {
        size = await File(path).length();
      } catch (_) {}
      if (size <= 0) throw const HttpException('El archivo quedó vacío');
      final record = DownloadRecord(
        title: video.title,
        url: video.url,
        path: path,
        formatLabel: option.label,
        dateMs: DateTime.now().millisecondsSinceEpoch,
        sizeBytes: size,
      );
      setState(() {
        _activeProcessId = null;
        _activeStatus = '';
        _history = [record, ..._history];
      });
      await _saveHistory();
      _snack('Listo: ${video.title}');
    } catch (e, st) {
      _writeLastAction('descarga directa falló "${video.title}": $e');
      await _writeCrashLog('descarga directa falló ${video.url}: $e\n$st');
      if (!mounted) return;
      // Si el usuario la canceló, _activeProcessId ya es null y ya se
      // avisó "Descarga cancelada": no mostrar otro error encima.
      final wasActive = _activeProcessId == processId;
      setState(() {
        _activeProcessId = null;
        _activeStatus = '';
      });
      if (wasActive) {
        _snack('La descarga directa falló. Prueba con MP3 o MP4 720p '
            '(usan el motor).');
      }
    }
  }

  String _friendlyError(String raw) {
    final low = raw.toLowerCase();
    if (low.contains('sign in') || low.contains('not a bot')) {
      return 'YouTube pidió verificación para ese video. Prueba con otro video.';
    }
    if (low.contains('private') || low.contains('unavailable')) {
      return 'Ese video es privado o no está disponible.';
    }
    return 'No se pudo descargar: $raw';
  }

  Future<void> _cancelDownload() async {
    final id = _activeProcessId;
    if (id == null) return;
    // Cancela el motor y también una descarga directa HTTP en curso.
    _yt.cancelHttp();
    await _yt.cancel(id);
    setState(() {
      _activeProcessId = null;
      _activeStatus = '';
      _progress = 0;
    });
    _snack('Descarga cancelada');
  }

  Future<void> _deleteRecord(DownloadRecord record) async {
    try {
      await File(record.path).delete();
    } catch (_) {}
    setState(() => _history.remove(record));
    await _saveHistory();
  }

  String _sizeText(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ---------- UI: estilo iOS 27, aireado, letras modestas ----------

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      background: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.0, 0.45, 0.75, 1.0],
            colors: [
              Color(0xFF0E1330),
              Color(0xFF1C2E6E),
              Color(0xFF3A2060),
              Color(0xFF0E1330),
            ],
          ),
        ),
      ),
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: const Text('Liquid YT', style: _sTitle),
      ),
      // Píldora seleccionada SÓLIDA (azul), no transparente: en iOS 27 la
      // selección es una píldora con color, no un cristal lavado. El
      // indicador es lo que marca la sección activa.
      bottomBar: GlassTabBar.bottom(
        selectedIndex: _tabIndex,
        onTabSelected: (i) => setState(() => _tabIndex = i),
        tabs: const [
          GlassTab(icon: Icon(Icons.search), label: 'Buscar'),
          GlassTab(icon: Icon(Icons.download), label: 'Descargas'),
        ],
        indicatorColor: const Color(0xFF4F7CFF),
        indicatorSettings: const LiquidGlassSettings(
          blur: 10,
          frost: 12,
          saturation: 1.6,
          glassColor: Color(0xFF4F7CFF),
        ),
        selectedIconColor: Colors.white,
        unselectedIconColor: Colors.white54,
        selectedLabelColor: Colors.white,
        unselectedLabelColor: Colors.white54,
        selectedLabelStyle:
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle:
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        labelFontSize: 11,
        barHeight: 66,
      ),
      body: _tabIndex == 0 ? _buildSearchTab() : _buildDownloadsTab(),
    );
  }

  /// Tarjeta de cristal con fondo de respaldo oscuro y opaco: así el
  /// glass se ve con cuerpo y no como un vidrio lavado sobre el fondo.
  Widget _glassCard({required Widget child, EdgeInsets? padding}) {
    return GlassContainer.card(
      shape: const LiquidRoundedSuperellipse(borderRadius: 24),
      useOwnLayer: true,
      settings: _cardGlassSettings,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(20),
        child: child,
      ),
    );
  }

  /// Chip de formato estilo iOS: el seleccionado es una píldora azul
  /// sólida con letra blanca; el no seleccionado, cristal tenue.
  Widget _formatChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      label: Text(label, style: _sChip.copyWith(
        color: selected ? Colors.white : Colors.white.withValues(alpha: 0.85),
      )),
      selected: selected,
      selectedColor: const Color(0xFF4F7CFF),
      backgroundColor: Colors.white.withValues(alpha: 0.08),
      side: BorderSide(
        color: selected
            ? Colors.transparent
            : Colors.white.withValues(alpha: 0.18),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      onSelected: (_) => onTap(),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(text, style: _sSection),
    );
  }

  Widget _buildSearchTab() {
    return ListView(
      // Más aire: más padding lateral y más espacio entre secciones.
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 140),
      children: [
        // Título grande estilo iOS (solo el título de pantalla es grande;
        // el resto de la letra es modesta: 13-16).
        const Padding(
          padding: EdgeInsets.only(left: 4, top: 8, bottom: 4),
          child: Text('Liquid YT', style: _sScreenTitle),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 20),
          child: Text(
            'Descarga videos y audio de YouTube en tu teléfono',
            style: _sCaption,
          ),
        ),
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt, color: Colors.cyanAccent, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _engineBusy
                          ? 'Preparando motor en segundo plano… no cierres la app'
                          : _engineReady
                              ? 'Motor listo · descarga en tu teléfono'
                              : 'Motor no listo · se prepara solo al descargar',
                      style: _sBody.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (_engineVersions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_engineVersions, style: _sCaption),
                ),
              if (_engineError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_engineError!,
                      style: _sBody.copyWith(color: Colors.orangeAccent)),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _queryController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                style: const TextStyle(fontSize: 14, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Busca una rola o pega el link de YouTube',
                  hintStyle: const TextStyle(
                      fontSize: 14, color: Colors.white54),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () => _queryController.clear(),
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _searching ? null : _search,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4F7CFF),
                    foregroundColor: Colors.white,
                    textStyle: _sButton,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.search, size: 20),
                  label: Text(_searching ? 'Buscando…' : 'Buscar'),
                ),
              ),
            ],
          ),
        ),
        if (_activeProcessId != null) ...[
          const SizedBox(height: 20),
          _glassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _activeTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _sTitle.copyWith(fontSize: 15),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress / 100 : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_progress.toStringAsFixed(0)}% · ${_activeStatus.isNotEmpty ? _activeStatus : 'Descargando'}'
                        '${_etaSeconds > 0 ? ' · ETA ${_etaSeconds}s' : ''}',
                        style: _sCaption,
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelDownload,
                      child: const Text('Cancelar', style: _sBody),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_resolving) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator()),
        ],
        if (_resolved != null) ...[
          const SizedBox(height: 20),
          _buildResolvedCard(_resolved!),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 24),
          _sectionTitle('Resultados'),
          ..._results.map(_buildResultTile),
        ],
      ],
    );
  }

  Widget _buildResultTile(SearchItem item) {
    final disabled = _resolving;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _glassCard(
        padding: const EdgeInsets.all(12),
        child: InkWell(
          // Mientras se resuelve otro video, el toque se desactiva:
          // en v1.0.6 un doble toque lanzaba dos getVideoInfo nativos
          // a la vez.
          onTap: disabled ? null : () => _resolveAndShow(item.url, fromSearch: item),
          borderRadius: BorderRadius.circular(20),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  item.thumbnailUrl,
                  width: 112,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 112,
                    height: 64,
                    color: Colors.white12,
                    child: const Icon(Icons.play_arrow),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _sBody.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${item.channel}${item.durationText.isNotEmpty ? ' · ${item.durationText}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _sCaption,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: disabled ? Colors.white24 : Colors.white54,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResolvedCard(ResolvedVideo video) {
    final direct = _directFormats;
    final selected = _selectedDirectFormat ?? _selectedFormat;
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: video.thumbnailUrl.isNotEmpty
                    ? Image.network(
                        video.thumbnailUrl,
                        width: 112,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 112,
                          height: 64,
                          color: Colors.white12,
                          child: const Icon(Icons.play_arrow),
                        ),
                      )
                    : Container(
                        width: 112,
                        height: 64,
                        color: Colors.white12,
                        child: const Icon(Icons.play_arrow),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: _sTitle,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${video.channel}${video.durationText.isNotEmpty ? ' · ${video.durationText}' : ''}',
                      style: _sCaption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('Formato', style: _sSection),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: YtService.presets().map((f) {
              final isSel =
                  _selectedDirectFormat == null && _selectedFormat.id == f.id;
              return _formatChip(
                label: f.label,
                selected: isSel,
                onTap: () => setState(() {
                  _selectedFormat = f;
                  _selectedDirectFormat = null;
                }),
              );
            }).toList(),
          ),
          if (direct.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Descarga directa · sin motor', style: _sSection),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: direct.map((f) {
                final isSel = _selectedDirectFormat?.id == f.id;
                return _formatChip(
                  label: f.label,
                  selected: isSel,
                  onTap: () => setState(() {
                    _selectedDirectFormat = f;
                  }),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              // Mientras se prepara el motor, el botón se desactiva: no
              // se puede lanzar dos descargas ni dos inits a la vez.
              onPressed: (_activeProcessId != null || _engineBusy)
                  ? null
                  : () => _startDownload(video, selected),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF4F7CFF),
                foregroundColor: Colors.white,
                textStyle: _sButton,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: _engineBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.download, size: 20),
              label: Text(_engineBusy
                  ? 'Preparando motor…'
                  : 'Descargar · ${selected.label}'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 140),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, top: 8, bottom: 4),
          child: Text('Descargas', style: _sScreenTitle),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 20),
          child: Text(
            _history.isEmpty
                ? 'Tus archivos descargados aparecen aquí'
                : '${_history.length} archivo${_history.length == 1 ? '' : 's'} descargado${_history.length == 1 ? '' : 's'}',
            style: _sCaption,
          ),
        ),
        _glassCard(
          child: Row(
            children: [
              const Icon(Icons.folder, color: Colors.cyanAccent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Carpeta de descargas', style: _sSection),
                    const SizedBox(height: 3),
                    Text(
                      _outputDirLabel.isEmpty
                          ? 'Descargas / LiquidYT'
                          : _outputDirLabel,
                      style: _sCaption,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 22),
                onPressed: _loadHistory,
              ),
            ],
          ),
        ),
        if (_crashLogPath != null || _lastActionPath != null) ...[
          const SizedBox(height: 20),
          _glassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.warning_amber,
                        color: Colors.orangeAccent, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Registro de un error anterior',
                        style: _sSection,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Si la app se vuelve a cerrar, mándame estos archivos:',
                  style: _sBody,
                ),
                if (_crashLogPath != null) ...[
                  const SizedBox(height: 6),
                  Text('crash.log:\n$_crashLogPath', style: _sCaption),
                ],
                if (_lastActionPath != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'last_action.log (qué estaba haciendo al cerrarse):\n$_lastActionPath',
                    style: _sCaption,
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (_history.isEmpty)
          _glassCard(
            child: const Column(
              children: [
                Icon(Icons.download_done, size: 40, color: Colors.white54),
                SizedBox(height: 10),
                Text(
                  'Aún no hay descargas.\nBusca una rola y bájala.',
                  textAlign: TextAlign.center,
                  style: _sBody,
                ),
              ],
            ),
          )
        else
          ..._history.map((r) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _glassCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(Icons.audiotrack,
                        color: Colors.cyanAccent, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: _sBody.copyWith(
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${r.formatLabel}${_sizeText(r.sizeBytes).isNotEmpty ? ' · ${_sizeText(r.sizeBytes)}' : ''}',
                            style: _sCaption,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow, size: 22),
                      onPressed: () => OpenFile.open(r.path),
                      tooltip: 'Abrir / reproducir',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 22),
                      onPressed: () => _deleteRecord(r),
                      tooltip: 'Borrar',
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  /// Menú flotante al compartir desde YouTube: miniatura, título,
  /// selector de calidad/formato y botón de descarga.
  void _openDownloadSheet(ResolvedVideo video) {
    FormatOption selected = YtService.presets().first;
    FormatOption? selectedDirect;
    // Los formatos directos se cargaron en segundo plano (HTTP) al
    // resolver el video; si aún no llegaron, el menú muestra solo los
    // fijos con motor. Nada nativo corre al abrir este menú.
    final direct = List<FormatOption>.from(_directFormats);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final current = selectedDirect ?? selected;
            final real = direct;
            return Container(
              decoration: BoxDecoration(
                color: const Color(0xF2141B3D),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.25)),
              ),
              padding: EdgeInsets.fromLTRB(
                24,
                12,
                24,
                MediaQuery.of(ctx).viewInsets.bottom + 28,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white38,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: video.thumbnailUrl.isNotEmpty
                            ? Image.network(
                                video.thumbnailUrl,
                                width: 112,
                                height: 64,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 112,
                                  height: 64,
                                  color: Colors.white12,
                                  child: const Icon(Icons.play_arrow),
                                ),
                              )
                            : Container(
                                width: 112,
                                height: 64,
                                color: Colors.white12,
                                child: const Icon(Icons.play_arrow),
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: _sTitle,
                            ),
                            const SizedBox(height: 5),
                            Text(video.channel, style: _sCaption),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('Calidad y formato', style: _sSection),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: YtService.presets().map((f) {
                      final isSel =
                          selectedDirect == null && selected.id == f.id;
                      return _formatChip(
                        label: f.label,
                        selected: isSel,
                        onTap: () => setSheetState(() {
                          selected = f;
                          selectedDirect = null;
                        }),
                      );
                    }).toList(),
                  ),
                  if (real.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: real.map((f) {
                        final isSel = selectedDirect?.id == f.id;
                        return _formatChip(
                          label: f.label,
                          selected: isSel,
                          onTap: () => setSheetState(() {
                            selectedDirect = f;
                          }),
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _activeProcessId != null
                          ? null
                          : () {
                              Navigator.of(sheetContext).pop();
                              _startDownload(video, current);
                              setState(() => _tabIndex = 0);
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF4F7CFF),
                        foregroundColor: Colors.white,
                        textStyle: _sButton,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: const Icon(Icons.download, size: 20),
                      label: Text('Descargar · ${current.label}'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

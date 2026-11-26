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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();
  runApp(LiquidGlassWidgets.wrap(
    brightnessResolver: Theme.maybeBrightnessOf,
    theme: const GlassThemeData.ios27(),
    child: const LiquidYtApp(),
  ));
}

class LiquidYtApp extends StatelessWidget {
  const LiquidYtApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liquid YT',
      debugShowCheckedModeBanner: false,
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
  bool _engineBusy = true;
  String? _engineError;
  String _engineVersions = '';

  bool _searching = false;
  bool _resolving = false;
  List<SearchItem> _results = [];
  ResolvedVideo? _resolved;
  FormatOption _selectedFormat = YtService.presets().first;
  FormatOption? _selectedRealFormat;

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
    _boot();
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
    await Permission.storage.request();
    await _loadHistory();
    await _refreshOutputDirLabel();
    final ok = await _yt.init();
    if (!mounted) return;
    setState(() {
      _engineReady = ok;
      _engineBusy = false;
      _engineError = ok ? null : _yt.engineError;
    });
    if (ok) {
      _engineVersions = await _yt.engineVersions();
      if (mounted) setState(() {});
      unawaited(_yt.updateEngine());
    }
    _listenToDownloads();
    _checkSharedText();
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
    final ext = await getExternalStorageDirectory();
    final dir = Directory('${ext!.path}/LiquidYT');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _refreshOutputDirLabel() async {
    final dir = await _outputDir();
    if (mounted) setState(() => _outputDirLabel = dir.path);
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final saved =
        DownloadRecord.decodeList(prefs.getString('liquidyt_history') ?? '[]');
    final dir = await _outputDir();
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
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _search() async {
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

  Future<void> _resolveAndShow(String url) async {
    if (!_engineReady) {
      _snack('El motor yt-dlp aún se está preparando…');
      return;
    }
    setState(() {
      _resolving = true;
      _resolved = null;
      _selectedRealFormat = null;
      _selectedFormat = YtService.presets().first;
    });
    try {
      final video = await _yt.resolve(url);
      if (!mounted) return;
      setState(() => _resolved = video);
    } catch (e) {
      if (mounted) _snack('No se pudo leer ese video: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _resolveAndOpenSheet(String url) async {
    await _resolveAndShow(url);
    if (!mounted || _resolved == null) return;
    _openDownloadSheet(_resolved!);
  }

  Future<void> _startDownload(ResolvedVideo video, FormatOption option) async {
    if (_activeProcessId != null) {
      _snack('Ya hay una descarga en curso, espera a que termine');
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _activeProcessId = null;
        _activeStatus = '';
      });
      _snack(_friendlyError(e.toString()));
    }
  }

  String _friendlyError(String raw) {
    final low = raw.toLowerCase();
    if (low.contains('sign in') || low.contains('not a bot')) {
      return 'YouTube pidió verificación para ese video. Prueba con otro video o actualiza yt-dlp en Ajustes.';
    }
    if (low.contains('private') || low.contains('unavailable')) {
      return 'Ese video es privado o no está disponible.';
    }
    return 'No se pudo descargar: $raw';
  }

  Future<void> _cancelDownload() async {
    final id = _activeProcessId;
    if (id == null) return;
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

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      background: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0B1026),
              Color(0xFF1B2A6B),
              Color(0xFF3B1D5E),
              Color(0xFF0B1026),
            ],
          ),
        ),
      ),
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: const Text('Liquid YT'),
      ),
      bottomBar: GlassTabBar.bottom(
        selectedIndex: _tabIndex,
        onTabSelected: (i) => setState(() => _tabIndex = i),
        tabs: const [
          GlassTab(icon: Icon(Icons.search), label: 'Buscar'),
          GlassTab(icon: Icon(Icons.download), label: 'Descargas'),
        ],
      ),
      body: _tabIndex == 0 ? _buildSearchTab() : _buildDownloadsTab(),
    );
  }

  Widget _glassCard({required Widget child, EdgeInsets? padding}) {
    return GlassContainer.card(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  Widget _buildSearchTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
      children: [
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt, color: Colors.cyanAccent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _engineBusy
                          ? 'Preparando yt-dlp en tu teléfono…'
                          : _engineReady
                              ? 'Motor listo · descarga en tu teléfono'
                              : 'Motor no listo',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (_engineVersions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _engineVersions,
                    style: TextStyle(color: Colors.white.withOpacity(0.65)),
                  ),
                ),
              if (_engineError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _engineError!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _queryController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'Busca una rola o pega el link de YouTube',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => _queryController.clear(),
                  ),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _searching ? null : _search,
                  icon: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(_searching ? 'Buscando…' : 'Buscar'),
                ),
              ),
            ],
          ),
        ),
        if (_activeProcessId != null) ...[
          const SizedBox(height: 12),
          _glassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _activeTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress / 100 : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_progress.toStringAsFixed(0)}% · ${_activeStatus.isNotEmpty ? _activeStatus : 'Descargando'}'
                        '${_etaSeconds > 0 ? ' · ETA ${_etaSeconds}s' : ''}',
                        style: TextStyle(color: Colors.white.withOpacity(0.7)),
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelDownload,
                      child: const Text('Cancelar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_resolving) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ],
        if (_resolved != null) ...[
          const SizedBox(height: 12),
          _buildResolvedCard(_resolved!),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Resultados',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ..._results.map(_buildResultTile),
        ],
      ],
    );
  }

  Widget _buildResultTile(SearchItem item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _glassCard(
        padding: const EdgeInsets.all(10),
        child: InkWell(
          onTap: () => _resolveAndShow(item.url),
          borderRadius: BorderRadius.circular(16),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  item.thumbnailUrl,
                  width: 120,
                  height: 68,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 120,
                    height: 68,
                    color: Colors.white12,
                    child: const Icon(Icons.play_arrow),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.channel}${item.durationText.isNotEmpty ? ' · ${item.durationText}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: Colors.white.withOpacity(0.65)),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResolvedCard(ResolvedVideo video) {
    final real = YtService.realFormats(video);
    final selected = _selectedRealFormat ?? _selectedFormat;
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
                        width: 120,
                        height: 68,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 120,
                          height: 68,
                          color: Colors.white12,
                          child: const Icon(Icons.play_arrow),
                        ),
                      )
                    : Container(
                        width: 120,
                        height: 68,
                        color: Colors.white12,
                        child: const Icon(Icons.play_arrow),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${video.channel}${video.durationText.isNotEmpty ? ' · ${video.durationText}' : ''}',
                      style:
                          TextStyle(color: Colors.white.withOpacity(0.65)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text('Formato',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: YtService.presets().map((f) {
              final isSel =
                  _selectedRealFormat == null && _selectedFormat.id == f.id;
              return ChoiceChip(
                label: Text(f.label),
                selected: isSel,
                onSelected: (_) => setState(() {
                  _selectedFormat = f;
                  _selectedRealFormat = null;
                }),
              );
            }).toList(),
          ),
          if (real.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Formatos reales del video',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: real.map((f) {
                final isSel = _selectedRealFormat?.id == f.id;
                return ChoiceChip(
                  label: Text('${f.label} · ${f.detail}'),
                  selected: isSel,
                  onSelected: (_) => setState(() {
                    _selectedRealFormat = f;
                  }),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _activeProcessId != null
                  ? null
                  : () => _startDownload(video, selected),
              icon: const Icon(Icons.download),
              label: Text('Descargar · ${selected.label}'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
      children: [
        _glassCard(
          child: Row(
            children: [
              const Icon(Icons.folder, color: Colors.cyanAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Carpeta de descargas',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      _outputDirLabel.isEmpty
                          ? 'Descargas / LiquidYT'
                          : _outputDirLabel,
                      style:
                          TextStyle(color: Colors.white.withOpacity(0.65)),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loadHistory,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_history.isEmpty)
          _glassCard(
            child: const Column(
              children: [
                Icon(Icons.download_done, size: 40, color: Colors.white54),
                SizedBox(height: 8),
                Text('Aún no hay descargas.\nBusca una rola y bájala.',
                    textAlign: TextAlign.center),
              ],
            ),
          )
        else
          ..._history.map((r) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _glassCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.audiotrack, color: Colors.cyanAccent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${r.formatLabel}${_sizeText(r.sizeBytes).isNotEmpty ? ' · ${_sizeText(r.sizeBytes)}' : ''}',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.65)),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => OpenFile.open(r.path),
                      tooltip: 'Abrir / reproducir',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
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
    FormatOption? selectedReal;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final current = selectedReal ?? selected;
            final real = YtService.realFormats(video);
            return Container(
              decoration: BoxDecoration(
                color: const Color(0xCC141B3D),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(color: Colors.white.withOpacity(0.25)),
              ),
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 24,
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
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: video.thumbnailUrl.isNotEmpty
                            ? Image.network(
                                video.thumbnailUrl,
                                width: 120,
                                height: 68,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 120,
                                  height: 68,
                                  color: Colors.white12,
                                  child: const Icon(Icons.play_arrow),
                                ),
                              )
                            : Container(
                                width: 120,
                                height: 68,
                                color: Colors.white12,
                                child: const Icon(Icons.play_arrow),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              video.channel,
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.65)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Calidad y formato',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: YtService.presets().map((f) {
                      final isSel =
                          selectedReal == null && selected.id == f.id;
                      return ChoiceChip(
                        label: Text(f.label),
                        selected: isSel,
                        onSelected: (_) => setSheetState(() {
                          selected = f;
                          selectedReal = null;
                        }),
                      );
                    }).toList(),
                  ),
                  if (real.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: real.map((f) {
                        final isSel = selectedReal?.id == f.id;
                        return ChoiceChip(
                          label: Text(f.label),
                          selected: isSel,
                          onSelected: (_) => setSheetState(() {
                            selectedReal = f;
                          }),
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 16),
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
                      icon: const Icon(Icons.download),
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

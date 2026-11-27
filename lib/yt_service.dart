import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'models.dart';

/// Servicio de YouTube:
/// - Búsqueda por texto y metadatos con youtube_explode_dart (sin API key,
///   solo HTTP, nada nativo).
/// - Descarga DIRECTA por HTTP de los streams del manifiesto (MP4 360p
///   muxed y audio M4A): no toca el motor nativo, no puede cerrar la app.
/// - Descarga con el plugin `extractor` (fork local en
///   packages/extractor: yt-dlp real en el teléfono, Python + FFmpeg
///   incluidos en el APK) SOLO para MP3 y MP4 720p/480p, y SOLO cuando
///   el usuario presiona Descargar. Nada nativo corre al tocar una rola.
///
/// v1.0.9: se ELIMINÓ resolve() (getVideoInfo nativo). Era lo que mataba
/// la app: tocar una canción disparaba _fetchRealFormats -> _ensureEngine
/// -> init del motor en el hilo principal (log del usuario: "iniciando
/// motor yt-dlp"). Los formatos reales ahora vienen del manifiesto HTTP.
class YtService {
  final YoutubeDLFlutter _dl = YoutubeDLFlutter.instance;

  bool initialized = false;
  String? engineError;

  Stream<DownloadProgress> get progressStream => _dl.onProgress;
  Stream<DownloadState> get stateStream => _dl.onStateChanged;
  Stream<DownloadError> get errorStream => _dl.onError;

  /// Inicia yt-dlp + FFmpeg en el dispositivo. Con el fork local, la
  /// extracción pesada corre en Dispatchers.IO (ya no en el hilo
  /// principal), así que no congela ni cierra la app. Primera vez tarda
  /// unos segundos porque extrae Python + FFmpeg.
  Future<bool> init() async {
    try {
      final result =
          await _dl.initialize(enableFFmpeg: true, enableAria2c: false);
      initialized = result.success;
      if (!result.success) {
        engineError = result.errorMessage ?? 'No se pudo iniciar yt-dlp';
      }
      return initialized;
    } catch (e) {
      engineError = e.toString();
      return false;
    }
  }

  Future<String> engineVersions() async {
    try {
      final v = await _dl.getVersion();
      return 'yt-dlp ${v.youtubeDlVersion ?? '?'} · FFmpeg ${v.ffmpegVersion ?? '?'}';
    } catch (_) {
      return '';
    }
  }

  /// Búsqueda real por texto. Devuelve hasta 10 videos.
  Future<List<SearchItem>> search(String query) async {
    final yt = YoutubeExplode();
    try {
      final results = await yt.search.search(query);
      final items = <SearchItem>[];
      for (final v in results.take(10)) {
        items.add(SearchItem(
          videoId: v.id.value,
          title: v.title,
          channel: v.author,
          thumbnailUrl: v.thumbnails.mediumResUrl.toString(),
          duration: v.duration,
        ));
      }
      return items;
    } finally {
      yt.close();
    }
  }

  /// Metadatos ligeros de un video SIN yt-dlp: solo HTTP con
  /// youtube_explode. No toca código nativo, así que no puede matar la
  /// app. Sirve para pintar la tarjeta al instante.
  Future<ResolvedVideo> videoMeta(String url) async {
    final yt = YoutubeExplode();
    try {
      final v = await yt.videos.get(url);
      return ResolvedVideo(
        url: url,
        title: v.title,
        channel: v.author,
        thumbnailUrl: v.thumbnails.mediumResUrl.toString(),
        durationSeconds: v.duration?.inSeconds,
        formats: const [],
      );
    } finally {
      yt.close();
    }
  }

  /// Formatos de descarga DIRECTA (sin motor nativo) sacados del
  /// manifiesto de streams con solo HTTP. Devuelve [] si YouTube no
  /// entrega el manifiesto para ese video (pasa con algunas rolas:
  /// VideoUnavailableException) — en ese caso la tarjeta se queda con
  /// los formatos fijos y la descarga usa el motor al presionar
  /// Descargar. Nunca tira: cualquier error devuelve lista vacía.
  Future<List<FormatOption>> directFormats(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streams.getManifest(videoId);
      final out = <FormatOption>[];
      // MP4 muxed (video + audio en un solo archivo, normalmente 360p):
      // descarga directa, sin FFmpeg ni motor.
      final muxed = manifest.muxed;
      if (muxed.isNotEmpty) {
        final best = muxed.withHighestBitrate();
        out.add(FormatOption(
          id: 'direct-mp4',
          label: 'MP4 · ${best.qualityLabel} · Directa',
          detail: 'Video + audio, sin motor',
          formatString: '',
          audioOnly: false,
          directUrl: best.url.toString(),
          directExt: 'mp4',
        ));
      }
      // Audio M4A (AAC, sin convertir): descarga directa, sin motor.
      final audioMp4 = manifest.audioOnly
          .where((s) => s.container == StreamContainer.mp4)
          .toList();
      if (audioMp4.isNotEmpty) {
        audioMp4.sort((a, b) => b.bitrate.compareTo(a.bitrate));
        final best = audioMp4.first;
        out.add(FormatOption(
          id: 'direct-m4a',
          label: 'M4A · Audio · Directa',
          detail: 'Solo audio, sin motor',
          formatString: '',
          audioOnly: true,
          audioFormat: 'm4a',
          directUrl: best.url.toString(),
          directExt: 'm4a',
        ));
      }
      return out;
    } catch (_) {
      return const [];
    } finally {
      yt.close();
    }
  }

  /// Descarga directa por HTTP de una URL de stream (googlevideo).
  /// Sin código nativo. [onProgress] recibe (recibidos, total).
  /// Devuelve la ruta del archivo escrito.
  HttpClient? _httpClient;

  /// Cancela una descarga directa en curso (cierra el cliente HTTP).
  void cancelHttp() {
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  Future<String> downloadHttp({
    required String url,
    required String outputPath,
    void Function(int received, int total)? onProgress,
  }) async {
    final client = HttpClient();
    _httpClient = client;
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException(
            'YouTube devolvió HTTP ${response.statusCode} para ese video');
      }
      final total = response.contentLength;
      final file = File(outputPath);
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        if (onProgress != null) onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      return file.path;
    } finally {
      if (_httpClient == client) _httpClient = null;
      client.close();
    }
  }

  /// Saca el ID de 11 caracteres de cualquier link de YouTube.
  static String? videoIdFromUrl(String url) {
    final m = RegExp(
      r'(?:v=|/shorts/|/embed/|/live/|youtu\.be/)([A-Za-z0-9_-]{11})',
    ).firstMatch(url);
    return m?.group(1);
  }

  /// Descarga con yt-dlp (motor nativo). Solo se llama DESPUÉS de que
  /// el motor quedó listo, y solo al presionar Descargar.
  /// [processId] sirve para el progreso y para cancelar.
  Future<DownloadResult> download({
    required String url,
    required String outputDir,
    required FormatOption option,
    required String processId,
  }) {
    return _dl.download(DownloadRequest(
      url: url,
      outputPath: outputDir,
      outputTemplate: '%(title)s.%(ext)s',
      format: option.formatString,
      noPlaylist: true,
      extractAudio: option.audioOnly,
      audioFormat: option.audioOnly ? option.audioFormat : null,
      audioQuality: option.audioOnly ? 0 : null,
      embedThumbnail: false,
      embedMetadata: true,
      processId: processId,
    ));
  }

  Future<bool> cancel(String processId) => _dl.cancelDownload(processId);

  /// Formatos fijos que usan el motor yt-dlp (al presionar Descargar).
  /// yt-dlp elige el mejor stream disponible dentro de cada límite
  /// (FFmpeg une video + audio en MP4 o convierte a MP3).
  static List<FormatOption> presets() => const [
        FormatOption(
          id: 'mp3',
          label: 'MP3 · Audio',
          detail: 'Solo audio, en MP3',
          formatString: 'bestaudio/best',
          audioOnly: true,
          audioFormat: 'mp3',
        ),
        FormatOption(
          id: 'm4a',
          label: 'M4A · Audio',
          detail: 'Solo audio, sin convertir',
          formatString: 'bestaudio[ext=m4a]/bestaudio/best',
          audioOnly: true,
          audioFormat: 'm4a',
        ),
        FormatOption(
          id: 'mp4-720',
          label: 'MP4 · 720p',
          detail: 'Video HD + audio',
          formatString:
              'bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]',
          audioOnly: false,
        ),
        FormatOption(
          id: 'mp4-480',
          label: 'MP4 · 480p',
          detail: 'Video SD + audio',
          formatString:
              'bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=480]+bestaudio/best[height<=480]',
          audioOnly: false,
        ),
        FormatOption(
          id: 'mp4-360',
          label: 'MP4 · 360p',
          detail: 'Video ligero + audio',
          formatString:
              'bestvideo[height<=360][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=360]+bestaudio/best[height<=360]',
          audioOnly: false,
        ),
      ];

  /// Extrae el primer link de YouTube de un texto compartido.
  static String? extractYoutubeUrl(String text) {
    final regex = RegExp(
      r'(https?://(?:www\.|m\.)?(?:youtube\.com/watch\?[^ \n]+|youtu\.be/[A-Za-z0-9_-]{11}|youtube\.com/shorts/[A-Za-z0-9_-]{11}|youtube\.com/embed/[A-Za-z0-9_-]{11}|youtube\.com/live/[A-Za-z0-9_-]{11}))',
      caseSensitive: false,
    );
    return regex.firstMatch(text)?.group(1);
  }

  static bool looksLikeYoutubeUrl(String text) {
    final t = text.trim().toLowerCase();
    return t.contains('youtube.com') || t.contains('youtu.be');
  }
}

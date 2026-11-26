import 'package:extractor/extractor.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'models.dart';

/// Servicio de YouTube:
/// - Búsqueda por texto con youtube_explode_dart (sin API key, solo metadatos).
/// - Resolución de link y descarga con el plugin `extractor`, que corre el
///   yt-dlp real en el teléfono (youtubedl-android: Python + FFmpeg incluidos
///   en el APK). Nada se descarga desde un servidor.
class YtService {
  final YoutubeDLFlutter _dl = YoutubeDLFlutter.instance;

  bool initialized = false;
  String? engineError;

  Stream<DownloadProgress> get progressStream => _dl.onProgress;
  Stream<DownloadState> get stateStream => _dl.onStateChanged;
  Stream<DownloadError> get errorStream => _dl.onError;

  /// Inicia yt-dlp + FFmpeg en el dispositivo. Primera vez tarda unos segundos.
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

  Future<void> updateEngine() async {
    try {
      await _dl.updateYoutubeDL(channel: UpdateChannel.stable);
    } catch (_) {
      // Si no hay internet o GitHub limita, se sigue con el yt-dlp incluido.
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

  /// Resuelve un link de YouTube con yt-dlp: título, canal, duración,
  /// miniatura y la lista REAL de formatos del video.
  Future<ResolvedVideo> resolve(String url) async {
    final info = await _dl.getVideoInfo(url);
    final formats = <VideoFormatInfo>[];
    for (final f in info.formats ?? <VideoFormat?>[]) {
      if (f == null || f.formatId == null) continue;
      formats.add(VideoFormatInfo(
        formatId: f.formatId!,
        ext: f.ext ?? '',
        resolution: f.resolution ?? '',
        height: f.height,
        vcodec: f.vcodec ?? 'none',
        acodec: f.acodec ?? 'none',
        filesize: f.filesize,
      ));
    }
    return ResolvedVideo(
      url: url,
      title: info.title ?? 'Video de YouTube',
      channel: info.uploader ?? '',
      thumbnailUrl: info.thumbnail ?? '',
      durationSeconds: info.duration,
      viewCount: info.viewCount,
      formats: formats,
    );
  }

  /// Descarga con yt-dlp. [processId] sirve para el progreso y para cancelar.
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

  /// Formatos fijos que pide el usuario. yt-dlp elige el mejor stream
  /// disponible dentro de cada límite (FFmpeg une video + audio en MP4).
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

  /// Opciones armadas con los formatos REALES del video (por ID de yt-dlp).
  static List<FormatOption> realFormats(ResolvedVideo video) {
    final out = <FormatOption>[];
    final seen = <String>{};
    // Combinados (video + audio en un solo archivo).
    for (final f in video.formats) {
      if (!f.hasVideo || !f.hasAudio) continue;
      final h = f.height;
      final label = h != null ? 'MP4 · ${h}p' : 'MP4 · ${f.resolution}';
      final key = '$label-${f.ext}';
      if (!seen.add(key)) continue;
      out.add(FormatOption(
        id: 'real-${f.formatId}',
        label: label,
        detail: 'Formato ${f.formatId} · ${f.ext}',
        formatString: f.formatId,
        audioOnly: false,
      ));
    }
    // Video solo (se une con el mejor audio vía FFmpeg).
    for (final f in video.formats) {
      if (!f.hasVideo || f.hasAudio) continue;
      final h = f.height;
      if (h == null) continue;
      final label = 'MP4 · ${h}p';
      if (!seen.add('v$h')) continue;
      out.add(FormatOption(
        id: 'real-${f.formatId}',
        label: label,
        detail: 'Formato ${f.formatId} · ${f.ext} + audio',
        formatString: '${f.formatId}+bestaudio/best',
        audioOnly: false,
      ));
    }
    out.sort((a, b) {
      int h(String s) {
        final m = RegExp(r'(\d+)p').firstMatch(s);
        return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
      }

      return h(b.label).compareTo(h(a.label));
    });
    return out.take(6).toList();
  }

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

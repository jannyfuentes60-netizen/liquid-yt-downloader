import 'dart:convert';

/// Un resultado de la búsqueda de YouTube.
class SearchItem {
  final String videoId;
  final String title;
  final String channel;
  final String thumbnailUrl;
  final Duration? duration;

  const SearchItem({
    required this.videoId,
    required this.title,
    required this.channel,
    required this.thumbnailUrl,
    this.duration,
  });

  String get url => 'https://www.youtube.com/watch?v=$videoId';

  String get durationText {
    final d = duration;
    if (d == null) return '';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (d.inHours > 0) {
      return '${d.inHours}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// Una opción de formato/calidad para descargar.
class FormatOption {
  final String id;
  final String label;
  final String detail;
  final String formatString;
  final bool audioOnly;
  final String audioFormat;

  const FormatOption({
    required this.id,
    required this.label,
    required this.detail,
    required this.formatString,
    required this.audioOnly,
    this.audioFormat = '',
  });
}

/// Un video resuelto con sus formatos reales (de yt-dlp).
class ResolvedVideo {
  final String url;
  final String title;
  final String channel;
  final String thumbnailUrl;
  final int? durationSeconds;
  final int? viewCount;
  final List<VideoFormatInfo> formats;

  const ResolvedVideo({
    required this.url,
    required this.title,
    required this.channel,
    required this.thumbnailUrl,
    this.durationSeconds,
    this.viewCount,
    this.formats = const [],
  });

  String get durationText {
    final s = durationSeconds;
    if (s == null) return '';
    final m = s ~/ 60;
    final r = s % 60;
    if (s >= 3600) {
      return '${s ~/ 3600}:${((m % 60)).toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
    }
    return '$m:${r.toString().padLeft(2, '0')}';
  }
}

/// Formato real tal como lo reporta yt-dlp (sin depender del modelo del plugin).
class VideoFormatInfo {
  final String formatId;
  final String ext;
  final String resolution;
  final int? height;
  final String vcodec;
  final String acodec;
  final int? filesize;

  const VideoFormatInfo({
    required this.formatId,
    required this.ext,
    required this.resolution,
    this.height,
    required this.vcodec,
    required this.acodec,
    this.filesize,
  });

  bool get hasVideo => vcodec != 'none' && vcodec.isNotEmpty;
  bool get hasAudio => acodec != 'none' && acodec.isNotEmpty;
}

/// Un archivo ya descargado (historial).
class DownloadRecord {
  final String title;
  final String url;
  final String path;
  final String formatLabel;
  final int dateMs;
  final int sizeBytes;

  const DownloadRecord({
    required this.title,
    required this.url,
    required this.path,
    required this.formatLabel,
    required this.dateMs,
    required this.sizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'path': path,
        'formatLabel': formatLabel,
        'dateMs': dateMs,
        'sizeBytes': sizeBytes,
      };

  factory DownloadRecord.fromJson(Map<String, dynamic> j) => DownloadRecord(
        title: j['title'] as String? ?? 'Video',
        url: j['url'] as String? ?? '',
        path: j['path'] as String? ?? '',
        formatLabel: j['formatLabel'] as String? ?? '',
        dateMs: j['dateMs'] as int? ?? 0,
        sizeBytes: j['sizeBytes'] as int? ?? 0,
      );

  static String encodeList(List<DownloadRecord> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());

  static List<DownloadRecord> decodeList(String raw) {
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => DownloadRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

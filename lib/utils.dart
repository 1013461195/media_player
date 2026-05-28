const imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.bmp',
  '.webp',
  '.heic',
};

const videoExtensions = {
  '.mp4',
  '.m4v',
  '.mov',
  '.mkv',
  '.avi',
  '.webm',
  '.ts',
  '.m2ts',
  '.flv',
  '.wmv',
};

const smbDirectoryAttribute = 0x10;
const serversPrefKey = 'nas_servers';
const lastServerIdPrefKey = 'last_server_id';

String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  return name.substring(dot).toLowerCase();
}

bool isImage(String name) => imageExtensions.contains(extensionOf(name));
bool isVideo(String name) => videoExtensions.contains(extensionOf(name));

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes < 1024 * 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(1)} TB';
}

String formatDate(int epochMillis) {
  final date = DateTime.fromMillisecondsSinceEpoch(epochMillis).toLocal();
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String friendlyError(Object? error) {
  if (error == null) return '未知错误';
  final msg = error.toString();
  final match = RegExp(r"message:\s*'([^']*)'").firstMatch(msg);
  if (match != null) return match.group(1)!;
  if (msg.startsWith('Exception: ')) return msg.substring(11);
  return msg;
}

String formatDuration(Duration duration) {
  final h = duration.inHours;
  final m = duration.inMinutes.remainder(60);
  final s = duration.inSeconds.remainder(60);
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String contentTypeFor(String path) {
  final ext = extensionOf(path);
  switch (ext) {
    case '.mp4':
    case '.m4v':
      return 'video/mp4';
    case '.mkv':
      return 'video/x-matroska';
    case '.avi':
      return 'video/x-msvideo';
    case '.mov':
      return 'video/quicktime';
    case '.webm':
      return 'video/webm';
    case '.ts':
    case '.m2ts':
      return 'video/mp2t';
    case '.flv':
      return 'video/x-flv';
    case '.wmv':
      return 'video/x-ms-wmv';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.heic':
      return 'image/heic';
    case '.bmp':
      return 'image/bmp';
    default:
      return 'application/octet-stream';
  }
}

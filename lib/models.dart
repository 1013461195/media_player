enum VideoGestureMode { none, seek, brightness, volume }

enum ServerKind { smb, emby }

enum ServerCategory { fileService, mediaServer }

extension ServerKindMetadata on ServerKind {
  ServerCategory get category => switch (this) {
    ServerKind.smb => ServerCategory.fileService,
    ServerKind.emby => ServerCategory.mediaServer,
  };

  String get protocolLabel => switch (this) {
    ServerKind.smb => 'SMB',
    ServerKind.emby => 'Emby',
  };
}

extension ServerCategoryMetadata on ServerCategory {
  String get label => switch (this) {
    ServerCategory.fileService => '文件服务',
    ServerCategory.mediaServer => '媒体服务器',
  };
}

enum FileListViewMode { list, detail, largeGrid, mediumGrid }

enum EmbyLibraryView { programs, genres, folders }

class ServerConfig {
  const ServerConfig({
    required this.id,
    required this.kind,
    required this.name,
    required this.host,
    required this.domain,
    required this.username,
    required this.password,
    required this.accessToken,
    required this.userId,
  });

  final String id;
  final ServerKind kind;
  final String name;
  final String host;
  final String domain;
  final String username;
  final String password;
  final String accessToken;
  final String userId;

  String get displayName => name.trim().isEmpty ? host : name;
  ServerCategory get category => kind.category;

  ServerConfig copyWith({
    String? id,
    ServerKind? kind,
    String? name,
    String? host,
    String? domain,
    String? username,
    String? password,
    String? accessToken,
    String? userId,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      name: name ?? this.name,
      host: host ?? this.host,
      domain: domain ?? this.domain,
      username: username ?? this.username,
      password: password ?? this.password,
      accessToken: accessToken ?? this.accessToken,
      userId: userId ?? this.userId,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'host': host,
    'domain': domain,
    'username': username,
    'password': password,
    'accessToken': accessToken,
    'userId': userId,
  };

  static ServerConfig fromJson(Map<String, Object?> json) {
    return ServerConfig(
      id: json['id'] as String? ?? '',
      kind: ServerKind.values.firstWhere(
        (kind) => kind.name == (json['kind'] as String? ?? 'smb'),
        orElse: () => ServerKind.smb,
      ),
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
    );
  }
}

class EmbyItem {
  const EmbyItem({
    required this.id,
    required this.name,
    required this.type,
    required this.overview,
    this.communityRating,
    this.productionYear,
    this.runTimeTicks,
    this.officialRating = '',
    this.path = '',
    this.seriesName = '',
    this.indexNumber,
    this.parentIndexNumber,
    this.genres = const [],
    this.people = const [],
    this.mediaSources = const [],
    this.isFavorite = false,
  });

  final String id;
  final String name;
  final String type;
  final String overview;
  final double? communityRating;
  final int? productionYear;
  final int? runTimeTicks;
  final String officialRating;
  final String path;
  final String seriesName;
  final int? indexNumber;
  final int? parentIndexNumber;
  final List<String> genres;
  final List<EmbyPerson> people;
  final List<EmbyMediaSource> mediaSources;
  final bool isFavorite;

  bool get playable => const {'Movie', 'Episode', 'Video'}.contains(type);
  bool get isSeries => type == 'Series';
  bool get isMovie => type == 'Movie';
  bool get isEpisode => type == 'Episode';

  Duration? get runtime =>
      runTimeTicks == null ? null : Duration(microseconds: runTimeTicks! ~/ 10);
}

class EmbyPerson {
  const EmbyPerson({
    required this.id,
    required this.name,
    required this.role,
    required this.type,
  });

  final String id;
  final String name;
  final String role;
  final String type;
}

class EmbyMediaSource {
  const EmbyMediaSource({
    required this.path,
    required this.size,
    required this.container,
    required this.streams,
  });

  final String path;
  final int? size;
  final String container;
  final List<EmbyMediaStream> streams;
}

class EmbyMediaStream {
  const EmbyMediaStream({
    required this.type,
    required this.codec,
    required this.displayTitle,
    required this.language,
    required this.width,
    required this.height,
    required this.channels,
    required this.channelLayout,
    required this.bitRate,
    required this.sampleRate,
    required this.profile,
    required this.videoRange,
  });

  final String type;
  final String codec;
  final String displayTitle;
  final String language;
  final int? width;
  final int? height;
  final int? channels;
  final String channelLayout;
  final int? bitRate;
  final int? sampleRate;
  final String profile;
  final String videoRange;
}

class EmbyException implements Exception {
  const EmbyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DirectoryLoadException implements Exception {
  const DirectoryLoadException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

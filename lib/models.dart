enum VideoGestureMode { none, seek, brightness, volume }

enum ServerKind { smb, emby }

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
  });

  final String id;
  final String name;
  final String type;
  final String overview;

  bool get playable => const {'Movie', 'Episode', 'Video'}.contains(type);
  bool get isSeries => type == 'Series';
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

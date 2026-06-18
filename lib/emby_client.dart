import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

class EmbyVideoQuality {
  const EmbyVideoQuality(this.label, this.height, this.bitrate);
  final String label;
  final int? height;
  final int? bitrate;

  static const original = EmbyVideoQuality('原始画质', null, null);

  static const List<EmbyVideoQuality> presets = [
    EmbyVideoQuality('2160p - 120Mbps', 2160, 120000000),
    EmbyVideoQuality('2160p - 80Mbps', 2160, 80000000),
    EmbyVideoQuality('2160p - 60Mbps', 2160, 60000000),
    EmbyVideoQuality('2160p - 40Mbps', 2160, 40000000),
    EmbyVideoQuality('1080p - 10Mbps', 1080, 10000000),
    EmbyVideoQuality('1080p - 8Mbps', 1080, 8000000),
    EmbyVideoQuality('1080p - 6Mbps', 1080, 6000000),
    EmbyVideoQuality('1080p - 4Mbps', 1080, 4000000),
    EmbyVideoQuality('720p - 4Mbps', 720, 4000000),
    EmbyVideoQuality('720p - 3Mbps', 720, 3000000),
    EmbyVideoQuality('720p - 2Mbps', 720, 2000000),
    EmbyVideoQuality('720p - 1.5Mbps', 720, 1500000),
    EmbyVideoQuality('480p - 1.5Mbps', 480, 1500000),
    EmbyVideoQuality('480p - 720kbps', 480, 720000),
    EmbyVideoQuality('320p - 600kbps', 320, 600000),
    EmbyVideoQuality('240p - 400kbps', 240, 400000),
    EmbyVideoQuality('240p - 200kbps', 240, 200000),
    EmbyVideoQuality('144p - 200kbps', 144, 200000),
  ];

  static List<EmbyVideoQuality> get all => [original, ...presets];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmbyVideoQuality &&
          height == other.height &&
          bitrate == other.bitrate;

  @override
  int get hashCode => height.hashCode ^ bitrate.hashCode;
}

class HdrDetector {
  static const _channel = MethodChannel('com.huangjx.media_play/hdr');

  static Future<bool> isDolbyVisionSupported() async {
    try {
      if (!Platform.isAndroid) return true;
      final result = await _channel.invokeMethod<bool>(
        'checkDolbyVisionSupport',
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> isHdrSupported() async {
    try {
      if (!Platform.isAndroid) return true;
      final result = await _channel.invokeMethod<bool>('checkHdrSupport');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}

class EmbyClient {
  EmbyClient(this.config);

  static const _detailFields =
      'PrimaryImageAspectRatio,MediaSources,MediaStreams,Overview,'
      'DateCreated,Genres,People,Path,OfficialRating,CommunityRating,'
      'ProductionYear,RunTimeTicks,SeriesName,IndexNumber,ParentIndexNumber,'
      'UserData';

  final ServerConfig config;
  final HttpClient _httpClient = HttpClient();

  Uri get _baseUri {
    final raw = config.host.trim();
    return Uri.parse(raw.startsWith('http') ? raw : 'http://$raw');
  }

  Future<EmbyClient> authenticate() async {
    if (config.accessToken.isNotEmpty && config.userId.isNotEmpty) {
      debugPrint('[Emby] 使用缓存的令牌认证，跳过登录');
      return this;
    }
    final username = config.username.trim();
    if (username.isEmpty) {
      throw const EmbyException('用户名不能为空');
    }
    debugPrint('[Emby] 开始认证: host=${config.host}, username=$username');
    final response = await _requestJson(
      'POST',
      '/Users/AuthenticateByName',
      body: {'Username': username, 'Pw': config.password},
      includeToken: false,
    );
    final user = response['User'] as Map<String, dynamic>? ?? {};
    final token = response['AccessToken'] as String? ?? '';
    final userId = user['Id'] as String? ?? '';
    if (token.isEmpty || userId.isEmpty) {
      throw const EmbyException('Emby 登录成功但没有返回用户令牌');
    }
    debugPrint('[Emby] 认证成功: userId=$userId');
    return EmbyClient(config.copyWith(accessToken: token, userId: userId));
  }

  Future<List<EmbyItem>> latest() async {
    _assertAuthenticated();
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items/Latest',
      query: {'Limit': '20', 'Fields': _detailFields},
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> libraries() async {
    _assertAuthenticated();
    final data = await _requestJson('GET', '/Users/${config.userId}/Views');
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> favorites() async {
    _assertAuthenticated();
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items',
      query: {
        'Recursive': 'true',
        'Filters': 'IsFavorite',
        'IncludeItemTypes': 'Movie,Series,Episode,Video',
        'Fields': _detailFields,
        'SortBy': 'SortName',
      },
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> search(String term) async {
    _assertAuthenticated();
    final query = term.trim();
    if (query.isEmpty) return const [];
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items',
      query: {
        'SearchTerm': query,
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series,Video',
        'Fields': _detailFields,
        'SortBy': 'SortName',
        'Limit': '100',
      },
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<void> setFavorite(EmbyItem item, bool favorite) async {
    _assertAuthenticated();
    await _requestJson(
      favorite ? 'POST' : 'DELETE',
      '/Users/${config.userId}/FavoriteItems/${item.id}',
    );
  }

  void _assertAuthenticated() {
    if (config.accessToken.isEmpty || config.userId.isEmpty) {
      throw const EmbyException('Emby 未登录，请先连接服务器');
    }
  }

  Future<List<EmbyItem>> libraryItems(
    EmbyItem library,
    EmbyLibraryView view,
  ) async {
    _assertAuthenticated();
    if (view == EmbyLibraryView.genres) {
      final data = await _requestJson(
        'GET',
        '/Genres',
        query: {
          'UserId': config.userId,
          'ParentId': library.id,
          'SortBy': 'SortName',
        },
      );
      final list = data['Items'] as List<dynamic>? ?? [];
      return list.map(_itemFromJson).toList();
    }
    final query = {
      'ParentId': library.id,
      'Fields': _detailFields,
      'SortBy': 'SortName',
    };
    if (view == EmbyLibraryView.programs) {
      query.addAll({'Recursive': 'true', 'IncludeItemTypes': 'Movie,Series'});
    } else {
      query.addAll({'Recursive': 'false'});
    }
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items',
      query: query,
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> children(
    EmbyItem parent, {
    bool recursive = false,
  }) async {
    _assertAuthenticated();
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items',
      query: {
        'ParentId': parent.id,
        'Recursive': recursive ? 'true' : 'false',
        'Fields': _detailFields,
        'SortBy': 'SortName',
      },
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> seriesEpisodes(EmbyItem series) async {
    _assertAuthenticated();
    final data = await _requestJson(
      'GET',
      '/Shows/${series.id}/Episodes',
      query: {
        'UserId': config.userId,
        'Fields': _detailFields,
        'SortBy': 'SortName',
      },
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<EmbyItem> itemDetails(EmbyItem item) async {
    _assertAuthenticated();
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items/${item.id}',
      query: {'Fields': _detailFields},
    );
    return _itemFromJson(data);
  }

  Future<List<EmbyItem>> seriesSeasons(EmbyItem series) async {
    _assertAuthenticated();
    final data = await _requestJson(
      'GET',
      '/Shows/${series.id}/Seasons',
      query: {
        'UserId': config.userId,
        'Fields': _detailFields,
        'SortBy': 'SortName',
      },
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> seasonEpisodes(
    EmbyItem series,
    EmbyItem season,
  ) async {
    _assertAuthenticated();
    final data = await _requestJson(
      'GET',
      '/Shows/${series.id}/Episodes',
      query: {
        'UserId': config.userId,
        'SeasonId': season.id,
        'Fields': _detailFields,
        'SortBy': 'IndexNumber',
      },
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Uri imageUri(EmbyItem item, {int maxHeight = 420}) {
    return _buildUri(
      '/Items/${item.id}/Images/Primary',
      query: {
        'maxHeight': '$maxHeight',
        'quality': '82',
        'api_key': config.accessToken,
      },
    );
  }

  Uri backdropUri(EmbyItem item, {int maxWidth = 1400}) {
    return _buildUri(
      '/Items/${item.id}/Images/Backdrop/0',
      query: {
        'maxWidth': '$maxWidth',
        'quality': '88',
        'api_key': config.accessToken,
      },
    );
  }

  Uri personImageUri(EmbyPerson person, {int maxHeight = 240}) {
    return _buildUri(
      '/Persons/${person.id}/Images/Primary',
      query: {
        'maxHeight': '$maxHeight',
        'quality': '82',
        'api_key': config.accessToken,
      },
    );
  }

  Uri streamUri(
    EmbyItem item, {
    int? maxHeight,
    int? maxBitrate,
    String? playSessionId,
  }) {
    final needsTranscode = maxHeight != null || maxBitrate != null;
    final query = <String, String>{
      'api_key': config.accessToken,
      'DeviceId': 'media-player-flutter',
    };
    if (playSessionId != null) {
      query['PlaySessionId'] = playSessionId;
    }
    if (needsTranscode) {
      // Transcode to lower quality HLS stream
      query['Container'] = 'ts';
      query['VideoCodec'] = 'h264';
      query['AudioCodec'] = 'aac';
      query['Static'] = 'false';
      query['MaxHeight'] = '$maxHeight';
      query['VideoBitRate'] = '$maxBitrate';
      query['TranscodeReasons'] = 'ContainerBitrateExceedsLimit';
      return _buildUri('/Videos/${item.id}/master.m3u8', query: query);
    }
    // Direct play — no transcoding, serve original file directly
    query['Static'] = 'true';
    query['Container'] = _detectContainer(item);
    return _buildUri('/Videos/${item.id}/stream.${query['Container']}', query: query);
  }

  /// Detect the original container from the media source path.
  String _detectContainer(EmbyItem item) {
    if (item.mediaSources.isNotEmpty) {
      final path = item.mediaSources.first.path;
      if (path.contains('.')) {
        return path.split('.').last.toLowerCase();
      }
      final container = item.mediaSources.first.container;
      if (container.isNotEmpty) return container;
    }
    if (item.path.contains('.')) {
      return item.path.split('.').last.toLowerCase();
    }
    return 'mp4';
  }

  Future<void> reportPlaybackStart(
    EmbyItem item, {
    String? playSessionId,
    String playMethod = 'DirectPlay',
  }) async {
    _assertAuthenticated();
    await _requestJson(
      'POST',
      '/Sessions/Playing',
      body: {
        'ItemId': item.id,
        'PlayMethod': playMethod,
        'PlaySessionId': playSessionId ?? item.id,
      },
    );
  }

  Future<void> reportPlaybackProgress(
    EmbyItem item, {
    required int positionTicks,
    required bool isPaused,
    String? playSessionId,
    String playMethod = 'DirectPlay',
  }) async {
    _assertAuthenticated();
    await _requestJson(
      'POST',
      '/Sessions/Playing/Progress',
      body: {
        'ItemId': item.id,
        'PlayMethod': playMethod,
        'PlaySessionId': playSessionId ?? item.id,
        'PositionTicks': positionTicks,
        'IsPaused': isPaused,
      },
    );
  }

  Future<void> reportPlaybackStopped(
    EmbyItem item, {
    required int positionTicks,
    String? playSessionId,
  }) async {
    _assertAuthenticated();
    await _requestJson(
      'POST',
      '/Sessions/Playing/Stopped',
      body: {
        'ItemId': item.id,
        'PlaySessionId': playSessionId ?? item.id,
        'PositionTicks': positionTicks,
      },
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    bool includeToken = true,
  }) async {
    final uri = _buildUri(path, query: query);
    debugPrint('┌─── Emby Request ───────────────────────────────');
    debugPrint('│ $method $uri');
    debugPrint('│ Headers:');
    debugPrint('│   Content-Type: application/json');
    debugPrint('│   Accept: application/json');
    debugPrint('│   X-Emby-Client: Media Player');
    debugPrint('│   X-Emby-Client-Version: 0.1.0');
    debugPrint('│   X-Emby-Device-Id: media-player-flutter');
    debugPrint('│   X-Emby-Device-Name: Media Player');
    debugPrint(
      '│   X-Emby-Authorization: MediaBrowser Client="Media Player", Device="Flutter", DeviceId="media-player-flutter", DeviceName="Media Player", Version="0.1.0"',
    );
    if (includeToken && config.accessToken.isNotEmpty) {
      debugPrint('│   X-Emby-Token: ${config.accessToken}');
    }
    if (body != null) {
      debugPrint('│ Body:');
      debugPrint('│   ${jsonEncode(body)}');
    }
    debugPrint('└───────────────────────────────────────────────');

    final request = await _httpClient.openUrl(method, uri);
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set('X-Emby-Client', 'Media Player')
      ..set('X-Emby-Client-Version', '0.1.0')
      ..set('X-Emby-Device-Id', 'media-player-flutter')
      ..set('X-Emby-Device-Name', 'Media Player')
      ..set(
        'X-Emby-Authorization',
        'MediaBrowser Client="Media Player", Device="Flutter", DeviceId="media-player-flutter", DeviceName="Media Player", Version="0.1.0"',
      );
    if (includeToken && config.accessToken.isNotEmpty) {
      request.headers.set('X-Emby-Token', config.accessToken);
    }
    if (body != null) {
      final bodyBytes = utf8.encode(jsonEncode(body));
      request.headers.contentLength = bodyBytes.length;
      request.add(bodyBytes);
    } else {
      request.headers.contentLength = 0;
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();

    debugPrint('┌─── Emby Response ──────────────────────────────');
    debugPrint('│ Status: ${response.statusCode}');
    debugPrint('│ Headers:');
    response.headers.forEach((name, values) {
      debugPrint('│   $name: ${values.join(', ')}');
    });
    debugPrint('│ Body:');
    if (text.length > 1000) {
      debugPrint('│   ${text.substring(0, 1000)}...(truncated)');
    } else {
      debugPrint('│   $text');
    }
    debugPrint('└───────────────────────────────────────────────');

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String detail;
      try {
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          detail = (json['Message'] ?? json['message'] ?? text) as String;
        } else {
          detail = text;
        }
      } catch (_) {
        detail = text;
      }
      throw EmbyException('Emby 请求失败 (${response.statusCode}): $detail');
    }
    if (text.trim().isEmpty) {
      return {};
    }
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is List<dynamic>) {
      return {'Items': decoded};
    }
    return {};
  }

  Uri _buildUri(String path, {Map<String, String> query = const {}}) {
    final base = _baseUri;
    final normalizedPath =
        '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}$path';
    final allQuery = {...base.queryParameters, ...query};
    return base.replace(
      path: normalizedPath,
      queryParameters: allQuery.isEmpty ? null : allQuery,
    );
  }

  EmbyItem _itemFromJson(dynamic json) {
    final map = json as Map<String, dynamic>;
    final people = (map['People'] as List<dynamic>? ?? const [])
        .map((person) => person as Map<String, dynamic>)
        .map(
          (person) => EmbyPerson(
            id: person['Id'] as String? ?? '',
            name: person['Name'] as String? ?? '',
            role: person['Role'] as String? ?? '',
            type: person['Type'] as String? ?? '',
          ),
        )
        .toList();
    final mediaSources = (map['MediaSources'] as List<dynamic>? ?? const [])
        .map((source) => source as Map<String, dynamic>)
        .map(_mediaSourceFromJson)
        .toList();
    return EmbyItem(
      id: map['Id'] as String? ?? '',
      name: map['Name'] as String? ?? '',
      type: map['Type'] as String? ?? '',
      overview: map['Overview'] as String? ?? '',
      communityRating: (map['CommunityRating'] as num?)?.toDouble(),
      productionYear: (map['ProductionYear'] as num?)?.toInt(),
      runTimeTicks: (map['RunTimeTicks'] as num?)?.toInt(),
      officialRating: map['OfficialRating'] as String? ?? '',
      path: map['Path'] as String? ?? '',
      seriesName: map['SeriesName'] as String? ?? '',
      indexNumber: (map['IndexNumber'] as num?)?.toInt(),
      parentIndexNumber: (map['ParentIndexNumber'] as num?)?.toInt(),
      genres: (map['Genres'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      people: people,
      mediaSources: mediaSources,
      isFavorite:
          (map['UserData'] as Map<String, dynamic>?)?['IsFavorite'] as bool? ??
          false,
    );
  }

  EmbyMediaSource _mediaSourceFromJson(Map<String, dynamic> source) {
    final streams = (source['MediaStreams'] as List<dynamic>? ?? const [])
        .map((stream) => stream as Map<String, dynamic>)
        .map(
          (stream) => EmbyMediaStream(
            type: stream['Type'] as String? ?? '',
            codec: stream['Codec'] as String? ?? '',
            displayTitle: stream['DisplayTitle'] as String? ?? '',
            language: stream['Language'] as String? ?? '',
            width: (stream['Width'] as num?)?.toInt(),
            height: (stream['Height'] as num?)?.toInt(),
            channels: (stream['Channels'] as num?)?.toInt(),
            channelLayout: stream['ChannelLayout'] as String? ?? '',
            bitRate: (stream['BitRate'] as num?)?.toInt(),
            sampleRate: (stream['SampleRate'] as num?)?.toInt(),
            profile: stream['Profile'] as String? ?? '',
            videoRange: stream['VideoRange'] as String? ?? '',
          ),
        )
        .toList();
    return EmbyMediaSource(
      path: source['Path'] as String? ?? '',
      size: (source['Size'] as num?)?.toInt(),
      container: source['Container'] as String? ?? '',
      streams: streams,
    );
  }
}

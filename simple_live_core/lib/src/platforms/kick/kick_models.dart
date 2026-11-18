/// Kick 频道相关数据模型
///
/// 数据来源：`https://kick.com/api/v2/channels/{slug}`
/// Kick 的接口字段命名并不统一（同一份数据里既有 `profile_pic` 也有 `profilePic`），
/// 而且同一个字段的类型也会变（`followers_count` 有时是数字、有时是 `"4311"` 这种字符串），
/// 所以这里一律走宽松转换，字段缺失或类型异常都退回默认值，绝不抛异常。
class KickChannel {
  final int id;
  final String slug;
  final bool isBanned;
  final String playbackUrl;
  final int followersCount;
  final String? bannerImage;
  final KickLivestream? livestream;
  final KickUser? user;
  final int chatroomId;

  KickChannel({
    required this.id,
    required this.slug,
    required this.isBanned,
    required this.playbackUrl,
    required this.followersCount,
    this.bannerImage,
    this.livestream,
    this.user,
    required this.chatroomId,
  });

  factory KickChannel.fromJson(Map<String, dynamic> json) {
    final chatroom = json['chatroom'];
    return KickChannel(
      id: _asInt(json['id']),
      slug: _asString(json['slug']),
      isBanned: _asBool(json['is_banned']),
      playbackUrl: _asString(json['playback_url']),
      followersCount: _asInt(json['followers_count'] ?? json['followersCount']),
      bannerImage: _asStringOrNull(json['banner_image'] ?? json['bannerImage']),
      livestream: json['livestream'] is Map
          ? KickLivestream.fromJson(Map<String, dynamic>.from(json['livestream']))
          : null,
      user: json['user'] is Map
          ? KickUser.fromJson(Map<String, dynamic>.from(json['user']))
          : null,
      chatroomId: chatroom is Map ? _asInt(chatroom['id']) : 0,
    );
  }

  /// 是否正在直播
  bool get isLive => livestream?.isLive ?? false;
}

class KickLivestream {
  final int id;
  final String sessionTitle;
  final bool isLive;
  final int viewerCount;
  final bool isMature;
  final String? thumbnailUrl;
  final String? categoryName;

  KickLivestream({
    required this.id,
    required this.sessionTitle,
    required this.isLive,
    required this.viewerCount,
    required this.isMature,
    this.thumbnailUrl,
    this.categoryName,
  });

  factory KickLivestream.fromJson(Map<String, dynamic> json) {
    String? thumbnail;
    final thumb = json['thumbnail'];
    if (thumb is Map) {
      // 老接口是 {url: ...}，新接口有时直接给字符串
      thumbnail = _asStringOrNull(thumb['url']);
    } else {
      thumbnail = _asStringOrNull(thumb);
    }

    String? category;
    final categories = json['categories'];
    if (categories is List && categories.isNotEmpty) {
      final first = categories.first;
      if (first is Map) {
        category = _asStringOrNull(first['name']);
      }
    }

    return KickLivestream(
      id: _asInt(json['id']),
      sessionTitle: _asString(json['session_title'] ?? json['sessionTitle']),
      isLive: _asBool(json['is_live'] ?? json['isLive']),
      viewerCount: _asInt(json['viewer_count'] ?? json['viewerCount']),
      isMature: _asBool(json['is_mature'] ?? json['isMature']),
      thumbnailUrl: thumbnail,
      categoryName: category,
    );
  }
}

class KickUser {
  final int id;
  final String username;
  final String? profilePic;
  final String? bio;

  KickUser({
    required this.id,
    required this.username,
    this.profilePic,
    this.bio,
  });

  factory KickUser.fromJson(Map<String, dynamic> json) {
    // 频道接口用 profile_pic，搜索接口用 profilePic
    final pic = json['profile_pic'] ?? json['profilePic'];
    return KickUser(
      id: _asInt(json['id']),
      username: _asString(json['username'] ?? json['name'] ?? json['slug']),
      profilePic: _asStringOrNull(pic),
      bio: _asStringOrNull(json['bio']),
    );
  }
}

/// 搜索结果里的频道（字段与频道详情略有不同，例如用 isLive 而不是 livestream）
class KickSearchChannel {
  final int id;
  final String slug;
  final bool isBanned;
  final bool isLive;
  final int followersCount;
  final KickUser? user;

  KickSearchChannel({
    required this.id,
    required this.slug,
    required this.isBanned,
    required this.isLive,
    required this.followersCount,
    this.user,
  });

  factory KickSearchChannel.fromJson(Map<String, dynamic> json) {
    return KickSearchChannel(
      id: _asInt(json['id']),
      slug: _asString(json['slug']),
      isBanned: _asBool(json['is_banned'] ?? json['isBanned']),
      isLive: _asBool(json['isLive'] ?? json['is_live']),
      followersCount: _asInt(json['followers_count'] ?? json['followersCount']),
      user: json['user'] is Map
          ? KickUser.fromJson(Map<String, dynamic>.from(json['user']))
          : null,
    );
  }
}

/// 宽松转 int：兼容 `123`、`"123"`、`12.0`、`"1,234"`、`"1.2K"`、`true`
int _asInt(dynamic value, [int fallback = 0]) {
  if (value == null) {
    return fallback;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is bool) {
    return value ? 1 : 0;
  }
  var text = value.toString().replaceAll(",", "").trim();
  if (text.isEmpty) {
    return fallback;
  }
  var direct = int.tryParse(text);
  if (direct != null) {
    return direct;
  }
  var multiplier = 1;
  var last = text[text.length - 1].toUpperCase();
  if (last == "K" || last == "M" || last == "B") {
    multiplier = last == "K" ? 1000 : (last == "M" ? 1000000 : 1000000000);
    text = text.substring(0, text.length - 1).trim();
  }
  var parsed = num.tryParse(text);
  if (parsed == null) {
    return fallback;
  }
  return (parsed * multiplier).round();
}

/// 宽松转 bool：兼容 `true`、`1`、`"true"`、`"yes"`
bool _asBool(dynamic value, [bool fallback = false]) {
  if (value == null) {
    return fallback;
  }
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  var text = value.toString().trim().toLowerCase();
  if (text == "true" || text == "1" || text == "yes" || text == "y") {
    return true;
  }
  if (text == "false" || text == "0" || text == "no" || text == "n") {
    return false;
  }
  return fallback;
}

/// 宽松转 String：数字/其他类型统一成字符串，null 给空串
String _asString(dynamic value, [String fallback = ""]) {
  if (value == null) {
    return fallback;
  }
  if (value is String) {
    return value;
  }
  return value.toString();
}

/// 同上，但空串按 null 处理，方便可选字段
String? _asStringOrNull(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value.isEmpty ? null : value;
  }
  if (value is Map) {
    // 少数接口会把 url 包一层
    return _asStringOrNull(value["url"]);
  }
  var text = value.toString();
  return text.isEmpty ? null : text;
}

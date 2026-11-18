/// Kick 频道相关数据模型
///
/// 数据来源：`https://kick.com/api/v2/channels/{slug}`
/// Kick 的接口字段命名并不统一（同一份数据里既有 `profile_pic` 也有 `profilePic`），
/// 所以这里全部按「可能为空」处理，解析失败也不会抛异常。
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
      id: json['id'] ?? 0,
      slug: json['slug'] ?? '',
      isBanned: json['is_banned'] ?? false,
      playbackUrl: json['playback_url'] ?? '',
      followersCount: json['followers_count'] ?? 0,
      bannerImage: json['banner_image'] is String ? json['banner_image'] : null,
      livestream: json['livestream'] is Map
          ? KickLivestream.fromJson(Map<String, dynamic>.from(json['livestream']))
          : null,
      user: json['user'] is Map
          ? KickUser.fromJson(Map<String, dynamic>.from(json['user']))
          : null,
      chatroomId: chatroom is Map ? (chatroom['id'] ?? 0) : 0,
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
      thumbnail = thumb['url'] is String ? thumb['url'] : null;
    } else if (thumb is String) {
      thumbnail = thumb;
    }

    String? category;
    final categories = json['categories'];
    if (categories is List && categories.isNotEmpty) {
      final first = categories.first;
      if (first is Map && first['name'] is String) {
        category = first['name'];
      }
    }

    return KickLivestream(
      id: json['id'] ?? 0,
      sessionTitle: json['session_title'] ?? '',
      isLive: json['is_live'] ?? false,
      viewerCount: json['viewer_count'] ?? 0,
      isMature: json['is_mature'] ?? false,
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
      id: json['id'] ?? 0,
      username: json['username'] ?? '',
      profilePic: pic is String ? pic : null,
      bio: json['bio'] is String ? json['bio'] : null,
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
      id: json['id'] ?? 0,
      slug: json['slug'] ?? '',
      isBanned: json['is_banned'] ?? false,
      isLive: json['isLive'] ?? json['is_live'] ?? false,
      followersCount: json['followers_count'] ?? json['followersCount'] ?? 0,
      user: json['user'] is Map
          ? KickUser.fromJson(Map<String, dynamic>.from(json['user']))
          : null,
    );
  }
}

import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/model/account_info.dart';
import 'package:simple_live_core/src/model/account_qr_code.dart';
import 'package:simple_live_core/src/platforms/kick/kick_danmaku.dart';
import 'package:simple_live_core/src/platforms/kick/kick_models.dart';

/// Kick 直播解析
///
/// 走的是 Kick 网页端自己的公开接口：
/// * 频道信息：`GET https://kick.com/api/v2/channels/{slug}`
///   里面直接带 `playback_url`（AWS IVS 的 m3u8 主播放列表，带临时 token）和 `livestream` 直播数据。
/// * 搜索：`GET https://kick.com/api/search?searched_word={keyword}`
///
/// 注意：`playback_url` 里的 token 有效期只有 10 分钟左右，
/// 所以每次取清晰度、每次开始播放都会重新请求一次频道信息拿新链接。
class KickSite implements LiveSite {
  @override
  String id = 'kick';

  @override
  String name = 'Kick';

  static const defaultUa =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36";

  static const baseUrl = "https://kick.com";
  static const baseApiUrl = "https://kick.com/api/v2";

  /// 请求 Kick 接口用的头。Kick 前面有 Cloudflare，缺 UA / Referer 容易被拦。
  Map<String, String> headers = {
    'user-agent': defaultUa,
    'accept': 'application/json, text/plain, */*',
    'accept-language': 'en-US,en;q=0.9',
    'referer': baseUrl + "/",
    'origin': baseUrl,
  };

  /// 请求 m3u8 用的头
  Map<String, String> get streamHeaders => {
        'user-agent': defaultUa,
        'referer': baseUrl + "/",
        'origin': baseUrl,
      };

  @override
  LiveDanmaku getDanmaku() => KickDanmaku();

  /// 读取频道详情（原始数据）
  Future<KickChannel> getChannel(String slug) async {
    var response = await HttpClient.instance.getJson(
      "$baseApiUrl/channels/$slug",
      header: headers,
    );
    if (response is! Map) {
      throw Exception("Kick 频道数据解析失败：$slug");
    }
    return KickChannel.fromJson(Map<String, dynamic>.from(response));
  }

  /// 读取 m3u8 主播放列表，解析出所有清晰度
  Future<List<_KickVariant>> _getVariants(String playbackUrl) async {
    if (playbackUrl.isEmpty) return [];
    var content = await HttpClient.instance.getText(
      playbackUrl,
      header: streamHeaders,
    );
    return _parseMasterPlaylist(content);
  }

  List<_KickVariant> _parseMasterPlaylist(String content) {
    var lines = const LineSplitter().convert(content);
    var result = <String, _KickVariant>{};
    int? bandwidth;
    int? height;

    for (var line in lines) {
      var l = line.trim();
      if (l.startsWith("#EXT-X-STREAM-INF")) {
        var bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(l);
        var resMatch = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(l);
        bandwidth = bwMatch == null ? 0 : int.tryParse(bwMatch.group(1) ?? "") ?? 0;
        height = resMatch == null ? null : int.tryParse(resMatch.group(2) ?? "");
        continue;
      }
      if (l.isEmpty || l.startsWith("#")) continue;
      if (bandwidth == null) continue;
      // 这一行就是紧接着 #EXT-X-STREAM-INF 的播放地址
      var variant = _KickVariant(
        name: _qualityName(height, bandwidth),
        bandwidth: bandwidth,
        url: l,
      );
      // 同名清晰度只保留码率最高的那条
      var exist = result[variant.name];
      if (exist == null || exist.bandwidth < variant.bandwidth) {
        result[variant.name] = variant;
      }
      bandwidth = null;
      height = null;
    }

    var list = result.values.toList();
    list.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return list;
  }

  /// 清晰度名称：优先用分辨率高度，拿不到再按码率估算
  String _qualityName(int? height, int bandwidth) {
    if (height != null && height > 0) {
      return "${height}P";
    }
    if (bandwidth > 5000000) return "1080P";
    if (bandwidth > 2500000) return "720P";
    if (bandwidth > 1000000) return "480P";
    if (bandwidth > 500000) return "360P";
    return "自动";
  }

  @override
  Future<List<LiveCategory>> getCategories() {
    // Kick 没有公开的分类列表接口（/api/v2/categories 返回 404）
    return Future.value([]);
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) {
    return Future.value(LiveCategoryResult(hasMore: false, items: []));
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    // 推荐位未实现，返回空列表而不是抛异常，避免首页崩溃
    return Future.value(LiveCategoryResult(hasMore: false, items: []));
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var channel = await getChannel(roomId);
    return channel.isLive;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var channel = await getChannel(roomId);
    var livestream = channel.livestream;
    var isLive = livestream?.isLive ?? false;
    var userName = channel.user?.username ?? channel.slug;
    var avatar = channel.user?.profilePic ?? "";

    return LiveRoomDetail(
      roomId: channel.slug.isEmpty ? roomId : channel.slug,
      title: (livestream?.sessionTitle.isNotEmpty ?? false)
          ? livestream!.sessionTitle
          : userName,
      cover: livestream?.thumbnailUrl ?? channel.bannerImage ?? "",
      userName: userName,
      userAvatar: avatar,
      online: isLive ? (livestream?.viewerCount ?? 0) : 0,
      status: isLive,
      url: "$baseUrl/${channel.slug.isEmpty ? roomId : channel.slug}",
      introduction: channel.user?.bio ?? "",
      notice: "",
      danmakuData: channel.chatroomId,
      data: null,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualities(
      {required LiveRoomDetail detail}) async {
    var channel = await getChannel(detail.roomId);
    if (!channel.isLive || channel.playbackUrl.isEmpty) {
      return <LivePlayQuality>[];
    }
    var variants = await _getVariants(channel.playbackUrl);
    return variants
        .map((e) => LivePlayQuality(
              quality: e.name,
              data: {
                "name": e.name,
                "bandwidth": e.bandwidth,
                "url": e.url,
              },
              sort: e.bandwidth,
            ))
        .toList();
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var data = quality.data is Map
        ? Map<String, dynamic>.from(quality.data as Map)
        : <String, dynamic>{};
    var qualityName = data["name"]?.toString() ?? quality.quality;
    String? url = data["url"]?.toString();

    // playback_url 带的是 10 分钟有效期的 token，
    // 播放前重新拉一次，避免用到已经过期的地址
    try {
      var channel = await getChannel(detail.roomId);
      var variants = await _getVariants(channel.playbackUrl);
      if (variants.isNotEmpty) {
        var matched =
            variants.where((e) => e.name == qualityName).toList();
        url = matched.isNotEmpty ? matched.first.url : variants.first.url;
      }
    } catch (e) {
      CoreLog.w("kick 刷新播放地址失败，使用缓存的地址：$e");
    }

    if (url == null || url.isEmpty) {
      throw Exception("未获取到 Kick 播放地址，可能主播已下播");
    }

    return LivePlayUrl(
      urls: [url],
      headers: streamHeaders,
    );
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) {
    // Kick 没有对应的公开接口
    return Future.value([]);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    if (keyword.trim().isEmpty) {
      return LiveSearchAnchorResult(hasMore: false, items: <LiveAnchorItem>[]);
    }
    var response = await HttpClient.instance.getJson(
      "$baseUrl/api/search",
      queryParameters: {"searched_word": keyword.trim()},
      header: headers,
    );
    var items = <LiveAnchorItem>[];
    if (response is Map && response["channels"] is List) {
      for (var raw in response["channels"] as List) {
        if (raw is! Map) continue;
        var channel =
            KickSearchChannel.fromJson(Map<String, dynamic>.from(raw));
        if (channel.slug.isEmpty || channel.isBanned) continue;
        items.add(LiveAnchorItem(
          roomId: channel.slug,
          avatar: channel.user?.profilePic ?? "",
          userName: channel.user?.username ?? channel.slug,
          liveStatus: channel.isLive,
        ));
      }
    }
    return LiveSearchAnchorResult(hasMore: false, items: items);
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    // 搜索接口不返回直播间标题/封面/在线人数，做不了直播间卡片
    return Future.value(
        LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]));
  }

  @override
  void setSiteAttrs(String data) {
    // Kick 播放与弹幕都不需要 cookie / token
  }

  @override
  Future<AccountInfo> getAccountInfo({required String credential}) {
    throw UnimplementedError("kick暂不支持登录");
  }

  @override
  Future<QRCode> getQRCode() {
    throw UnimplementedError("kick暂不支持扫码登录");
  }

  @override
  Future<QRPollResult> getQRPollResult({required String qrcodeKey}) {
    throw UnimplementedError("kick暂不支持扫码登录");
  }
}

/// 一条 m3u8 清晰度（内部使用）
class _KickVariant {
  final String name;
  final int bandwidth;
  final String url;

  _KickVariant({
    required this.name,
    required this.bandwidth,
    required this.url,
  });
}

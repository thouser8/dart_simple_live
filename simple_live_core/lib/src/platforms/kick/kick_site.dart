import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
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
  ///
  /// 除了 UA，还要带上与 UA 自洽的 Client Hints（sec-ch-ua 系列）。
  /// Cloudflare 会把「UA 说自己是 Chrome，却不发 Client Hints」判为脚本流量直接 403。
  static Map<String, String> get headers => {
    'user-agent': defaultUa,
    'accept': 'application/json, text/plain, */*',
    'accept-language': 'en-US,en;q=0.9',
    'referer': baseUrl + "/",
    'origin': baseUrl,
    'sec-ch-ua':
        '"Google Chrome";v="137", "Chromium";v="137", "Not/A)Brand";v="24"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-origin',
    'priority': 'u=1, i',
  };

  /// 统一请求：非 2xx 时把服务端返回的正文塞进异常。
  ///
  /// 这里故意用 `statusCode: 0`，因为 `CoreError.toString()` 在 statusCode 不为 0 时
  /// 只会输出「无权限访问资源(403)」这种固定文案，会把诊断信息吞掉。
  static Future<dynamic> _request(
    String url, {
    required String method,
    Map<String, dynamic>? query,
    Map<String, String>? header,
    Object? data,
  }) async {
    Response<dynamic> resp;
    try {
      resp = await HttpClient.instance.dio.request(
        url,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          responseType: ResponseType.json,
          headers: Map<String, String>.from(header ?? headers),
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw CoreError("Kick 请求 $url 失败：${e.type.name} ${e.message}");
    }

    var code = resp.statusCode ?? 0;
    if (code >= 200 && code < 300) {
      return resp.data;
    }
    throw CoreError(
      "Kick 接口返回 $code：${_snippet(resp.data)}  ← $url",
    );
  }

  /// 把响应正文压成一行短文本，避免刷屏
  static String _snippet(dynamic data) {
    String text;
    if (data is String) {
      text = data;
    } else {
      try {
        text = jsonEncode(data);
      } catch (_) {
        text = data.toString();
      }
    }
    text = text.replaceAll(RegExp(r"\s+"), " ").trim();
    if (text.length > 400) {
      return "${text.substring(0, 400)}…";
    }
    return text;
  }

  /// 请求 m3u8 用的头
  Map<String, String> get streamHeaders => {
        'user-agent': defaultUa,
        'referer': baseUrl + "/",
        'origin': baseUrl,
      };

  /// 登录后的 cookie（session_token 等），未登录时为空
  String _cookie = "";

  /// 实时聊天服务所在的站点，和主站不是同一个域名
  static const realtimeBaseUrl = "https://web.kick.com/api/v1";

  @override
  LiveDanmaku getDanmaku() => KickDanmaku(cookie: _cookie);

  /// 带登录态的请求头，未登录时等于普通 headers
  Map<String, String> get _authHeaders {
    var token = pickCookie(_cookie, "session_token");
    return {
      ...headers,
      if (_cookie.isNotEmpty) 'cookie': _cookie,
      if (token.isNotEmpty) 'authorization': 'Bearer $token',
    };
  }

  /// 从 cookie 字符串里取某个字段
  static String pickCookie(String cookie, String name) {
    if (cookie.isEmpty) {
      return "";
    }
    for (var item in cookie.split(";")) {
      var kv = item.split("=");
      if (kv.length >= 2 && kv.first.trim() == name) {
        return kv.sublist(1).join("=").trim();
      }
    }
    return "";
  }

  /// 取频道聊天室当前使用的 Pusher 配置
  ///
  /// Kick 网页端先声明自己支持哪些实时厂商，服务端再下发对应的连接参数。
  /// 这里只要 pusher，就能拿到 `app_key` + `cluster`，用它连标准 Pusher 通道收弹幕。
  static Future<Map<String, dynamic>> getPusherConfig({
    required String chatroomId,
    String cookie = "",
  }) async {
    var response = await _request(
      "$realtimeBaseUrl/realtime/channels/$chatroomId/chat/connection",
      method: "POST",
      data: {
        "client": {
          "id": _clientId(),
          "type": "web",
        },
        "capabilities": {
          "accepted_providers": [
            {"provider": "pusher"}
          ]
        }
      },
      header: {
        ...headers,
        'content-type': 'application/json',
        'x-app-platform': 'web',
        'sec-fetch-site': 'same-site',
        if (cookie.isNotEmpty) 'cookie': cookie,
      },
    );

    if (response is! Map) {
      throw Exception("Kick 实时通道配置解析失败");
    }
    var connections = response["data"]?["connections"];
    if (connections is List && connections.isNotEmpty) {
      var first = connections.first;
      if (first is Map && first["credentials"] is Map) {
        return Map<String, dynamic>.from(first["credentials"]);
      }
    }
    throw Exception("Kick 未返回可用的实时通道");
  }

  /// 生成一个随机客户端 ID，服务端只要求形如 UUID，用来做连接标识
  static String _clientId() {
    var random = Random();
    String seg(int len) {
      var sb = StringBuffer();
      for (var i = 0; i < len; i++) {
        sb.write(random.nextInt(16).toRadixString(16));
      }
      return sb.toString();
    }

    return "${seg(8)}-${seg(4)}-4${seg(3)}-a${seg(3)}-${seg(12)}";
  }

  /// 读取频道详情（原始数据）
  Future<KickChannel> getChannel(String slug) async {
    dynamic response;
    try {
      response = await _request(
        "$baseApiUrl/channels/$slug",
        method: "GET",
        header: headers,
      );
    } on CoreError catch (e) {
      // 403 时换主域再试一次：Kick 对裸域和 www 的 Cloudflare 规则偶尔不一致
      if (e.message.contains("返回 403") || e.message.contains("返回 1020")) {
        CoreLog.w("kick 裸域被拦，改用 www.kick.com 重试");
        response = await _request(
          "https://www.kick.com/api/v2/channels/$slug",
          method: "GET",
          header: headers,
        );
      } else {
        rethrow;
      }
    }
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
      danmakuData: channel.chatroomId > 0 ? channel.chatroomId : null,
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
    var response = await _request(
      "$baseUrl/api/search",
      method: "GET",
      query: {"searched_word": keyword.trim()},
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
    if (data.trim().isEmpty) {
      return;
    }
    try {
      var map = jsonDecode(data);
      if (map is Map && map['cookie'] is String) {
        _cookie = (map['cookie'] as String).trim();
      }
    } catch (_) {
      // credential 不是合法 json 时按未登录处理
    }
  }

  /// 校验登录态并读取账号资料
  ///
  /// credential 形如 `{"cookie":"session_token=xxx; ..."}`。
  /// Kick 网页端把 `session_token` 放在 cookie 里，同时也会把它当 Bearer token 发，
  /// 这里两种都带上；用 `/api/v2/channels/followed` 判断登录是否有效
  /// （未登录固定返回 401，有效登录返回 200）。
  @override
  Future<AccountInfo> getAccountInfo({required String credential}) async {
    var info = AccountInfo();
    Map<String, dynamic> map;
    try {
      var decoded = jsonDecode(credential);
      if (decoded is! Map) return info;
      map = Map<String, dynamic>.from(decoded);
    } catch (e) {
      return info;
    }
    var cookie = (map['cookie'] ?? '').toString().trim();
    if (cookie.isEmpty) {
      return info;
    }
    setSiteAttrs(credential);

    // 先看关注列表能不能拿到：未登录固定 401，登录后 200
    var valid = false;
    try {
      await HttpClient.instance.getJson(
        "$baseApiUrl/channels/followed",
        queryParameters: {"page": 1, "limit": 1},
        header: _authHeaders,
      );
      valid = true;
    } catch (e) {
      CoreLog.w("kick 关注列表校验失败：$e");
    }

    String? name;
    String? avatar;
    String? uid;
    try {
      var user = await HttpClient.instance.getJson(
        "$baseUrl/api/v1/user",
        header: _authHeaders,
      );
      var node = user;
      if (node is Map && node['data'] is Map) {
        node = node['data'];
      }
      if (node is Map && node['user'] is Map) {
        node = node['user'];
      }
      if (node is Map) {
        name = (node['username'] ?? node['name'] ?? node['slug'])?.toString();
        avatar = (node['profile_pic'] ?? node['profile_pic_url'] ?? node['avatar'])
            ?.toString();
        uid = (node['id'] ?? node['uuid'])?.toString();
      }
    } catch (e) {
      CoreLog.w("kick 读取账号资料失败：$e");
    }

    // 关注列表接口万一被限流/改动，能读到用户资料也说明登录态可用
    if (!valid && (name != null && name.isNotEmpty)) {
      valid = true;
    }
    if (!valid) {
      return info;
    }

    return AccountInfo(
      name: (name == null || name.isEmpty) ? null : name,
      avatar: (avatar == null || avatar.isEmpty) ? null : avatar,
      uid: (uid == null || uid.isEmpty) ? null : uid,
      credential: credential,
      isValid: valid,
    );
  }

  /// Kick 没有扫码登录（网页端只提供邮箱密码 + 第三方 OAuth），
  /// 所以这里不做二维码，App 侧走「网页登录 + 自动取 cookie」。
  @override
  Future<QRCode> getQRCode() async {
    return QRCode(key: "", url: "");
  }

  @override
  Future<QRPollResult> getQRPollResult({required String qrcodeKey}) async {
    return QRPollResult(status: QRStatus.failed, message: "Kick 不支持扫码登录");
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

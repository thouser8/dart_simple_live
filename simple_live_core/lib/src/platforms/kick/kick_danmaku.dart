import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/platforms/kick/kick_site.dart';

/// Kick 弹幕
///
/// Kick 网页端现在把实时聊天收口到一个统一入口：
///
/// `POST https://web.kick.com/api/v1/realtime/channels/{chatroomId}/chat/connection`
///
/// 请求体里声明「客户端支持哪些实时厂商」，服务端返回该频道正在用的通道配置。
/// 只要声明 `pusher`，就能拿到 `app_key` / `cluster`，之后就是标准 Pusher 协议：
///
/// * 连接 `wss://ws-{cluster}.pusher.com/app/{app_key}?protocol=7&client=js&version=8.4.0&flash=false`
/// * 订阅 `chatrooms.{chatroomId}.v2`
/// * 监听 `App\Events\ChatMessageEvent`
///
/// 全过程匿名可用，不需要登录。
/// （网上流传的固定 key `32cbd69e4b950bf97679` 已经作废，会返回 4001 App key not in this cluster，
/// 所以这里的 key 必须每次从上面那个接口现取。）
class KickDanmaku implements LiveDanmaku {
  KickDanmaku({this.chatroomId = "", this.cookie = ""});

  /// 聊天室 ID（注意不是频道 ID，也不是 slug）
  String chatroomId;

  /// 登录后的 cookie，可选。匿名也能看弹幕，带上只是让身份更完整
  String cookie;

  WebScoketUtils? _ws;

  /// Pusher 的 activity_timeout 是 120s，40s 发一次心跳足够
  @override
  int heartbeatTime = 40 * 1000;

  @override
  Function(String msg)? onClose;

  @override
  Function(LiveMessage msg)? onMessage;

  @override
  Function()? onReady;

  @override
  void heartbeat() {
    _ws?.sendMessage(jsonEncode({"event": "pusher:ping", "data": {}}));
  }

  @override
  Future start(args) async {
    if (args is Map) {
      chatroomId =
          (args['chatroomId'] ?? args['chatroom_id'] ?? chatroomId).toString();
      cookie = (args['cookie'] ?? cookie).toString();
    } else if (args != null) {
      chatroomId = args.toString();
    }
    if (chatroomId.isEmpty) {
      onClose?.call("Kick 弹幕缺少聊天室 ID");
      return;
    }

    try {
      var config = await KickSite.getPusherConfig(
        chatroomId: chatroomId,
        cookie: cookie,
      );
      var appKey = config["app_key"]?.toString() ?? "";
      var cluster = config["cluster"]?.toString() ?? "";
      if (appKey.isEmpty) {
        throw Exception("Kick 未返回实时通道配置");
      }
      _connect(appKey, cluster.isEmpty ? "us2" : cluster);
    } catch (e) {
      onClose?.call("Kick 弹幕连接失败：$e");
    }
  }

  void _connect(String appKey, String cluster) {
    var url =
        "wss://ws-$cluster.pusher.com/app/$appKey?protocol=7&client=js&version=8.4.0&flash=false";
    _ws = WebScoketUtils(
      url: url,
      heartBeatTime: heartbeatTime,
      onReady: () {
        // 每次（重）连上都要重新订阅
        _subscribe();
      },
      onMessage: _onMessage,
      onHeartBeat: heartbeat,
      onClose: (msg) {
        onClose?.call(msg);
      },
    );
    _ws?.connect();
  }

  void _subscribe() {
    if (chatroomId.isEmpty) {
      return;
    }
    _ws?.sendMessage(jsonEncode({
      "event": "pusher:subscribe",
      "data": {
        "auth": "",
        "channel": "chatrooms.$chatroomId.v2",
      },
    }));
  }

  void _onMessage(dynamic raw) {
    String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw, allowMalformed: true);
    } else {
      return;
    }

    Map<String, dynamic> data;
    try {
      var decoded = jsonDecode(text);
      if (decoded is! Map) return;
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    var event = data["event"]?.toString() ?? "";

    // Pusher 协议自带的消息
    if (event == "pusher:ping") {
      _ws?.sendMessage(jsonEncode({"event": "pusher:pong", "data": {}}));
      return;
    }
    if (event == "pusher_internal:subscription_succeeded") {
      onReady?.call();
      return;
    }
    if (event == "pusher:error") {
      var msg = data["data"];
      if (msg is Map && msg["message"] is String) {
        onClose?.call(msg["message"]);
      }
      return;
    }
    if (event != "App\\Events\\ChatMessageEvent") {
      return;
    }

    var body = data["data"];
    if (body is String) {
      try {
        body = jsonDecode(body);
      } catch (_) {
        return;
      }
    }
    if (body is! Map) {
      return;
    }

    var type = body["type"]?.toString() ?? "message";
    // message = 普通弹幕，reply = 回复某条弹幕
    if (type != "message" && type != "reply") {
      return;
    }

    var sender = body["sender"];
    var userName = "";
    var userId = "";
    var color = LiveMessageColor.white;
    if (sender is Map) {
      userName =
          sender["username"]?.toString() ?? sender["slug"]?.toString() ?? "";
      userId = sender["id"]?.toString() ?? "";
      var identity = sender["identity"];
      if (identity is Map) {
        color = _parseColor(identity["color"]?.toString() ?? "");
      }
    }

    var content = _stripEmotes(body["content"]?.toString() ?? "");
    if (content.isEmpty) {
      return;
    }

    onMessage?.call(LiveMessage(
      type: LiveMessageType.chat,
      userName: userName,
      userId: userId,
      message: content,
      color: color,
    ));
  }

  /// Kick 的身份颜色是 `#RRGGBB` 形式，转成本项目通用的颜色对象
  LiveMessageColor _parseColor(String value) {
    var hex = value.replaceAll("#", "").trim();
    if (hex.length != 6 && hex.length != 8) {
      return LiveMessageColor.white;
    }
    var color = int.tryParse(hex, radix: 16);
    if (color == null) {
      return LiveMessageColor.white;
    }
    return LiveMessageColor.numberToColor(color);
  }

  /// 表情在正文里是 `[emote:4147914:duckPls]` 这种占位符。
  /// 本项目没有 Kick 的表情图片表，这里退化成表情名，避免把占位符原样显示出来。
  String _stripEmotes(String content) {
    return content.replaceAllMapped(
      RegExp(r'\[emote:\d+:([^\]]+)\]'),
      (m) => m.group(1) ?? "",
    );
  }

  @override
  Future stop() async {
    _ws?.close();
    _ws = null;
    onMessage = null;
    onClose = null;
    onReady = null;
  }
}

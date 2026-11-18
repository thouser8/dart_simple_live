import 'package:simple_live_core/simple_live_core.dart';

/// Kick 弹幕（暂未实现）
///
/// 现状：Kick 在 2025 年底之后把公开的 Pusher 弹幕通道换成了自己的实时服务，
/// 抓包/复现结论如下（留给后续接手的人）：
///
/// 1. 先领一张一次性令牌：
///    `GET https://websockets.kick.com/viewer/v1/token`
///    必须带请求头 `X-CLIENT-TOKEN: e1393935a959b4020a4491574f6490129f678acdaa92760471263db43487f823`
///    （这个值是 Kick 网页端打包在 JS 里的固定客户端 token，会随前端发版变化）
///    返回 `{"data":{"token":"..."}}`，令牌一次性、有效时间很短。
/// 2. 用它连 `wss://websockets.kick.com/viewer/v1/connect?token=xxx`
///    连接能建立，但服务端不会主动打招呼，也不回应 Pusher 式 `pusher:subscribe`
///    和 Centrifugo 式 `{"id":1,"connect":{}}`，说明握手帧格式是 Kick 私有的。
/// 3. 旧的 `wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679` 已经失效，
///    现在连上去会返回 `4001 App key not in this cluster`。
/// 4. 老接口 `https://kick.com/api/v2/channels/{slug}/messages` 返回 401 Unauthenticated，
///    聊天记录也需要登录态。
///
/// 所以想真正拿到 Kick 弹幕，需要补一步「Kick 账号登录（拿 session cookie 或 OAuth token）」，
/// 属于账号体系的工作，不是纯解析能解决的 —— 这部分没做，弹幕列表会是空的，播放不受影响。
class KickDanmaku implements LiveDanmaku {
  @override
  Function(String msg)? onClose;

  @override
  Function(LiveMessage msg)? onMessage;

  @override
  Function()? onReady;

  @override
  int heartbeatTime = 30 * 1000;

  @override
  void heartbeat() {}

  @override
  Future start(args) async {
    CoreLog.w("Kick 弹幕暂不支持：官方实时通道需要登录态，当前仅支持播放");
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    onReady = null;
  }
}

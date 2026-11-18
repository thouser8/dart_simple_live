import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 用系统 WebView 里真实的 Chromium 内核去请求 Kick 接口。
///
/// 背景：Kick 的边缘节点会校验 TLS / HTTP2 指纹，Dart 自带的 HttpClient
/// 无论怎么伪装请求头都会拿到
/// `{"error":"Request blocked by security policy.","reference":"..."}`（403）。
/// 而 WebView 的握手特征就是浏览器本身，等同于用户手动打开，
/// 顺带还能复用 WebView 里已有的登录 cookie。
///
/// 做法：在隐藏的 WebView 里先打开一个 kick.com 同源的小页面拿到 origin，
/// 再用页面内的 fetch() 发请求（同源，不受 CORS 限制），
/// 结果写进 window 变量后由 Dart 轮询取出。
class KickWebFetcher {
  KickWebFetcher._();

  static final KickWebFetcher instance = KickWebFetcher._();

  static bool _registered = false;

  /// 把抓取器注册到 core，App 启动时调一次
  static void register() {
    if (_registered) {
      return;
    }
    _registered = true;
    KickSite.webFetch = ({
      required String url,
      required String method,
      required Map<String, String> headers,
      String? body,
    }) =>
        instance.fetch(
          url: url,
          method: method,
          headers: headers,
          body: body,
        );
  }

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  Completer<void>? _pageReady;

  /// 串行锁：同一时刻只跑一个请求，避免 window 变量相互覆盖
  Future<void> _lock = Future.value();

  /// 发起一次请求，成功返回响应正文，失败返回 null
  Future<String?> fetch({
    required String url,
    required String method,
    required Map<String, String> headers,
    String? body,
  }) async {
    var previous = _lock;
    var gate = Completer<void>();
    _lock = gate.future;
    try {
      await previous;
    } catch (_) {
      // 上一个请求失败不影响本次
    }
    try {
      return await _doFetch(
        url: url,
        method: method,
        headers: headers,
        body: body,
      );
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  Future<String?> _doFetch({
    required String url,
    required String method,
    required Map<String, String> headers,
    String? body,
  }) async {
    // 失败后重建一次 WebView 再试，覆盖「页面被系统回收」的情况
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _ensurePage();
        var controller = _controller;
        if (controller == null) {
          throw StateError("WebView 未就绪");
        }
        var result = await _runFetch(
          controller,
          url: url,
          method: method,
          headers: headers,
          body: body,
        );
        if (result != null) {
          return result;
        }
        return null;
      } catch (e) {
        Log.w("Kick WebView 请求失败(${attempt + 1}/2)：$e");
        await _dispose();
      }
    }
    return null;
  }

  Future<String?> _runFetch(
    InAppWebViewController controller, {
    required String url,
    required String method,
    required Map<String, String> headers,
    String? body,
  }) async {
    var script = _buildScript(url, method, headers, body);
    await controller.evaluateJavascript(source: script);

    // 最多等 12 秒（每秒 8 次轮询）
    for (var i = 0; i < 96; i++) {
      await Future.delayed(const Duration(milliseconds: 125));
      var raw = await controller.evaluateJavascript(source: "window.__slKickRes");
      var decoded = _decodeLoose(raw);
      if (decoded is Map && decoded["__done"] == true) {
        var status = int.tryParse(decoded["s"]?.toString() ?? "") ?? 0;
        var text = decoded["b"]?.toString() ?? "";
        if (status >= 200 && status < 300 && text.trim().isNotEmpty) {
          return text;
        }
        Log.w("Kick WebView 返回 $status：${text.length > 120 ? text.substring(0, 120) : text}");
        return null;
      }
      // 页面被跳走 / 控制器失联时直接退出，交给外层重试
      if (decoded is String && decoded == "__missing__") {
        continue;
      }
    }
    Log.w("Kick WebView 请求超时：$url");
    return null;
  }

  /// fetch 里不能出现 Cookie / User-Agent 这类禁止头（浏览器会直接丢弃），
  /// 去掉它们，靠 credentials: include 带上 cookie
  static const _forbiddenHeaders = {
    "cookie",
    "user-agent",
    "origin",
    "host",
    "content-length",
    "connection",
  };

  String _buildScript(
    String url,
    String method,
    Map<String, String> headers,
    String? body,
  ) {
    var safeHeaders = <String, String>{};
    headers.forEach((key, value) {
      if (!_forbiddenHeaders.contains(key.toLowerCase())) {
        safeHeaders[key] = value;
      }
    });
    var methodJson = jsonEncode(method.toUpperCase());
    var urlJson = jsonEncode(url);
    var headersJson = jsonEncode(safeHeaders);
    var bodyJson = body == null ? "null" : jsonEncode(body);

    return """
(function(){
  window.__slKickRes = "";
  try {
    var opt = {
      method: $methodJson,
      headers: $headersJson,
      credentials: "include",
      cache: "no-store"
    };
    var body = $bodyJson;
    if (body !== null) { opt.body = body; }
    fetch($urlJson, opt).then(function(r){
      return r.text().then(function(t){
        window.__slKickRes = JSON.stringify({__done:true, s:r.status, b:t});
      });
    }).catch(function(e){
      window.__slKickRes = JSON.stringify({__done:true, s:-1, b:String(e)});
    });
  } catch (e) {
    window.__slKickRes = JSON.stringify({__done:true, s:-1, b:String(e)});
  }
})();
""";
  }

  /// evaluateJavascript 拿到的可能是被多层编码的字符串，逐层解开
  static dynamic _decodeLoose(dynamic raw) {
    var value = raw;
    for (var i = 0; i < 3; i++) {
      if (value is! String) {
        return value;
      }
      var text = value.trim();
      if (text.isEmpty) {
        return null;
      }
      if (!text.startsWith("{") && !text.startsWith("[")) {
        // 还没写入结果（空字符串）或者页面结构变了
        return text == "" ? null : text;
      }
      try {
        value = jsonDecode(text);
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  /// 确保隐藏 WebView 已打开 kick.com 上的一个轻量页面（拿到同源 origin）
  Future<void> _ensurePage() async {
    if (_controller != null) {
      return;
    }
    var existing = _pageReady;
    if (existing != null) {
      return existing.future;
    }
    var completer = Completer<void>();
    _pageReady = completer;

    // 打开 kick.com 首页：除了拿到同源 origin，还能顺手把边缘节点下发的
    // cookie（含风控用的 clearance）和 JS 环境都准备好
    var headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri("https://kick.com/")),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        thirdPartyCookiesEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
      },
      onLoadStop: (controller, url) {
        _controller = controller;
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onReceivedError: (controller, request, error) {
        // 4xx/5xx 也是页面加载「完成」，origin 已经就位，照样可以用
        _controller = controller;
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
    );
    _headless = headless;
    try {
      await headless.run();
      _controller = headless.webViewController ?? _controller;
    } catch (e) {
      Log.w("Kick WebView 创建失败：$e");
      _pageReady = null;
      rethrow;
    }

    // 兜底：8 秒还没等到 onLoadStop 也放行，直接尝试注入脚本
    unawaited(Future.delayed(const Duration(seconds: 8), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }));

    return completer.future;
  }

  Future<void> _dispose() async {
    var headless = _headless;
    _headless = null;
    _controller = null;
    _pageReady = null;
    if (headless == null) {
      return;
    }
    try {
      await headless.dispose();
    } catch (_) {
      // 已经销毁过就忽略
    }
  }
}

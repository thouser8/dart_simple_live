import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/account.dart';
import 'package:simple_live_app/services/platform_service.dart';

/// Kick 网页登录
///
/// Kick 没有扫码登录，网页端只提供邮箱密码 + 第三方 OAuth（Google / X / Discord 等）。
/// 所以这里沿用 B 站「Web 登录」那一套：
/// 在内置浏览器里打开 kick.com 登录页，登录成功后从 cookie 里取出 `session_token`
/// 作为 credential 存下来，之后所有请求都带上它。
class KickWebLoginController extends BaseController {
  Account account = Get.arguments;
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();

  /// 防止重复触发登录
  bool _logging = false;

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    webViewController!.loadUrl(
      urlRequest: URLRequest(
        url: WebUri("https://kick.com/login"),
      ),
    );
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) async {
    if (_logging) {
      return;
    }
    // 登录成功最直接的信号：kick.com 域下出现了 session_token
    try {
      var cookies = await cookieManager.getCookies(
        url: WebUri("https://kick.com"),
      );
      var token = cookies.where(
        (e) => e.name == "session_token" && (e.value ?? "").isNotEmpty,
      );
      if (token.isEmpty) {
        return;
      }
      await logined(cookies);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> logined(List<Cookie> cookies) async {
    _logging = true;
    try {
      var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join("; ");
      var credential = jsonEncode({'cookie': cookieStr});
      Log.i("kick cookie: $cookieStr");

      var res = await PlatformService.instance.accountLogin(
        account.copyWith(credential: credential),
      );
      if (!res) {
        SmartDialog.showToast('登录校验失败，请重试');
        _logging = false;
        return;
      }
      SmartDialog.showToast('Kick 登录成功');
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      _logging = false;
    }
  }
}

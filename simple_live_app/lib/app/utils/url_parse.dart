import 'package:dio/dio.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';

class UrlParse {
  static UrlParse? _urlParse;

  static UrlParse get instance {
    _urlParse ??= UrlParse();
    return _urlParse!;
  }

  /// 链接解析工具
  Future<List> parse(String url) async {
    var id = "";
    // 粘贴时经常带空格、换行，先清掉
    url = url.trim();
    if (url.contains("bilibili.com")) {
      var regExp = RegExp(r"bilibili\.com/([\d|\w]+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";
      return [id, Sites.allSites[Constant.kBiliBili]!];
    }

    if (url.contains("b23.tv")) {
      var btvReg = RegExp(r"https?:\/\/b23.tv\/[0-9a-z-A-Z]+");
      var u = btvReg.firstMatch(url)?.group(0) ?? "";
      var location = await _getLocation(u);

      return await parse(location);
    }

    if (url.contains("douyu.com")) {
      var regExp = RegExp(r"douyu\.com/([\d|\w]+)");
      // 适配 topic_url
      if (url.contains("topic")) {
        regExp = RegExp(r"[?&]rid=([\d]+)");
      }
      id = regExp.firstMatch(url)?.group(1) ?? "";

      return [id, Sites.allSites[Constant.kDouyu]!];
    }
    if (url.contains("huya.com")) {
      var regExp = RegExp(r"huya\.com/([\d|\w]+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";

      return [id, Sites.allSites[Constant.kHuya]!];
    }
    if (url.contains("live.douyin.com")) {
      var regExp = RegExp(r"live\.douyin\.com/([\d\w.]+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";

      return [id, Sites.allSites[Constant.kDouyin]!];
    }
    if (url.contains("webcast.amemv.com")) {
      var regExp = RegExp(r"reflow/(\d+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";
      return [id, Sites.allSites[Constant.kDouyin]!];
    }
    if (url.contains("twitch.tv/")) {
      final regExp = RegExp(r'twitch\.tv/([^/?]+)');
      id = regExp.firstMatch(url)?.group(1) ?? "";
      return [id, Sites.allSites[Constant.kTwitch]!];
    }
    // Kick：频道页 https://kick.com/{slug}
    // 也接受接口地址 https://kick.com/api/v2/channels/{slug}
    if (url.contains("kick.com")) {
      id = _parseKickId(url);
      if (id.isNotEmpty) {
        return [id, Sites.allSites[Constant.kKick]!];
      }
    }
    if (url.contains("v.douyin.com")) {
      var regExp = RegExp(r"http.?://v.douyin.com/[\d\w]+/");
      var u = regExp.firstMatch(url)?.group(0) ?? "";
      var location = await _getLocation(u);
      return await parse(location);
    }

    return [];
  }

  /// Kick 的一级路径，这些不是房间名
  static const _kickReserved = {
    "api",
    "categories",
    "category",
    "browse",
    "following",
    "followers",
    "search",
    "login",
    "signup",
    "register",
    "settings",
    "messages",
    "dashboard",
    "video",
    "videos",
    "popular",
    "help",
    "about",
    "terms",
    "privacy",
    "clip",
    "clips",
    "subscriptions",
  };

  /// 从 Kick 链接里取频道 slug
  ///
  /// 支持三种写法：
  /// * `https://kick.com/quin3614`
  /// * `https://kick.com/quin3614/chat`
  /// * `https://kick.com/api/v2/channels/quin3614`（接口地址，容易被直接粘贴）
  static String _parseKickId(String url) {
    var text = url.trim();

    // 接口地址优先：/api/v2/channels/{slug}
    var apiMatch =
        RegExp(r'kick\.com/api/v\d+/channels/([^/?#\s]+)').firstMatch(text);
    if (apiMatch != null) {
      return apiMatch.group(1) ?? "";
    }

    // 频道页：取 kick.com 之后的第一段
    var pageMatch = RegExp(r'kick\.com/([^/?#\s]+)').firstMatch(text);
    var seg = pageMatch?.group(1) ?? "";
    if (seg.isEmpty) {
      return "";
    }
    if (_kickReserved.contains(seg.toLowerCase())) {
      return "";
    }
    // 频道名里不会带 .m3u8 之类，防止把播放直链当成房间号
    if (seg.contains(".m3u8") || seg.contains(".mp4")) {
      return "";
    }
    return seg;
  }

  Future<String> _getLocation(String url) async {
    try {
      if (url.isEmpty) return "";
      await Dio().get(
        url,
        options: Options(
          followRedirects: false,
        ),
      );
    } on DioException catch (e) {
      if (e.response!.statusCode == 302) {
        var redirectUrl = e.response!.headers.value("Location");
        if (redirectUrl != null) {
          return redirectUrl;
        }
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return "";
  }
}

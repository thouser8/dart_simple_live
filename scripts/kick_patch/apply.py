#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「Kick 直播平台支持」补丁打进上游作者的最新代码。

TV 打包流程每次都会签出作者仓库（SlotSun/dart_simple_live）的最新分支，
那份代码里没有 Kick。本脚本把本仓库里已有的 Kick 实现搬运过去并接线，
让「作者的 TV 新功能」和「我们自己的 Kick」同时存在。

用法：
    python3 scripts/kick_patch/apply.py <目标仓库根目录> <补丁源目录>

    <目标仓库根目录>  签出作者代码的目录（通常是 .）
    <补丁源目录>      签出本仓库的目录（默认 _kickpatch）

设计原则：
  * 全部步骤幂等（重复执行不叠加）；
  * 每个锚点找不到就立刻 `::error::` 退出，绝不产出「看着打好了其实没打上」的包；
  * 只改必需的行，尽量缩小与上游的冲突面。
"""

import io
import os
import re
import shutil
import sys


def read(path):
    return io.open(path, encoding="utf-8").read()


def write(path, text):
    io.open(path, "w", encoding="utf-8", newline="").write(text)


def fail(msg):
    print("::error::" + msg)
    sys.exit(1)


def need(cond, msg):
    if not cond:
        fail(msg)


def step(title):
    print("\n▶ " + title)


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "."
    src = sys.argv[2] if len(sys.argv) > 2 else "_kickpatch"

    target = os.path.abspath(target)
    src = os.path.abspath(src)
    need(os.path.isdir(src), "补丁源目录不存在：%s" % src)

    # ------------------------------------------------------------------
    step("1. 复制 core 的 kick 平台实现")
    src_kick = os.path.join(src, "simple_live_core/lib/src/platforms/kick")
    dst_kick = os.path.join(target, "simple_live_core/lib/src/platforms/kick")
    need(os.path.isdir(src_kick), "补丁源里没有 kick 平台目录：%s" % src_kick)
    if os.path.isdir(dst_kick):
        shutil.rmtree(dst_kick)
    shutil.copytree(src_kick, dst_kick)
    files = sorted(os.listdir(dst_kick))
    need(len(files) > 0, "kick 平台目录复制后为空")
    print("   " + ", ".join(files))

    # ------------------------------------------------------------------
    step("2. core 入口导出 KickSite")
    core_lib = os.path.join(target, "simple_live_core/lib/simple_live_core.dart")
    need(os.path.isfile(core_lib), "找不到 %s" % core_lib)
    text = read(core_lib)
    if "platforms/kick/kick_site.dart" in text:
        print("   已存在，跳过")
    else:
        anchor = "export 'src/platforms/twitch/twitch_site.dart';"
        need(anchor in text, "core 入口里找不到 twitch 的 export 行，无法定位插入点")
        text = text.replace(
            anchor, anchor + "\nexport 'src/platforms/kick/kick_site.dart';", 1
        )
        write(core_lib, text)
        print("   已在 twitch 之后插入 kick export")

    # ------------------------------------------------------------------
    step("3. 复制 TV 端图标与 WebView 抓取器")
    png_src = os.path.join(src, "simple_live_tv_app/assets/images/kick.png")
    png_dst = os.path.join(target, "simple_live_tv_app/assets/images/kick.png")
    need(os.path.isfile(png_src), "补丁源里没有 kick.png")
    need(
        os.path.isdir(os.path.dirname(png_dst)),
        "目标里没有 assets/images 目录，TV 工程结构可能变了",
    )
    shutil.copyfile(png_src, png_dst)
    print("   kick.png %d 字节" % os.path.getsize(png_dst))

    fetcher_src = os.path.join(src, "simple_live_tv_app/lib/services/kick_web_fetcher.dart")
    fetcher_dst = os.path.join(target, "simple_live_tv_app/lib/services/kick_web_fetcher.dart")
    need(os.path.isfile(fetcher_src), "补丁源里没有 kick_web_fetcher.dart")
    need(
        os.path.isdir(os.path.dirname(fetcher_dst)),
        "目标里没有 lib/services 目录，TV 工程结构可能变了",
    )
    shutil.copyfile(fetcher_src, fetcher_dst)
    print("   kick_web_fetcher.dart %d 字节" % os.path.getsize(fetcher_dst))

    # ------------------------------------------------------------------
    step("4. 注册 Kick 站点（sites.dart）")
    sites = os.path.join(target, "simple_live_tv_app/lib/app/sites.dart")
    need(os.path.isfile(sites), "找不到 %s" % sites)
    text = read(sites)
    if "KickSite()" in text:
        print("   已存在，跳过")
    else:
        indexes = [int(x) for x in re.findall(r"^\s*index:\s*(\d+)\s*,", text, re.M)]
        idx = (max(indexes) + 1) if indexes else 0
        block = (
            '    "kick": Site(\n'
            '      id: "kick",\n'
            '      logo: "assets/images/kick.png",\n'
            '      name: "Kick",\n'
            '      liveSite: KickSite(),\n'
            "      index: %d,\n"
            "    ),\n" % idx
        )
        m = re.search(r"\n  \};\n", text)
        need(m is not None, "sites.dart 里找不到 allSites 的结束标记，结构可能变了")
        text = text[: m.start() + 1] + block + text[m.start() + 1 :]
        need("import 'package:simple_live_core/simple_live_core.dart';" in text,
             "sites.dart 没有导入 simple_live_core，KickSite 会找不到")
        write(sites, text)
        print("   已插入 Kick 站点，index=%d" % idx)

    # ------------------------------------------------------------------
    step("5. 启动时注册 WebView 兜底（main.dart）")
    main_dart = os.path.join(target, "simple_live_tv_app/lib/main.dart")
    need(os.path.isfile(main_dart), "找不到 %s" % main_dart)
    text = read(main_dart)
    changed = False
    if "services/kick_web_fetcher.dart" not in text:
        imports = list(re.finditer(r"^import [^\n]+\n", text, re.M))
        need(len(imports) > 0, "main.dart 里找不到 import 段")
        pos = imports[-1].end()
        text = (
            text[:pos]
            + "import 'package:simple_live_tv_app/services/kick_web_fetcher.dart';\n"
            + text[pos:]
        )
        changed = True
        print("   已添加 import")
    if "KickWebFetcher.register()" not in text:
        anchor = "await initServices();"
        need(text.count(anchor) >= 1, "main.dart 里找不到 `await initServices();`")
        text = text.replace(
            anchor,
            anchor + "\n  // Kick 接口有浏览器指纹风控，注册 WebView 内核兜底\n  KickWebFetcher.register();",
            1,
        )
        changed = True
        print("   已在 initServices() 之后注册")
    if changed:
        write(main_dart, text)
    else:
        print("   已存在，跳过")

    # ------------------------------------------------------------------
    step("6. TV 工程添加 flutter_inappwebview 依赖（pubspec.yaml）")
    pubspec = os.path.join(target, "simple_live_tv_app/pubspec.yaml")
    need(os.path.isfile(pubspec), "找不到 %s" % pubspec)
    text = read(pubspec)
    if "flutter_inappwebview" in text:
        print("   已存在，跳过")
    else:
        dep = (
            "\n  # Kick 接口有浏览器指纹风控，需要用 WebView 内核发请求（隐藏页面）\n"
            "  flutter_inappwebview:\n"
            "    git:\n"
            "      url: https://github.com/guide-inc-org/guide-flutter_inappwebview.git\n"
            "      path: flutter_inappwebview\n"
            "      ref: sbi_fx_pc/v6.2.0-beta.3\n"
        )
        m = re.search(r"^dependency_overrides:", text, re.M)
        need(m is not None, "pubspec.yaml 里找不到 dependency_overrides，无法定位插入点")
        text = text[: m.start()] + dep.lstrip("\n") + "\n" + text[m.start() :]
        write(pubspec, text)
        print("   已添加依赖")

    # ------------------------------------------------------------------
    step("7. 结果校验")
    checks = [
        (os.path.join(target, "simple_live_core/lib/src/platforms/kick/kick_site.dart"), "core kick_site"),
        (os.path.join(target, "simple_live_tv_app/lib/services/kick_web_fetcher.dart"), "TV fetcher"),
        (os.path.join(target, "simple_live_tv_app/assets/images/kick.png"), "TV 图标"),
    ]
    for path, label in checks:
        need(os.path.isfile(path), "缺少文件：%s" % path)
        print("   %-12s %s" % (label, path))

    for path, needle, label in [
        (core_lib, "platforms/kick/kick_site.dart", "core export"),
        (sites, "KickSite()", "sites 注册"),
        (main_dart, "KickWebFetcher.register()", "main 注册"),
        (pubspec, "flutter_inappwebview", "pubspec 依赖"),
    ]:
        need(needle in read(path), "%s 未生效：%s" % (label, path))
        print("   %-12s OK" % label)

    print("\n✅ Kick 补丁已全部应用")


if __name__ == "__main__":
    main()

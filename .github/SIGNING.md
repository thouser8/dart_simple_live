# 签名与包名说明（两个自建仓库）

仓库 1：`thouser8/dart_simple_live`（基于 SlotSun 上游）
仓库 2：`thouser8/slive-june`（基于 June6699 上游）

两个仓库的 APK 都使用自己独立的包名，因此可以和官方原版同时安装、互不覆盖。

## 包名对照

| 仓库 | 端 | 自建版包名 | 官方原版包名 | 显示名 |
| --- | --- | --- | --- | --- |
| 仓库1 | 手机 | `com.slotsun.slive.my` | `com.slotsun.slive` | Simple Live 自建版 |
| 仓库1 | TV | `com.xycz.simple_live_tv.my` | `com.xycz.simple_live_tv` | Simple Live TV 自建版 |
| 仓库2 | 手机 | `com.xycz.simple_live.june` | `com.xycz.simple_live` | Simple Live 自建版 |
| 仓库2 | TV | `com.xycz.simple_live_tv.june` | `com.xycz.simple_live_tv` | Simple Live TV 自建版 |

后缀 `.my` / `.june` 写在对应 workflow 的「应用自定义设置」步骤里，构建时临时
改写，**不改仓库里的 `build.gradle.kts`**，所以同步上游不会冲突。

## 签名为什么不会被上游覆盖

- 密钥文件（`*.jks`）已被 `.gitignore` 排除，**从未进入仓库**；
- 构建时由 workflow 从 GitHub Secret 解码到 runner 的临时目录，用完即弃；
- 上游仓库里没有任何与本项目同名的 workflow 文件，同步时不会被覆盖或改写。

也就是说：只要 Secret 还在，签名就永远是你这一份。

## 仓库 2 需要配置的 Secret

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Secret 名称 | 值 |
| --- | --- |
| `SLIVE_JUNE_KEYSTORE_BASE64` | `signing/keystore.b64` 的**全部内容**（一行 base64） |
| `SLIVE_JUNE_KEYSTORE_PASSWORD` | 密钥密码（见本机 `signing/password.txt`） |

> 这两个值保存在本机 `signing/` 目录中，**该目录不进入仓库**。
> 请自行备份到网盘或密码管理器 —— 一旦丢失，已安装的旧版本将无法覆盖升级，
> 只能卸载重装（数据会丢）。

## 仓库 1 的签名

仓库 1 直接复用你之前配好的 4 个 Secret：`TV_KEYSTORE_BASE64` /
`TV_STORE_PASSWORD` / `TV_KEY_PASSWORD` / `TV_KEY_ALIAS`。
手机版和 TV 版都用这一套，不需要新增。

## 邮件通知（两个仓库都要配）

构建完成后自动发信，需要 4 个 Secret（两个仓库各配一份）：

| Secret 名称 | QQ 邮箱的填法 | 163 邮箱 | Gmail |
| --- | --- | --- | --- |
| `MAIL_TO` | 收件邮箱，可以就是你自己 | 同左 | 同左 |
| `SMTP_HOST` | `smtp.qq.com` | `smtp.163.com` | `smtp.gmail.com` |
| `SMTP_PORT` | `465` | `465` | `465` |
| `SMTP_USER` | 你的完整邮箱地址 | 同左 | 同左 |
| `SMTP_PASS` | QQ 邮箱「授权码」 | 163 授权码 | 应用专用密码 |

QQ 邮箱授权码获取：QQ 邮箱网页版 → 设置 → 账号 → 开启「POP3/SMTP 服务」→ 生成授权码。
**注意不是 QQ 登录密码。**

没配这 4 个 Secret 时，构建照常出包，只是不发邮件（日志里会有提示）。

## 上游自动同步

两个仓库各有一个 `Sync Upstream (同步上游)` 流程：

- 每周一 03:00 UTC（北京 11:00）自动跑，也可手动触发
- 能干净合并 → 自动 push，**并自动触发手机版 + TV 版构建**，构建完发邮件
- 合并冲突 → 自动放弃，仓库保持原样，只报错提醒（不会把仓库搞坏）

## 本地构建

在 `simple_live_app/android/key.properties`（TV 是 `simple_live_tv_app/android/key.properties`）写入：

```properties
storeFile=/绝对路径/slive-june.jks
storePassword=你的密码
keyPassword=你的密钥密码
keyAlias=slive
```

`key.properties` 同样已被 `.gitignore` 排除，不会误提交。

# 云析 iOS（YunX for iPhone）

把 `CYQawa/YunX`（Android）和 `tidain/YunX-Desktop`（Windows）的解析能力，做成**原生 iOS App**：
纯 SwiftUI + URLSession，**不依赖服务器**，装到 iPhone 上直接解析、下载、存进「文件」App。

- 目标系统：iOS 16+
- 代码：13 个 Swift 文件，约 1250 行
- 已做语法自检：`py tools/verify.py` → 13 files, 0 errors
- 已实机构建：GitHub Actions `macos-15-intel` → `YunX-unsigned.ipa`（arm64，191 KB，Bundle ID `com.yunx.ios`）
- 编译在 GitHub Actions 的 macOS runner 上跑（Windows 电脑不用装任何 Apple 工具）

---

## 它能干什么

| 功能 | 说明 |
|---|---|
| 分享链接识别 | 夸克 `pan.quark.cn/s/xxx`、UC `drive.uc.cn/s/xxx`、百度 `pan.baidu.com/s/1xxx`，自动提取「提取码：xxxx」 |
| 登录 | 内置 WKWebView 打开官方网页登录（扫码/手机号都行），完成后自动抓该域名 Cookie |
| 手动 Cookie | 也可以从电脑浏览器复制整行 Cookie 粘进来 |
| 目录浏览 | 分享里的文件夹可以逐层点进去 |
| 取直链 | 转存 → 轮询任务 → `file/download` 拿签名直链（带 Referer/UA/Cookie） |
| 下载 | URLSession 下载，进度实时显示，完成后落到 App 的 Documents |
| 保存到「文件」 | 开启 `UIFileSharingEnabled`，文件 App 里 `/我的 iPhone/云析` 直接能看到；也能用分享面板导出 |
| 凭据安全 | Cookie 存 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），页面只显示前 20 字符 |

**没有的**：磁力/BT、115/123/迅雷/139/光鸭/蓝奏、视频平台（抖音/B站等）、转码合流、后台常驻下载。
这些在 Android/桌面版里是额外模块，iOS 版先做通「网盘分享 → 直链 → 下载」这条主链。

### 百度网盘（已接入）

走的是网页端分享链路，和 AList 的实现一致：

1. `GET pan.baidu.com/s/1<surl>` → 抓 `shareid` / `share_uk` / `sign` / `timestamp`
2. `POST /share/verify` → `randsk`（带提取码时），塞进 Cookie `BDCLND`
3. `GET /share/list?uk=&shareid=&dir=` → 文件列表（`fs_id` / `server_filename` / `isdir` / `path`）
4. `POST /api/sharedownload` → `dlink`
5. 下载 `dlink`：UA 用 `pan.baidu.com`，带 `Cookie` + `Referer`

百度这块的坑比夸克多，先说清楚：

- **Cookie 必须包含 `BDUSS`**，否则 `sharedownload` 会返回 `errno=-6`。
- `errno=-62` 是触发验证码风控：先用 Safari 打开一次这个分享页，过验证再回 App 解析。
- `errno=118` 是限速：等一会儿或换号，别并发拉。
- `errno=112` 是分享失效；`errno=-9` 是提取码错。
- 百度对短时间大量取链很敏感，**建议一次下一个文件**，别批量。
- 失败时 App 会把 `errno` 直接显示出来，照着上面这张表处理。

---

## 怎么装到 iPhone（三条路，选一条）

### 路线 A：GitHub Actions 出 IPA + Sideloadly 签名（Windows 就能做，无需 Mac）

**准备**：一个 GitHub 账号、一台 Windows 电脑、一根数据线、你的 Apple ID（免费账号即可）。

1. **建仓库并上传代码**
   打开 https://github.com/new 建一个空仓库（Private 也行）；
   把本目录（`YunX-iOS`）里的**全部内容**传到仓库根目录——注意 `.github/workflows/ios.yml` 必须保持在
   `.github/workflows/` 下，否则 Actions 不会出现。
   网页上传：`Add file → Upload files`，把文件夹拖进去，Commit。

2. **让它编译**
   仓库 → `Actions` → 左侧 `Build iOS IPA` → `Run workflow` → 等 3~6 分钟（macOS 机器排队可能要 10~20 分钟）。
   绿色对勾后，点进这次运行 → 页面底部 `Artifacts` → 下载 `YunX-unsigned-ipa` → 解压得到
   `YunX-unsigned.ipa`。

> 实测坑：`macos-14` 镜像已下架（任务秒取消），`macos-15`（arm64）在免费账号上常常排不到机器。
> 现用 `runs-on: macos-15-intel`，能正常出包。排到机器后编译只要 2~4 分钟。

3. **装到手机（Windows）**
   - 装 [Sideloadly](https://sideloadly.io/)（免费）；
   - Windows 还需要 Apple 的驱动：装 [Apple Devices](https://apps.microsoft.com/detail/9np83lwlpz9k)
     或官网版 iTunes（**不要** Microsoft Store 版 iTunes，驱动装不全）；
   - 手机连电脑，信任此电脑；
   - Sideloadly 里：`IPA` 选刚下载的 `YunX-unsigned.ipa`，`Apple account` 填你的 Apple ID，
     点 `Start`，输入 Apple ID 密码（如有二次验证按提示填）；
   - 装完手机上：`设置 → 通用 → VPN与设备管理 → 开发者App → 信任你的 Apple ID`。

4. **打开用**
   桌面出现「云析」→ 打开 → 「账号」页登录夸克 → 回「解析」页贴分享链接。

> 免费 Apple ID 的限制：签名 **7 天** 过期、最多同时装 3 个自签 App、每 7 天要重新签一次。
> 想省事：装 **SideStore** 或 **AltStore**（同一台电脑做一次配对，之后手机自动续签，不用连电脑）。

### 路线 B：有 Mac（最省事）

```bash
brew install xcodegen
cd ios
xcodegen generate          # 生成 YunX.xcodeproj
open YunX.xcodeproj
```

Xcode 里选 `YunX` target → `Signing & Capabilities` → 勾 `Automatically manage signing` → 选你的
Apple ID Team → 选真机 → `Run`。
（免费账号同样 7 天；付费开发者账号 1 年，还能用 TestFlight 分发给别人。）

### 路线 C：想直接上架/长期用

需要 Apple Developer Program（$99/年）：Xcode 归档 → App Store Connect → TestFlight 内测或提交审核。
网盘解析类 App 上架审核风险高，一般走 TestFlight 或自签。

---

## 用起来

1. 「账号」→ 选平台（夸克 / UC / 百度）→ **用内置浏览器登录** → 登录成功后点右上角「完成」（自动抓 Cookie）。
   也可以手动粘贴 Cookie：电脑 Chrome 登录对应网盘 → F12 → Network → 任一请求 →
   Request Headers 里的整行 `Cookie:`（夸克/UC 要包含 `__pus=` `__puus=`；百度要包含 `BDUSS=`）。
2. 「解析」→ 粘贴分享文案（可带提取码）→ 解析 → 出现文件列表。
3. 点文件 → 开始下载（转存 + 取链在后台自动完成，第一次会慢 1~3 秒）。
4. 「下载」→ 看进度 → 完成后点 **导出到「文件」**，或直接在
   `文件 App → 我的 iPhone → 云析` 里找。
5. 直链有时效（几小时），过期就重新解析一次。

---

## 出问题了看这里

| 现象 | 原因 / 处理 |
|---|---|
| Actions 编译失败 | 点开红色步骤看第一条 `error:`。把日志发我，我按报错改代码 |
| 装完打不开、闪退 | 多半是没在「VPN与设备管理」里信任开发者证书 |
| 提示「未受信任的开发者」 | 同上 |
| 7 天后打不开 | 免费签名过期，重新用 Sideloadly 签一次（或用 SideStore 自动续签） |
| 解析报「取 token 失败」 | 没登录 / Cookie 过期 / 提取码错 / 分享失效 |
| 解析报「转存失败」 | 自己网盘空间满，或账号被风控（百度最凶，夸克相对宽松） |
| 下载 403 | 直链过期，回「解析」重新点一次 |
| 下载到一半断 | 保持 App 在前台；iOS 给后台的时间只有几十秒 |
| 找不到文件 | 文件 App → 浏览 → 我的 iPhone → 云析 |

---

## 目录结构

```
YunX-iOS/
├─ ios/
│  ├─ project.yml                     XcodeGen 工程描述（不用手写 pbxproj）
│  ├─ Support/Info.plist              文件共享、竖屏、启动屏
│  └─ Sources/
│     ├─ YunXApp.swift                入口
│     ├─ Models.swift                 Platform / CloudFile / 错误类型
│     ├─ ShareParser.swift            分享链接正则（移植 ShareLinkParser.kt）
│     ├─ Net.swift                    HTTP 封装（手动带 Cookie/UA/Referer）
│     ├─ QuarkClient.swift            夸克/UC：token → detail → save → task → download
│     ├─ BaiduClient.swift            百度：分享页 → verify → list → sharedownload
│     ├─ Drive.swift                  CloudDrive 协议 + 各平台适配（列目录/取直链）
│     ├─ CookieStore.swift            Keychain 存 Cookie
│     ├─ Downloader.swift             URLSession 下载 + 进度 + 落盘
│     ├─ ResolveView.swift            解析页 / 文件夹页
│     ├─ DownloadsView.swift          下载页 + 导出到文件
│     ├─ SettingsView.swift           账号页（登录/粘贴/清除）
│     ├─ LoginSheet.swift             WKWebView 登录 + 抓 Cookie
│     └─ Assets.xcassets/AppIcon      1024 图标
└─ .github/workflows/ios.yml          macOS runner 出 unsigned IPA
```

## 加一个平台（比如 115 / 123）

1. `Models.swift` 的 `Platform` 加 case，补 `apiBase / referer / cookieHost / userAgent`；
2. `ShareParser.swift` 的 `patterns` 加一条正则；
3. 写一个 `XxxClient`，再在 `Drive.swift` 里加一个 `XxxDrive: CloudDrive`（实现 `list` / `direct` / `rootID`），
   把新的 state 塞进 `DriveState` 枚举，`makeDrive` 里加一个分支即可——上层视图完全不用改。

上游 `Pan115Api.kt`、`Pan123Api.kt`、`BaiduApi.kt` 就是现成的接口文档。

---

## 说明

- 本项目是个人使用工具，解析能力来自上游 AGPL-3.0 项目的接口实现；分发修改版请遵守 AGPL-3.0。
- 下载内容的版权归原作者，别拿去做二次分发。
- 网盘接口随时可能变；变了就改 `QuarkClient.swift` 里对应的路径 / 参数。

# muxi

幕汐 · 播放器与私人影视库

muxi 是面向 macOS 与 Windows 的免费开源视频播放器与私人影视库项目。**当前可下载版本为 macOS；Windows 版尚在规划，暂不提供安装包。** 当前采用 SwiftUI + libmpv（IINA 同样使用 mpv），在应用内解码，直接连接自己的 Emby / Jellyfin 服务器，没有订阅、广告、遥测或第三方账号。幕汐原创代码采用 MIT；随应用打包的播放运行库另有 GPL 等许可要求，见下方许可证说明。

英文名统一使用小写 **muxi**，下方中文名为 **幕汐**。mux 呼应音视频封装。后续功能和平台交付标准见 [更新路线图](docs/ROADMAP.md)，正式图标采用 [C · 石墨薄荷](docs/brand/README.md)。

> 当前是 [v0.1.0-alpha.4 预览版](https://github.com/HectorGao/muxi-player/releases/tag/v0.1.0-alpha.4)。真实 Emby 播放已做本机验证；Jellyfin 已接入官方接口并通过协议测试替身检查，尚未用真实 Jellyfin 实例验收。兼容性仍需在不同服务器及媒体格式上验证，不是 Infuse / SenPlayer 的完整替代品。

## 已实现

- 可选择 Emby 或 Jellyfin，使用服务器账号登录，支持端口和反向代理路径；登录令牌存储在 macOS 钥匙串，密码不落盘。
- 连接后生成媒体墙：继续观看、未看过的高分推荐、按媒体库分区的横向海报行；各分区按需加载，提供进入完整列表的入口。
- 独立搜索、推荐和收藏入口；媒体库、电影、剧集、季/集目录、分页与影片详情。
- 分类页支持最近添加、年份、评分、名称排序，以及年份、类型、国家 / 地区、观看状态组合筛选；分类搜索保持当前分类范围。
- 海报及详情页的爱心可加入或取消收藏，结果同步到当前服务器；收藏页支持搜索。
- 推荐筛除服务器标记为已看的项目，再按评分与入库时间排序，是可解释的筛选规则，未接入 AI 或额外的个性化推荐服务。
- 打开资源时获取服务器提供的片源版本及编码信息；播放后从 libmpv 实际识别结果填充音轨和字幕菜单。
- libmpv 原始流播放与服务器 HLS 转封装/转码协商。
- 音轨和内嵌字幕在本机切换，支持加载 Emby 提供的外置字幕地址；这些操作不要求服务器烧录字幕。
- 独立的片源版本、分辨率上限和码率上限选择；重新加载时保留播放位置及暂停状态。
- 暂停/播放、时间轴拖动、前后 10 秒、音量、0.5–2 倍速、下一集、窗口全屏与 macOS 原生系统全屏。
- 播放开始、周期进度、暂停、停止同步；“退出播放”及离开播放页立即停止取流，提交进度并结束转码。同步失败的进度按服务器、账号与影片隔离保存在本机，下次播放优先恢复，确认同步后清除。
- 夜潮深色、晴汐浅色及跟随系统外观；侧栏与工具栏使用原生毛玻璃材质，背景取当前媒体库真实海报缓慢漂移。右上角外观菜单和设置可切换主题、关闭动态效果。
- 动态背景遵循系统减少动态效果/减少透明度设置，在播放或应用不活跃时暂停；减少透明度时退回纯色背景。支持键盘与辅助功能标签。

## 构建和运行

需要 macOS 14+、Swift 6 工具链（Xcode 或 Command Line Tools）、Python 3.9+ 和 libmpv。可以使用已安装的 IINA 运行库，或通过 Homebrew 安装 `mpv`；协议视频测试还需要支持 libass 的 FFmpeg。

```sh
git clone https://github.com/HectorGao/muxi-player.git
cd muxi-player
# 如果没有安装 IINA，可先执行：brew install mpv
./script/build_and_run.sh
```

产物是 `dist/MuxiPlayer.app`。构建脚本将选中的 libmpv 及其必要依赖复制到 app 内并签名，打包后播放内核无需再从 IINA 加载。也可以通过 Codex 的 Run 按钮启动。构建脚本支持 `--build-only`、`--verify`、`--debug`、`--logs`、`--telemetry`。

默认优先使用 `/Applications/IINA.app/Contents/Frameworks`，其次搜索 Homebrew。可设置 `MUXI_MPV_LIB_DIR=/path/to/mpv/lib` 选择自己的运行库。头文件固定为 mpv v0.41.0 / Client API 2.5；本机验证的 IINA 1.5.0 运行库为 mpv 0.41.0、FFmpeg 9.0.1。详细依赖、来源和打包方式见 [docs/mpv-runtime.md](docs/mpv-runtime.md)。

```sh
./script/test.sh
./script/build_and_run.sh --build-only
```

Command Line Tools 27 缺少 SwiftUI State 宏，并未自动发现 Testing 宏插件。项目使用标准 State 属性包装器的类型别名；测试脚本按当前工具链定位 Testing 插件，不修改全局 SDK 或开发者配置。

从 [GitHub Releases](https://github.com/HectorGao/muxi-player/releases) 下载带版本号的 **DMG**，打开后将 `muxi.app` 拖入 `Applications`，弹出磁盘，再从应用程序启动。也保留 APP ZIP 下载；更新前先退出旧版。预览包面向 Apple Silicon（arm64）、macOS 14+，使用临时签名，尚无 Developer ID 签名或 Apple 公证；首次打开可能被 Gatekeeper 提示。Intel Mac 尚未实机验收，不提供 Intel 包。

每次版本更新提交代码并推送 GitHub；`v*` tag 工作流构建 DMG、APP ZIP、源码附件和 SHA-256 清单，创建对应预览版 Release。已有版本和附件不覆盖。构建及发布细节见 [运行库与发布说明](docs/mpv-runtime.md)。

## 使用

1. 选择 Emby 或 Jellyfin，输入对应服务器根地址，如 `https://emby.example.com`、`https://jellyfin.example.com`、`http://192.168.1.10:8096` 或带反向代理路径的地址。
2. 输入该服务器的用户名和密码。连接后进入媒体墙，可继续观看、查看推荐，或按媒体库浏览海报。
3. 通过侧栏“搜索”查找当前服务器中的影片与剧集；点击海报或详情中的爱心收藏，再从“我的收藏”查看。收藏操作需要服务器确认，失败时会显示错误并保留原状态。
4. 打开影片，点击播放或继续播放。剧集先打开季，再选择集。
5. “退出播放”返回进入前的页面；切换侧栏同样停止视频下载。播放窗口底部可分别选择版本、字幕、音轨、分辨率和码率；“原始”保留源画质。音轨和字幕列表来自实际片源；画质降低仍需要服务器开放转码。
6. 通过左下角“我的 Emby”或“我的 Jellyfin”管理连接。当前保存一个连接，切换服务器前需先断开；断开会移除本机令牌，并尝试撤销服务端会话。

分类页的“排序”直接请求服务器；打开“筛选”时，按页读取整个分类的文字元数据与海报标识，再在本机执行组合筛选和分页，不下载视频，也不只筛选首页。大媒体库首次整理需要时间，界面显示已读取数量；离开分类会取消，点击刷新会重新读取。国家按服务器 `ProductionLocations` 原样列出，合拍片可以归入多个国家；缺失国家显示“未标注”。不会根据片名猜测产地，也不额外请求第三方刮削服务。筛选后的搜索匹配片名或原始片名；普通搜索仍使用服务器搜索。年份和类型同样依赖源提供准确元数据。

高码率播放时，画质区显示接收速率、缓存秒数、实际硬件 / 软件解码状态和累计丢帧。持续下载速度低于片源码率时，本地实时降码率不能省下公网带宽：原片仍需先完整传到本机，再编码还会增加计算负担。优先在版本菜单选择更低码率的已有片源；服务器允许时再调整分辨率 / 码率。暂停预缓冲只能吸收短时抖动，不能保证持续低带宽下无限流畅。幕汐保持 mpv 自动硬件解码，没有加入无效的本机“省流量转码”开关。参考 [Emby 播放方式说明](https://emby.media/support/articles/DirectPlay-Stream-Transcoding.html) 与 [mpv 硬件解码说明](https://mpv.io/manual/stable/#options-hwdec)。

新建 Emby 连接默认使用 **SenPlayer 兼容标识**，也可选择 **Infuse 兼容** 或 **muxi 原生标识**。仅改变 Emby `Authorization` 中的 `Client` 名称；HTTP User-Agent、设备标识、版本和实际播放内核仍属于 muxi，不复制第三方认证凭据。选择随连接保存，旧连接及未记录标识的历史连接保持原设置；Jellyfin 始终使用 muxi 原生标识。没有跨服务商的公开兼容率排名，本轮授权服务器对 Infuse 标识返回 HTTP 403、对 SenPlayer 标识允许登录，因此采用已验证的 SenPlayer 作为可切换的默认值；不能保证所有源放行；仍需有效账号和服务端授权。依据：[Emby 客户端认证字段](https://dev.emby.media/doc/restapi/User-Authentication.html)、[Infuse 的 Emby / Jellyfin 集成说明](https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin)。

如果钥匙串被锁定，或开发中重新签名使旧记录不可访问，应用仍可建立本次内存会话，并显示“登录未保存”。退出后需要重新登录；可先解锁钥匙串，或在“钥匙串访问”中移除旧的 `com.hectorgao.muxi-player` 记录，再重新连接。

如果提示“网页验证或拦截”，说明收到的是网关页面，尚未取得媒体服务器的接口响应，不能据此判断密码错误或转码权限不足。先核对服务商的播放地址和路径；若仍被拦截，需要服务商确认自建客户端的接入方式。普通 HTTP 403 与可识别的 Cloudflare 验证/拦截页面分别处理，错误提示不显示响应正文或凭据。

| 操作 | 快捷键 |
| --- | --- |
| 播放/暂停 | 空格 |
| 后退/前进 10 秒 | ← / → |
| 下一集 | ⇧⌘N |
| 停止播放 | ⌘. |
| 窗口全屏 | ⌘↩ |
| 系统全屏 | ⌃⌘F |
| 先关闭设置浮层 / 逐层退出全屏 | Esc |

播放器采用幕汐自己的界面，并未复制 IINA 的控制栏；两者使用同类的 libmpv 播放内核。播放器提供两个带文字的独立按钮：“窗口全屏”让影片铺满当前窗口，保留窗口尺寸和位置；“系统全屏”进入 macOS 独立全屏空间。窗口绿色按钮、⌃⌘F 和双击视频也进入系统全屏。播放全屏时隐藏侧栏和导航，控制栏浮在画面上；音轨、字幕和画质集中在右下角设置按钮。鼠标静止约 3 秒后控制栏自动收起，暂停、拖动、菜单打开和 VoiceOver 启用时保持可用。从窗口全屏进入系统全屏后，退出系统全屏回到之前的窗口全屏，再按 Esc 恢复媒体库布局；播放位置和轨道选择保持。

## 播放边界

- 播放内核已改为 libmpv + FFmpeg，并向服务器声明 MKV、H.264/HEVC、DTS/TrueHD 等直接播放能力。具体兼容性仍取决于运行库、文件内容和硬件，不能由能力申报推断所有格式都已实测。
- 内嵌字幕和服务器提供的外置字幕交由本机内核处理；已通过内嵌/外置 SRT 的自动化解码检查，以及一个真实 HEVC/MKV 片源中双语 PGS 字幕的原生画面检查。ASS 尚未做原生画面验收；暂未提供手动导入本地字幕文件的入口。
- 分辨率与码率是**上限**，不会把低清源升级为高清；限制实际输出由服务器执行。无法提供所选画质时显示错误，不悄悄回退到原画。
- 当账号明确禁用视频转码时，应用禁用降低分辨率和码率的选项；仍可切换已有片源版本、原始文件中的音轨和字幕。服务器仍需允许获取原始流及对应字幕文件。
- HLS 从完整 VOD 时间轴开始，由 libmpv 跳转到续播位置。未针对超长视频的远端转码启动时间优化。
- 不绕过服务器认证、播放授权或转码权限。免费指本客户端；Emby 服务端自己的功能许可与资源消耗由服务器决定。
- 当前保存一个 Emby 或 Jellyfin 连接；未实现多服务器同时管理、本地文件夹/M3U 接入、下载离线、直播、投屏、画中画或自动播放下一集；不承诺 HDR/Dolby Vision 保真输出或全格式解码。
- 普通 API 和海报请求使用对应服务的令牌请求头：Emby 使用 `X-Emby-Token`，Jellyfin 使用 `Authorization: MediaBrowser … Token="…"`。同源播放及外置字幕地址分别使用 Emby 的 `api_key` 或 Jellyfin 的 `ApiKey`；服务器/代理可能记录这些地址，应避免将其日志公开。
- API 和海报请求禁止跨站重定向；CDN 播放地址不额外附加服务器令牌。不绕过 TLS 证书错误。HTTP 仅建议用于可信网络。

## 本机集成验证

`script/smoke_server.py` 是仅监听 loopback 的 **协议测试替身**，不是 Emby Server 或 Jellyfin Server。它提供两组媒体库、分页、搜索、未看筛选、评分排序及可读写的收藏，同时生成双音轨 MKV、内嵌/外置 SRT，并提供 HLS、画质切换与进度接口，用于媒体墙和播放器联调。

```sh
python3 script/smoke_server.py --self-test
python3 script/smoke_server.py --ffmpeg /path/to/ffmpeg
```

服务运行后，在另一终端执行：

```sh
./script/check_library.sh
./script/check_playback.sh
```

`check_library.sh` 运行实际 `LibraryStore`，分别使用 Emby、Jellyfin 协议配置检查媒体墙、分区按需加载与取消后重入、继续观看、未看高分推荐、分页、搜索与空状态、过期请求隔离、收藏保存/移除和失败恢复。它会添加并移除测试影片的 fixture 收藏，不连接真实用户服务器。

`check_playback.sh` 静音运行真实 libmpv 引擎和幕汐播放控制器，检查 MKV 直播放、双音轨切换、内嵌/外置 SRT、HLS 解码、480p 输出、暂停状态、续播、倍速和停止同步。该检查采用 headless 输出，不验证 OpenGL 画面渲染。

在应用中选择 Emby 或 Jellyfin，并连接 `http://127.0.0.1:18796/emby`，测试账号和密码均为 `demo`。这里的 `/emby` 是 fixture 的反向代理测试路径，两种协议配置共用它。所有测试视频与事件保存在忽略提交的 `.local/smoke/` 中。测试后请在应用中断开此连接，再连接自己的服务器。

本机已通过 30 项 Core 协议测试、两种服务配置的媒体墙 Store 集成检查，以及 libmpv headless 回归检查。协议测试覆盖地址校验、反向代理、按服务区分的认证/流令牌、收藏接口、筛选分页、封面元数据、HTTP 错误、直播放选择、画质约束、字幕/音轨参数、进度字段及时间转换。

真实 Emby 原生界面已核对媒体墙封面、评分和年份、按库分区、完整电影列表、搜索及收藏增删；临时收藏测试结束后已恢复原状态。部分分区曾返回 HTTP 502，重新进入后恢复，未据此保证服务器持续可用。

另已在真实 Emby 片源中确认 HEVC 影片画面、DTS 轨道切换和双语 PGS 字幕；高码率源仍观察到网络缓冲，未验收整片持续流畅。Jellyfin 当前验证范围为官方接口核对、协议测试替身和原生类型选择入口，尚未连接真实 Jellyfin 实例验收。原生验证记录见 [docs/validation.md](docs/validation.md)，设计核对见 [design-qa.md](design-qa.md)。本机协议测试不代表真实服务开放转码，也不代表所有媒体格式兼容。

## 代码结构

- `Sources/MuxiCore`：Emby / Jellyfin 共用模型、服务类型、网络请求、播放协商、安全 URL 处理。
- `Sources/MuxiPlayer`：SwiftUI 窗口、媒体库、钥匙串、libmpv 生命周期和 AppKit/OpenGL 渲染。
- `Sources/CMPV`：上游 libmpv C API 头文件及 Swift 模块桥接。
- `Tests/MuxiCoreTests`：Swift Testing 协议与边界测试。
- `script`：构建、测试、本机协议测试服务。

接口依据：[Emby 用户认证](https://dev.emby.media/doc/restapi/User-Authentication.html)、[PlaybackInfo](https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html)、[播放进度](https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html)、[Jellyfin 维护者认证规范](https://gist.github.com/nielsvanvelzen/ea047d9028f676185832e51ffaf12a6f)、[Jellyfin Items API](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/ItemsController.cs)、[Jellyfin 收藏与用户媒体 API](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/UserLibraryController.cs)。本项目与 Emby、Jellyfin、Infuse、SenPlayer 无隶属关系。

## 许可证

幕汐原创源代码采用 [MIT](LICENSE)，公开 C API 头文件保留上游 ISC 声明。**这不代表包含播放运行库的完整二进制仅受 MIT 许可约束。** 当前使用的 IINA libmpv 构建启用了 GPL，FFmpeg 及其他依赖还各有自己的许可。

含播放运行库的完整二进制按 **GPL-3.0-or-later** 分发，幕汐原创源码仍提供 MIT 许可。每个 Release 同时提供该提交的幕汐源码、固定版本的运行库对应源码（含补丁、构建脚本、递归子模块）及 SHA-256 清单；APP 内附第三方许可文本。发布运行库锁定到 IINA 官方依赖发行资产，不将任意本机运行库冒充为对应源码版本。参见 [运行库与发布说明](docs/mpv-runtime.md) 和 [第三方材料说明](ThirdParty/iina-1.5.0/README.md)。

欢迎通过 Issue 提交服务器版本、媒体编码、复现步骤及脱敏后的错误信息；不要上传密码或含 `api_key` 的播放地址。

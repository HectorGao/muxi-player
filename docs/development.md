# 开发与验证

需要 macOS 14+、Swift 6 工具链、Python 3.9+ 和 libmpv；视频测试另需支持 libass 的 FFmpeg。

```sh
git clone https://github.com/HectorGao/muxi-player.git
cd muxi-player
# 未安装 IINA 时可使用 brew install mpv
./script/build_and_run.sh --build-only
./script/test.sh
```

构建产物为 `dist/MuxiPlayer.app`。默认优先使用 IINA 运行库，再查找 Homebrew；可通过 `MUXI_MPV_LIB_DIR` 指定目录。分发时固定运行库版本并附对应源码，见 [运行库与发布说明](mpv-runtime.md)。

本机集成测试使用 loopback 协议替身，不代表真实服务器验收：

```sh
python3 script/smoke_server.py --ffmpeg /path/to/ffmpeg
# 在另一终端
./script/check_library.sh
./script/check_playback.sh
bash script/check_online.sh
```

多源持久化测试需再启动第二个替身 `python3 script/smoke_server.py --port 18797 --ffmpeg /path/to/ffmpeg`，然后运行 `bash script/check_sources.sh`。测试使用独立钥匙串 service 和偏好域，不读取用户媒体源。

增量索引检查：`./script/check_index.sh`，验证磁盘复用、变化合并、删除核对、离线保留与账号隔离。索引只保存元数据，不保存令牌或媒体地址。按源 / 账号 / 分类隔离；5 分钟内复用缓存，随后使用 Emby / Jellyfin 的 `MinDateLastSaved` 与 `MinDateLastSavedForUser` 增量查询，每天或手动同步时读取轻量成员列表核对删除。服务端不支持这些参数时保留旧索引并提示错误，用户可重建；不要把不完整分页写成完整索引。

## 在线片源与评分

`OnlineCatalogClient` 对接苹果 CMS 与 Internet Archive，返回统一条目和线路。在线缓存按源、地址与关键词隔离，首次读取后复用，支持小时 / 发布时间窗口，并定期重读已缓存页核对变更。接口列表与地址写入独立钥匙串账户，媒体流 URL 只在播放时获取。

`MovieRatings` 按提供方 ID，或唯一的片名与年份匹配评分，IMDb 与豆瓣分别保存成功 / 缺失 / 失败缓存，兼容旧单评分缓存。豆瓣使用公开摘要与建议接口，IMDb 已知 ID 每批最多 100 个查询。排序使用已识别和已缓存的评分，卡片查询补充未知条目后会重新排序。`MovieCharts` 验证完整 250 个唯一名次后更新磁盘缓存，失效保留旧榜单。IMDb 第三方快照的日期与过期标志展示在界面。采集源排序与榜单筛选仅覆盖已加载内容。

`bash script/check_online.sh --live` 额外访问公开片库、读取媒体 Range 和查询 IMDb 评分。普通替身测试不依赖外部服务。

## 自动更新发布

Sparkle 2.10.1 由 SwiftPM 固定下载。签名密钥位于本机登录钥匙串的 `com.hectorgao.muxi-player.updates` 账户，仓库只含 `Resources/UpdatePublicKey.txt`；不得导出或提交私钥。安装包在解压前验证 Ed25519 签名。自动下载后等待应用退出安装；保留应用原有进度上报流程。

每次发布先提交代码、构建并核对全部 Release 附件，再运行：

```sh
./script/publish_appcast.sh VERSION dist/vVERSION/release/MuxiPlayer-VERSION-macOS-arm64.zip
```

检查生成的 `appcast.xml` 中版本、URL、长度及签名，确认公开下载成功后单独提交更新源。`SUFeedURL` 指向主分支的原始 `appcast.xml`。CI 没有签名密钥，仅构建、测试和打包，不能自动发布未经签名的更新源。后续版本沿用此钥匙串密钥并单调递增 CFBundleVersion；丢失私钥会影响 ad-hoc 版本的更新链路，需妥善备份登录钥匙串。历史 alpha.5 及更早版本需要手动安装一次。

更新设置与签名流程依据 [Sparkle 官方文档](https://sparkle-project.org/documentation/)，增量参数依据 [Emby Items API](https://dev.emby.media/reference/RestAPI/ItemsService/getItems.html) 与 [Jellyfin OpenAPI](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json)。

- `Sources/MuxiCore`：协议模型、请求、播放协商与地址安全。
- `Sources/MuxiPlayer`：SwiftUI 界面、多源保存、媒体库、libmpv 生命周期。
- `Tests/MuxiCoreTests`：协议与模型测试。
- `script`：构建、打包、协议替身与集成检查。

本地脚本可检查请求、分页、收藏、轨道、续播与停止取流；原生渲染、真实服务器、平台兼容性需单独验证。历史证据及边界见 [验证记录](validation.md)。真实 Jellyfin、Intel 与 Windows 尚未完成原生验收。

登录令牌只写入 macOS 钥匙串，不进入偏好设置或源码。旧单连接在首次可读取时迁移到多源记录；拒绝访问或损坏时保留原数据，不写空记录覆盖。macOS 更新签名后可能重新询问访问权限，按系统提示授权即可，无需重新填写服务器账号。相关行为见 [Apple 钥匙串访问说明](https://support.apple.com/en-gb/guide/mac-help/kychn002/26/mac/26) 与 [Apple SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))。

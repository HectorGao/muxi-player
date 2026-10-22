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
```

多源持久化测试需再启动第二个替身 `python3 script/smoke_server.py --port 18797 --ffmpeg /path/to/ffmpeg`，然后运行 `bash script/check_sources.sh`。测试使用独立钥匙串 service 和偏好域，不读取用户媒体源。

- `Sources/MuxiCore`：协议模型、请求、播放协商与地址安全。
- `Sources/MuxiPlayer`：SwiftUI 界面、多源保存、媒体库、libmpv 生命周期。
- `Tests/MuxiCoreTests`：协议与模型测试。
- `script`：构建、打包、协议替身与集成检查。

本地脚本可检查请求、分页、收藏、轨道、续播与停止取流；原生渲染、真实服务器、平台兼容性需单独验证。历史证据及边界见 [验证记录](validation.md)。真实 Jellyfin、Intel 与 Windows 尚未完成原生验收。

登录令牌只写入 macOS 钥匙串，不进入偏好设置或源码。旧单连接在首次可读取时迁移到多源记录；拒绝访问或损坏时保留原数据，不写空记录覆盖。macOS 更新签名后可能重新询问访问权限，按系统提示授权即可，无需重新填写服务器账号。相关行为见 [Apple 钥匙串访问说明](https://support.apple.com/en-gb/guide/mac-help/kychn002/26/mac/26) 与 [Apple SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))。

# 幕汐的 libmpv 运行时

幕汐通过 `CMPV` C 模块调用 libmpv，并在自己的 AppKit 视图中渲染画面。
它不会启动 IINA 窗口，也不会读取 IINA 的设置、插件、媒体历史或账号数据。

## 本地构建

需要 macOS 14+、Swift 6 工具链和可用的 libmpv 动态库。运行库按以下顺序选择：

1. 显式环境变量 `MUXI_MPV_LIB_DIR`。
2. `/Applications/IINA.app/Contents/Frameworks`。
3. `/opt/homebrew/lib`，然后 `/usr/local/lib`。

目录中必须有 `libmpv.2.dylib` 或 `libmpv.dylib`。显式指定的目录不存在或不含
libmpv 时构建会报错，不会默默换用其他来源。自备运行库示例：

```sh
MUXI_MPV_LIB_DIR=/path/to/mpv/lib swift build
MUXI_MPV_LIB_DIR=/path/to/mpv/lib ./script/build_and_run.sh --build-only
```

直接 `swift build` 的可执行文件使用开发运行库 rpath。
`script/build_and_run.sh` 先统一选择运行库并导出该环境变量，再构建、打包和签名。
默认使用 release 构建；`--debug` 使用 debug 构建。原有无参数运行和
`--build-only` 入口保持可用。
没有设置全局 `DYLD_LIBRARY_PATH`；这样可以避免错误加载其他应用附带的 Swift
兼容运行库。库目录只来自显式环境或上述固定位置，不从工作目录搜索可执行代码。

```sh
python3 script/bundle_mpv_runtime.py --print-lib-dir
python3 script/bundle_mpv_runtime.py --inspect-only
```

## 已验证的开发来源

2026-10-22 在本机安装的 IINA 上检查得到：

| 项目 | 版本或位置 |
| --- | --- |
| IINA | 1.5.0，build 180 |
| libmpv | `/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib` |
| mpv / Client API | v0.41.0 / 2.5 |
| FFmpeg | 9.0.1 |
| 架构 | arm64 + x86_64 |
| 依赖闭包 | 44 个 dylib，包含 libmpv 本身 |
| 构建许可特征 | 启用了 `gpl` |

在独立进程中，不打开媒体、禁用用户配置和脚本后，`mpv_initialize()` 返回成功。
这项验证只证明该运行库能初始化，不代表所有格式、HDR 输出或网络源已通过播放测试。
Homebrew 或自建来源可能有不同版本和依赖数量，应以实际检查结果为准。

`Sources/CMPV/include/mpv/` 中只保存上游 v0.41.0 的公开 C API 头文件，来源及
SHA-256 见 `Sources/CMPV/VENDORED.md`。运行库至少应提供这些调用所需的兼容 API；
实际播放控制器仍需在运行时检查初始化和命令返回值。

## 本地 app 打包行为

`script/bundle_mpv_runtime.py` 使用 `otool` 递归检查 libmpv 的非系统依赖，
只复制这一依赖闭包到 `MuxiPlayer.app/Contents/Frameworks`，保留全部已有架构。
它不复制 IINA 本身、Sparkle、yt-dlp、插件或 `libswift*`。

复制后，将库的标识改为 `@rpath/<name>`，库之间的引用改为
`@loader_path/<name>`，主程序引用改为 `@rpath/libmpv.2.dylib`（或实际安装名）。
主程序保留 `@executable_path/../Frameworks`，移除所选开发库目录的 rpath。
每个修改后的库单独进行 ad-hoc 签名及校验，随后由构建脚本签名和校验整个 app。
原始 IINA/Homebrew 库不会被修改。

脚本不删除文件；如果输出 Frameworks 中存在本次闭包以外的 dylib，会报错，
要求先保留或移走旧 app 再构建，避免把历史依赖混入新包。

app 的 `Contents/Resources/ThirdParty/mpv/` 保存运行库清单、原始及打包后
SHA-256、依赖关系、来源版本、mpv 许可文本和本文。该清单不含媒体 URL、
用户名、密码、访问令牌或开发者 home 目录。

## 固定发布运行库与对应源码

公开预览包固定使用 IINA 官方
[`iina-1.5.0-release`](https://github.com/iina/deps-buildscripts/releases/tag/iina-1.5.0-release)
中的 `iina-deps-fat.zip`，SHA-256 为
`d6b3bb920f14780ec9c9df22e323e2bf72a5ca2b198473c67bf37581f0a60b6e`。
该 tag 对应依赖构建提交 `f86d54276547df6d14104583ea604af67433f1e1`，
包含 mpv 0.41.0、FFmpeg 9.0.1 及完整的 44 库闭包；所有库的 Mach-O
最低系统版本均为 macOS 11.0，幕汐本身仍要求 macOS 14.0。
当前只发布并验证 Apple Silicon 主程序，不宣称支持尚未验证的 Intel app。

本机 IINA 1.5.0 中的 libmpv 与该官方依赖发布物并非逐字节相同，不能混用
两者的对应源码声明。发布构建必须显式选择已校验的官方运行库，不能退回
Homebrew 或本机 IINA；本地开发仍可使用前述自动选择方式。

```sh
python3 script/prepare_release_runtime.py
```

脚本读取 `ThirdParty/iina-1.5.0/runtime-lock.json`，校验官方库归档与构建脚本，
收集 28 个带 SHA-256 的源码归档、libjxl/libplacebo 完整源码及 16 个递归子模块，
保存全部原始版权/许可文本、补丁、构建参数及源码清单。Brotli 等依赖随其
固定子模块一起提供。收集过程不执行上游构建脚本，不删除文件，不读取客户端
设置或账号信息。输出位于 `.local/release-materials/`，不提交二进制或大源码包到 Git。

大约 211 MiB 的 `iina-dependencies-source.tar.gz` 是实际源码附件，不只是下载
链接或书面承诺。归档还包括上游构建工具要求和配置；Apple 系统 SDK、编译器
以及通用构建工具作为环境前提说明，不随运行库复制。尚未声称可生成字节一致
的上游二进制。完整说明见 `ThirdParty/iina-1.5.0/README.md`。

## 版本化 APP 与 GitHub 产物

先提交审查后的源码，再生成最终 app，确保源码附件与 app 内记录的提交一致：

```sh
MUXI_MPV_LIB_DIR="$PWD/.local/release-materials/runtime" \
  ./script/build_and_run.sh --build-only \
  --version 0.1.0-alpha.1 --build-number 1 \
  --output "$PWD/dist/v0.1.0-alpha.1/MuxiPlayer.app"

# 完成这一个 app 的原生播放/窗口验证后，再打包同一个 app。
python3 script/package_release.py --version 0.1.0-alpha.1 \
  --app-bundle dist/v0.1.0-alpha.1/MuxiPlayer.app \
  --output dist/v0.1.0-alpha.1/release
```

版本字符串写入 `MuxiReleaseVersion`；`CFBundleShortVersionString` 使用其数字
部分，`CFBundleVersion` 使用正整数构建号。打包器拒绝未提交源码、提交不匹配、
运行库/源码哈希不匹配、非 arm64 主程序或非空输出目录，不覆盖以前的发布物。
它输出六个应一起上传的文件：

- `MuxiPlayer-<version>-macOS-arm64.dmg`，包含 `muxi.app`、Applications 快捷入口及安装说明。
- `MuxiPlayer-<version>-macOS-arm64.zip`，包含同一份已经验证的 app。
- `MuxiPlayer-<version>-source.tar.gz`，由该提交的 `git archive` 导出。
- `MuxiPlayer-<version>-dependencies-source.tar.gz`，完整对应依赖源码。
- `release-manifest.json`，版本、架构、提交和运行库来源。
- `SHA256SUMS`，以上五个附件的校验值。

`.github/workflows/swift.yml` 在每次 push/PR 测试、构建并保留这六个文件的
Actions artifact；推送 `v*` tag 时创建预发布。已有 Release 一律保持原样，
不会替换本地原生测试过的 APP。远程 CI 是否成功应以该次 Actions 结果为准。

## 开源许可和签名边界

当前 IINA 运行库是启用 GPL 功能的构建。公开 C API 头文件采用 ISC，不能据此
把完整 libmpv/FFmpeg 依赖闭包声明成 ISC 或 MIT。幕汐原有代码的 MIT 许可不替代
第三方库的许可义务；包含 GPL 库的整体发布物应满足实际组合所适用的要求。

当前组合二进制按 **GPL-3.0-or-later** 分发，兼容 mpv、FFmpeg、Rubber Band
的 GPL-2.0-or-later 以及 Highway 等 Apache-2.0 组件；各独立组件保留原许可。
APP 内保存完整 GPLv3、原始依赖许可/版权文本和来源清单；项目源码仍保留 MIT。
每个二进制发布必须同时公开对应项目源码和完整依赖源码，不能仅附 mpv 许可证。

预览版仅使用 ad-hoc 签名，**未经 Apple 公证**，不等同于 Developer ID 签名
发行。下载到其他 Mac 后可能触发 Gatekeeper；界面与发布说明必须如实标明，
不自动关闭系统安全设置。公证不是生成这个预览包的前置条件。
本机播放验证也不等于已经完成干净机器或所有 macOS 版本上的兼容性验证。

若选择 LGPL 构建，需要重新核验 mpv 和所有链接库；仅添加 `-Dgpl=false`
不自动证明整个依赖组合符合 LGPL。无需复制 IINA 的 UI 源代码来使用 libmpv。

固定材料中的 `versions.env` 提供源码版本与校验值，`fix-install-names.sh`、
`lipo.sh` 和 `copy-headers.sh` 分别处理动态库路径、通用架构及头文件。
不要不经审查直接运行 IINA 应用的下载脚本；它还会下载本项目不需要的插件和 yt-dlp。

官方参考：

- [mpv 许可说明](https://github.com/mpv-player/mpv/blob/v0.41.0/Copyright)
- [libmpv 公开 API](https://github.com/mpv-player/mpv/tree/v0.41.0/include/mpv)
- [嵌入方式和 Render API](https://github.com/mpv-player/mpv-examples/blob/master/libmpv/README.md)
- [IINA 构建说明](https://github.com/iina/iina#building)
- [IINA 官方依赖构建脚本](https://github.com/iina/deps-buildscripts)

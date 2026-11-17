# 社区源测试记录

测试于 2026-11-15，使用本机实际网络与名为 MuxiPlayer 的原生请求程序。检查目录、中文搜索、影片详情、HLS 清单及视频分片。加入默认列表的七个源还通过应用所用 libmpv 的短时解码，识别到 H.264 视频和 AAC 音轨，播放位置超过 0.5 秒。

每源抽样一部《肖申克的救赎》。失败源另抽近期内容复测。记录代表本次抽样，整库影片、长片连续播放与其他网络的可用性仍取决于源站。

## 加入默认列表

| 社区源 | API | 本次结果 |
| --- | --- | --- |
| 360 | <https://360zy.com/api.php/provide/vod/> | 目录、搜索、分片、解码通过。服务商新域名 `360zyzz.com` 也返回同一片库，合并为一个默认源 |
| 红牛 | <https://www.hongniuzy2.com/api.php/provide/vod/> | 目录、搜索、分片、解码通过 |
| 极速 | <https://jszyapi.com/api.php/provide/vod/> | 目录、搜索、分片、解码通过 |
| 光速 | <https://api.guangsuapi.com/api.php/provide/vod/> | 目录、搜索、分片、解码通过 |
| 无尽 | <https://api.wujinapi.com/api.php/provide/vod/> | 目录、搜索、分片、解码通过 |
| 虎牙 | <https://www.huyaapi.com/api.php/provide/vod/> | 目录、搜索、分片、解码通过 |
| 火狐 | <https://hhzyapi.com/api.php/provide/vod/> | 目录、搜索、分片、解码通过 |

升级会补充这些默认接口。已保存的同地址接口、名称和关闭状态予以保留。在“管理媒体源”中可关闭任一默认源。

## 暂缓内置的接口

| 社区源 | API | 本次结果 |
| --- | --- | --- |
| 量子 | <https://cj.lziapi.com/api.php/provide/vod/> | 目录、搜索和详情可读，两轮抽样 HLS 均返回 404 |
| 飞速 | <https://www.feisuzyapi.com/api.php/provide/vod/> | TLS 连接失败 |
| 非凡 | <https://cj.ffzyapi.com/api.php/provide/vod/> | 目录、搜索和详情可读，两轮抽样媒体返回 403 |
| 暴风 | <https://bfzyapi.com/api.php/provide/vod/> | 目录、搜索和详情可读，两轮抽样 HLS 均返回 404 |
| 百度云 | <https://api.apibdzy.com/api.php/provide/vod/> | 目录、搜索和详情可读，两轮抽样媒体返回 403 |
| 索尼 | <https://suoniapi.com/api.php/provide/vod/> | 目录可读，搜索返回“暂不支持搜索”纯文本 |
| 闪电 | <https://sdzyapi.com/api.php/provide/vod/> | 目录可读，搜索返回“暂不支持搜索”纯文本 |
| 卧龙 | <https://collect.wolongzy.cc/api.php/provide/vod/> | TLS 连接失败 |
| ikun | <https://ikunzyapi.com/api.php/provide/vod/> | TLS 连接失败 |
| 天空 | <https://api.tiankongapi.com/api.php/provide/vod/> | 目录请求出现重定向错误 |
| U酷 | <https://api.ukuapi.com/api.php/provide/vod/> | TLS 连接失败 |

## 接口线索

API 线索来自社区源列表与服务商帮助页，实际结果由上述独立测试确定。[社区接口列表](https://github.com/cms-player/vod-source/blob/main/source.json)、[360 官网](https://360zy.com/)、[量子帮助](https://lzizy.net/index.php/help.html)、[红牛帮助](https://hongniuzy.com/index.php/help)、[暴风帮助](https://bfzy.tv/index.php/help.html)。

## 2026-11-17 观影站点核查

网站线索来自用户指定的 Jeffern 项目及作者后续的 Joyflix 站点配置，LibreTV 演示地址来自当前项目 README。本次新增独立 WebKit 入口，并复用现有七个 CMS 源进行聚合浏览。实现使用平台 API 与幕汐自身代码。[Jeffern 参考项目](https://github.com/King-JH484/LibreTV-MoonTV-Mac-Objective-C)、[Joyflix 当前站点配置](https://github.com/jeffernn/Joyflix-Mac-Objective-C/blob/main/Joyflix/Home/HLHomeViewController.m)、[LibreTV 项目](https://github.com/LibreSpark/LibreTV)、[用户提供的接口讨论](https://github.com/LibreSpark/LibreTV/discussions/652)。

| 内置入口 | 地址 | 本次核查 |
| --- | --- | --- |
| 可可影视 | <https://www.kkys20.com/> | HTTP 200，影视主页 |
| OmoFun | <https://omofun.in/> | HTTP 200，动漫主页 |
| 注视影视 | <https://gaze.red/> | HTTP 200，影视主页 |
| 爱迪影视 | <https://adys.tv/> | HTTP 200，影视主页 |
| CCTV 直播 | <https://tv.cctv.com/live/> | HTTP 200，直播主页 |
| LibreTV 演示站 | <https://tv.bagiinlink.eu.org/> | HTTP 502，保留项目公布的入口并显示实时状态 |
| 鹿院 Emby | <https://dongman.theluyuan.com/> | `System/Info/Public` 返回有效服务器 ID 与版本，登录资格以站方为准 |
| Jellyfin 官方演示 | <https://demo.jellyfin.org/stable/> | `System/Info/Public` 返回有效服务器 ID 与版本，供测试媒体演示 |

HTTP 检查覆盖网页与公共接口，逐片和长片播放仍需分别验证。旧参考中的 `omofun2.xyz` 返回加载占位页，`jagcys.com` 返回停放内容，部分旧域名返回 404、TLS 错误或超时。网络列表中的 `emby.plusmedia.site` 返回 HTML 停放页，Xeton 两个接口超时。默认入口采用上述已核对地址。

同日使用名为 `MuxiPlayer` 的原生检测进程复测全部 17 个观影 / 接口入口，13 个在线，可可、爱迪和红牛出现连接超时，LibreTV 演示站返回 HTTP 502。普通检测进程可读取上述三个入口，进程与网络路径会影响结果。界面保留逐站状态，自动优选依据当次本机检测。既有播放源直连分流继续沿用。

公益服指北、终点站公告、LibreTV 和 Jeffern / Joyflix 项目页列入资讯区，作为开通条件与地址变更的查阅入口。参考项目 README 记录过内置 Emby 因滥用停用，公益服的开放状态以运营方当前公告为准。[公益服指北](https://wiki.freeembyguide.eu.org/)、[终点站公告](https://t.me/s/embypub)。

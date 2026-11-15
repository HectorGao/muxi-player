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

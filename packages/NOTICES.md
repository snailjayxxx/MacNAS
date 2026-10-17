# 内置下载器来源

两者是独立上游软件，MacNAS 保留其原始应用资源、签名及许可说明。固定包信息与官方校验来源见 downloaders.json。当前未修改上游应用二进制。

|组件|固定 macOS 版本|官方获取与校验|许可与对应版本源码|
|---|---|---|---|
|qBittorrent|5.2.3|https://www.qbittorrent.org/download|https://github.com/qbittorrent/qBittorrent/tree/release-5.2.3|
|Transmission|4.1.3|https://transmissionbt.com/download|https://github.com/transmission/transmission/tree/4.1.3|

qBittorrent 官方 COPYING 区分源代码 GPLv2+ 与二进制 GPLv3+，并附 OpenSSL 例外；Transmission 官方 COPYING 允许其列出的 GPLv2/GPLv3 等许可，并附 OpenSSL 例外。具体文本和各组件版权以对应版本的原始许可为准。

当前为本机开发包准备与隔离安装。正式对外分发应同时提供发行物中相应版本及其依赖的完整来源和许可资料；当前文档链接与原始应用资源不代表正式发行供应包已经完成。

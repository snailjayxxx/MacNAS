# 内置下载器与安装工具契约

qBittorrent 与 Transmission 随 MacNAS 默认提供，均可移除和重新安装。这里的“系统内置”指 MacNAS 发行物；两者仍是各自上游维护的独立原生应用。

- 两个包保持独立状态，可同时安装或卸载；重新打开工具不能恢复用户已移除的包。
- 卸载保留下载文件、配置、任务恢复资料和离线归档。不提供清空数据或连同下载删除的选项。
- 不启动应用、不自动运行 BT 任务、不配置 launchd、系统账户、共享、网络或公网端口。
- 目标是 Apple Silicon / macOS15+。官方 Universal 包中的 x86_64 切片不是本项目恢复 Intel 支持的声明。

## 原生打包与生命周期

使用现有 Python 3 标准库运行。例中的目录均由本工具专用，不是系统 `/Applications`、家庭资料或生产 NAS 路径。

```sh
/usr/bin/python3 scripts/manage_downloaders.py --root ../DeploySandbox/downloaders fetch-cache --cache ../Build/downloader-cache
/usr/bin/python3 scripts/manage_downloaders.py --root ../DeploySandbox/downloaders init --cache ../Build/downloader-cache
/usr/bin/python3 scripts/manage_downloaders.py --root ../DeploySandbox/downloaders status
/usr/bin/python3 scripts/manage_downloaders.py --root ../DeploySandbox/downloaders uninstall qbittorrent
/usr/bin/python3 scripts/manage_downloaders.py --root ../DeploySandbox/downloaders install qbittorrent
```

`fetch-cache` 仅从版本化目录中的两个官方地址取归档，重定向限定 HTTPS 及官方分发域；每个归档最多 200MiB、下载总时限 300 秒，完整摘要不符不发布。已有缓存不匹配时拒绝覆盖。正常安装和重装只读取离线缓存，并再次校验完整摘要。

`init` 只接受尚不存在的目标目录。先在同父目录准备完整发行物，验证两份归档和两个应用，再发布目录。读写命令要求已有正确收据、目录和进程锁，不把任意既有目录接管成应用根。

```text
<owned-root>/
  .package-lock
  catalog.json
  receipt.json
  NOTICE.txt
  installed/qbittorrent/qbittorrent.app
  installed/transmission/Transmission.app
  offline-cache/<两份固定版本的 DMG>
  data/qbittorrent/
  data/transmission/
  work/
```

安装器拒绝符号链接祖先、缓存链接/硬链接、bundle 外逃链接、包身份或架构不符、签名损坏；不去除 quarantine 或替应用重签名。只读 DMG 检查在私有临时目录进行，成功后卸载虚拟映像。已发布目录不包含挂载点。

卸载仅移除 `installed/<已知包ID>`，缓存与 data 不受影响，其他下载目标也不作为卸载输入。应用文件被打开时拒绝操作，不杀应用。未预期的同级用户内容会阻止卸载。需要先关闭运行中的下载器。状态不一致显示 needsRepair；没有自动重放或永久数据清理。当前工具不支持跨版本升级/回退、生产会话授权或抵御同一 OS 用户恶意修改。

## 网页

`downloaders.js` 只接受显式 fixture API，不接受 host 回退。默认登记两个包；跨演示身份保留本次页面会话的卸载状态。页面刷新仍建立新的合成环境，这不是原生持久收据。每次写动作重新检查当前角色和模式；会话结束或视图关闭时拒绝迟到操作，旧视图不关闭其他借用者的会话。

套件中心展示包名、说明、固定版本、内置/可移除和当前状态；已安装提供卸载，未安装提供安装。卸载对话框明确包名和数据保留；取消不改变状态。读者及恢复模式禁用动作。所有动态文本走 textContent，中文和日文均提供完整文案。

生产网页到实际安装器的认证消息、后台下载器进程管理、独立工作目录、BT/磁力链接任务和 WebUI 入口尚未接入。现有可信自研样例注册器与数据库角色边界保留。

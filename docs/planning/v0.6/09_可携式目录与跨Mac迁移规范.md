# 09｜MIG-05：可携式单目录与跨 Mac 一键迁移规范 v0.6

**用户新需求，首版强制目标**：通过复制/打包一个实例文件夹，在另一台 Apple Silicon Mac（最低目标macOS 15）安装必要的受信任环境后，安全恢复平台功能和设置，保留所有可迁移应用及数据。跨主机的系统授权/服务/密码要求正规重建，不能被“无缝”措辞掩盖。

## A. 范围定义：三个世界不混淆
1. **开发工作区 MacNAS-Dev**：当前500GB外置SSD仅作为Codex开发环境；源码、Build、模拟磁盘和测试数据与正式运行实例隔离。它不是生产路径约束，也不等同于可迁移部署包。
2. **Portable Instance Root（可迁移文件夹）**：配置、逻辑用户与角色、应用安装包及其状态、索引与必要任务检查点、文件/卷引用、导出工具与schema版本。用户将它完整复制到新Mac任意位置，由Bootstrap安装/恢复。
3. **真实NAS文件（可能30TB以上）**：通常留在独立HDD/SSD存储池上。仅迁移Portable Root不能拷贝这部分数据，必须原柜换机安全重连、额外完整复制或从独立备份恢复。用户选择“包含原始用户数据”的全量迁移时，另给明确容量和目的地预算。

## B. 单实例目录建议结构（允许ADR微调）
```text
MacNAS-Instance/
  instance.json              # schema版本、实例UUID与导出元数据（非本机唯一标识）
  manifest.json              # 文件清单、hash、数据一致性、版本兼容区间
  portable-installer/        # 受信任安装/恢复器与签名发布组件，可检查后再安装
  config/                    # 仅跨机可携配置、角色、策略、计划任务
  state/                     # 平台事务数据库、一致性任务检查点
  apps/                      # 已安装自研可信套件包及其签名清单
  app-data/                  # 套件私有数据与schema版本
  logical-storage/           # 外部volume/library/pool逻辑ID/原路径提示/校验信息
  migrations/                # 已执行schema版本与迁移journal
  optional-cache/            # 可选缓存（缺少时可自动重建）
  restore/                   # 最后一份一致性导出结果、校验/恢复报告（敏感数据保护）
```
**严格不带入**：macOS系统账号、系统LaunchDaemon注册、旧机TCC数据库、Keychain明文、证书私钥明文、开发DerivedData缓存、正式用户大数据（默认）。可携实例的内容及包含/排除清单必须给用户一眼可查。

## C. 统一路径/资源/数据模式
- 跨机持久对象只引用`instance_root`派生路径、`library_id`、`volume_id`、`plugin_id`、`storage_pool_id`、相对路径。禁止硬编码`/Volumes/MacNAS-Dev`、username、UID、主机名、IP、绝对路径作为唯一业务身份。
- 分离`portable-config`（机器无关）与`host-binding`（每台机器独立）；新机读取旧机器绑定只能给出提示，不当作授权。
- `host-binding`保存卷身份、文件系统、容量/设备信息、物理成员、SMB账户映射候选、已授权访问状态、系统服务状态、监听端口占用、证书来源等；任何失配显示原因，不猜测对应盘。
- 盘不在时所有关联写入任务进入`waiting_for_volume`，使用空目录或同名卷不得自动续写。
- 文件相似索引、缩略图、媒体缓存可不纳入精简导出，恢复时明确将其标为待重建；应用数据库和手工标签等不可重建数据必须纳入。
- 插件必须提供`exportState/importState/schemaVersion/migrate`扩展契约，不能把数据藏在用户主目录、`/usr/local`或硬编码路径。

## D. 两种迁移模式
**M1 标准迁移（推荐）**：先在旧Mac从Web/CLI运行“迁移预检查”→暂停新写入/等事务完成→对平台和插件数据库作一致性导出→输出`MacNAS-Instance/`文件夹或归档→完整性校验→复制到新Mac→新Mac环境/安装器验证→权限、系统服务与卷重新绑定→只读巡检→用户确认后正式切换→旧主机停止/旧令牌撤销。不能把正在被写入的数据库直接压缩并当作成功。

**M2 灾难恢复**：旧Mac损坏时，使用最近的有效实例备份及独立用户数据备份，在新Mac只读验包、发现缺失卷/密钥/数据库版本、向导显示“可恢复/待人工/不可恢复”列表；禁止静默丢弃应用数据或权限而宣称成功。

**M3 同机搬目录/换SSD**：实例根目录改名或更换挂载位置时，平台通过实例根重定位和重绑定恢复；不要求重建所有照片缩略图与手动标签，不重新安装每个插件。

## E. 密钥/账户/系统授权
- 基础登录用户、组、应用授权策略可以迁移，但系统SMB用户UID/GID和密码不可假设一致，新机必须映射并做真实权限测试。用户Web登录token/session宜强制失效/重签（具体由安全ADR决定）。
- Keychain项目需要根据应用签名、账户/Keychain作用域重新访问；对于迁移所需秘密，优先用户重新输入/重新连接第三方账号。仅在单独授权的情况下允许加密secret导出；禁止明文打包、日志输出或上传云端。
- 新Mac上的ServiceManagement登录项/LaunchDaemons/Privileged Helper必须从受信任签名安装器按苹果正规授权重新注册。放在用户可写SSD中的程序不允许因便携需求而提升为root执行。
- TCC、沙箱资源授权、目录访问书签迁机后可能失效，使用标准GUI授权/重新选目录。不写绕过SIP/TCC的脚本。
- TLS证书、DNS、反向代理、iOS/Windows同步端点修改须用户确认；不得在测试迁移时自动修改公网生产入口。

## F. 双机切换与防双主
- 迁出前产生包含源实例ID、逻辑部署generation、导出时间及所依赖卷/远端写入资源的证明；新机默认`read_only_recovery`。
- 共享存储上的锁/租约/服务端确认机制必须可在物理拔盘、重启、网络分区后可靠判断占有；普通目录锁文件只用于辅助，**不可声称具备强分布式fencing**。
- 未能证明源实例已停止且共享写入资源已由目标独占时，目标继续只读，不能开启备份/同步/共享写入/存储池重建。
- 支持从新机回滚旧机：恢复原主机独占身份、验证数据一致性和备份状态；迁移包留可重复校验的journal，不依赖Codex终端尚在打开。

## G. CLI、Web与API契约草案（名称仅供ADR决定）
- `macnas doctor --portable <path>`：验证目录、版本、签名、容量、数据库和外部依赖，**默认只读**。
- `macnas migrate preview --target <path>`：输出可转移内容、必须重建项、与外部数据关联风险，不写目标。
- `macnas migrate export --dest <path>`：一致性导出，输出完整性验证结果；必须安全处理秘密和取消/中断。
- `macnas migrate restore --source <path> --dest <path>`：默认“先检测/只读预演”，正式写入需要明确目标目录与确认。
- `macnas migrate cutover`：根据系统/设备重绑定清单由所有者确认后切换为读写；遇到不安全条件拒绝执行。
- `macnas migrate rollback`：针对已记录的事务恢复；不夸大可回滚能力。
**CLI和Web只调用同一后端迁移服务，权限检查不能靠前端按钮。**

## H. 达标验证
首版必须有：单目录转移到不同绝对路径后恢复用户/应用配置；完整性/hash校验、断点恢复、数据库事务一致性、插件版本迁移、旧机停用与新机独占写入、未找到原数据卷时不误写、密钥重授权、真实Mac跨机恢复以及撤销/回退。测试细则见`11_迁移恢复与故障注入验收.md`。没有第二台Mac时只能标“模拟完成、跨Mac真实测试未完成”。

## 官方技术核对
- [ServiceManagement](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)
- [Apple Service Management Installer样例](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
- [App Sandbox文件访问/安全作用域书签](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Disk Arbitration卷标识](https://developer.apple.com/documentation/diskarbitration/diskarbitration-constants)

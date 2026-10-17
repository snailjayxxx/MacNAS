# MacNAS

2026-10-17接续：N-030按用户新指令增加qBittorrent和Transmission两个默认内置、可卸载及离线重装的原生下载器。固定官方macOS归档/版本/SHA256、bundle身份/arm64和原签名；私有新目录默认安装两者，实际12步CLI验证分别卸载、移除选择跨进程保持、init拒绝重新插入和离线重装，5份合成配置/恢复/下载文件摘要不变。22项Python故障测试、383项Node、20语法、17静态策略和9需求负测通过；中日包中心明确为fixture；已实测隔离页面全部实际加载资产与本次主树逐字节一致，复用该12项浏览器功能记录，没有声称新的主树浏览器执行。未启动下载器/BT任务，未修改系统Applications、服务或网络。网页尚未接生产安装宿主。 旧核心94份及全部实际16内嵌/4独立依赖保持，复用已发布N-029 C3C2的471Swift/16独立管道和PG停止精确收据，本阶段没有新Swift全量。前端/预览/策略QA改动由新检查覆盖；原29规划/5来源/111父和97-13-1不变，913基线子项；SYS09仍很后期另1父7子。两轮DMG挂载/lipo参数失败及源码均保留，修复以真实包验证确认。当前Mac26.5.2私有工具结果不等于macOS15、跨Mac、生产认证或NAS发布。 见[N-030证据](docs/evidence/n030-2026-10-17.json)及[内置下载器契约](docs/contracts/BUILTIN_DOWNLOADERS.md)。
Mac上使用的NAS系统

Swift 原生核心与中文/日文静态网页桌面开发原型，数据库采用 PostgreSQL 18。桌面暂用合成数据，尚未提供可部署 NAS 服务。

文件中心已实现连续浏览、新建/改名、有界上传/下载和复制。原生回收/恢复及真实中断核对另在私有合成资料库实现；网页仍使用内存样例树。单文件16MiB是当前原型预算，完整回收恢复界面、持久大文件传输和正式NAS接入仍待后续阶段。

C3C2实际宿主账目列表已发布，C3C3A管理观察纯模型通过新的368Node检查，复核C3C2 471Swift/16管道精确基线，见[C3C3A证据](docs/evidence/n029-c3c3a-2026-10-17.json)。实际管理物理观察、执行及网页接线继续后续阶段，浏览器已获准按需使用，本切片未执行浏览器。

用户2026-10-17要求自动连续开发、按阶段中文提交推送，并暂不使用浏览器。实际工程位于外挂SSD，路径与接续步骤见[HANDOFF.md](HANDOFF.md)。Intel Mac/macOS14支持留待以后，当前Apple Silicon/macOS15+目标不变。

- [DSM整体功能差距](docs/plans/DSM-FUNCTIONAL-BASELINE.md) / [控制面板与网络详细对照](docs/plans/DSM-CONTROL-PANEL-NETWORK-REFERENCE.md)
- [用户补充需求账目](requirements/user-additions.json)：新增SYS-09网页远控Mac，按用户要求**很后期、未开始**；原111项基线不变，当前有效112项。

- [进展与真实测试结果](PROGRESS.md)
- [下一轮任务](NEXT_TASK.md)
- [工程架构](ARCHITECTURE.md) / [依赖及准入](DEPENDENCIES.md)
- [PostgreSQL 决策](docs/decisions/ADR-002-postgresql.md)
- [原始规划包（逐字节保留）](docs/planning/v0.6/CODEX_START_HERE.md)

在已验证开发 SSD 的工程根目录运行：

```sh
/usr/bin/python3 scripts/verify_requirements.py
/usr/bin/python3 scripts/build_postgresql.py
/usr/bin/python3 scripts/dev.py
```

`dev.py` 包含 Swift 构建、自动测试、独立 PostgreSQL 集群、CLI 便携快照/换路径恢复演练、合成中日英文图像探针，并最终关闭临时测试集群。所有缓存和数据留在工作区，Unix socket临时目录在结束时清理；每轮日志保留在 `../Evidence/runs/`。

工程路径：`/Volumes/MacNAS-Dev/MacNAS-Workspace/MacNAS`。用户已有的蜗光集 PostgreSQL 服务与数据不在测试范围。Swift 和 PostgreSQL 的构建最低目标为macOS15，实际运行证据仅来自当前macOS26.5.2。许可证及生产分发方式尚待确定。

N-009新增签名迁移日志、检查点恢复、PostgreSQL Schema1→2隔离升级、保留源库的回退、统一停写和无监听业务API。CLI提供 `migrate upgrade` / `status` / `rollback`；完整环境由dev.py准备。见 [ADR-003](docs/decisions/ADR-003-recoverable-migration.md) 与 [原型API](docs/contracts/PROTOTYPE_API.md)。

后续Git commit标题和说明使用中文。用户已授权每完成一个独立功能、相关测试通过且文档/证据齐全后，自动提交并推送到开发分支；main合并、强推及历史重写不在此授权内。

N-010 增加 PostgreSQL Schema 3 的持久任务、步骤检查点、租约/重试/取消和事务 outbox。标准验证入口还会演练 Schema 2→3 隔离升级、任务执行/确认、任务快照恢复及只读拒写。单独合成实例可用 `fixture create --dest PATH --schema 3`，再运行 `jobs demo --source PATH`；需要验证入口创建的私有测试数据库环境，未提供生产常驻服务。

任务 API、权限与交付语义见 [PROTOTYPE_API](docs/contracts/PROTOTYPE_API.md) 和 [ADR-004](docs/decisions/ADR-004-durable-jobs-outbox.md)。

N-011已加入[中文/日文静态桌面源码](web/dist/index.html)：窗口、任务/通知中心、合成文件和偏好。当前显式使用内存演示数据，未连接Swift/NAS；35TB仅为合成逻辑引用。浏览器视觉/交互因工具入口和权限限制待验收，见[清单](web/tests/BROWSER_ACCEPTANCE.md)。

前端检查：

```sh
/usr/bin/python3 scripts/dev_web.py
```

使用现有Node内置测试和系统Python，不安装包，此检查入口不启动监听。模型、桥接客户端和静态HTTP策略测试不能替代浏览器验收。已获授权的临时静态预览入口为scripts/preview_web.py，绑定127.0.0.1:8766；用户可手动显示页面，但随后正规删除仅该站点例外仍被工具权限层拒绝，原因未知。预览已关闭，不重复同状态请求或换通道绕过。详见[恢复记录](docs/evidence/n011-acceptance-recovery-2026-10-16.json)、[ADR-005](docs/decisions/ADR-005-static-desktop.md)及[桌面适配契约](docs/contracts/DESKTOP_API.md)。

N-012/N-013新增[合成卷绑定与只读资料库API](docs/contracts/FIXTURE_STORAGE_API.md)：UUID/介质/挂载会话检查、一次性绑定预览、掉线撤销、固定目录句柄、资料库读者范围和有界UTF-8预览。当前只用于host-binding内自建合成内容，未查询真实磁盘或连接网页。

在验证入口准备的独立测试环境中，可以运行：

```sh
macnas storage demo --source SYNTHETIC_INSTANCE
```

命令只在有效合成实例中创建新的随机fixture目录；只读恢复模式拒绝。scripts/dev.py自动演练这一流程，并检查恢复拒绝时没有创建占位目录。[范围与限制](docs/plans/N-012-013-ACCEPTANCE.md)。

N-014加入[无监听桌面消息桥接](docs/decisions/ADR-008-desktop-message-bridge.md)。在验证入口准备的合成数据库环境中，`macnas bridge fixture --source SYNTHETIC_INSTANCE --user fixture-owner`通过标准输入输出交换有界逐行JSON；10个固定方法涵盖任务、事件及已批准合成文件，不接受身份、数据库或根目录参数。scripts/dev.py会用JavaScript客户端调用独立Swift进程，检查真实PostgreSQL持久任务、权限和只读拒写。静态网页仍为演示模式，尚无生产登录或浏览器连接。

N-015加入[具名业务客户端](web/dist/bridge-client.js)：完整展示数据校验、固定宿主身份、调用超时/关闭、迟到响应丢弃和业务幂等重试。仍通过Node与CLI管道验证，未接入网页。参见[ADR-009](docs/decisions/ADR-009-typed-desktop-client.md)与[接口](docs/contracts/DESKTOP_API.md)。

N-016加入[有界任务页及统计](docs/decisions/ADR-010-bounded-job-pages.md)：固定UTF-8字节顺序、每页最多100条、60秒会话绑定的一次性游标；overview在数据库聚合，旧数组超过4096条明确拒绝。页为实时读取，不能当作一致性快照。静态网页及回家窗口验收状态保持不变。

**网页窗口尚未实测。** 用户已回到Mac mini并完成正规设置排查，工具仍拒绝内容观察。[启动步骤与W/T/N/F/FO/FT清单](web/tests/BROWSER_ACCEPTANCE.md)覆盖窗口、任务、通知、文件浏览、新建/改名及上传/下载交互，46项全部保留待测；手动看到页面及自动测试不代替功能验收。

N-017加入[当前页任务展示](docs/decisions/ADR-011-task-page-presentation.md)：每页3条、下一页/重新读取、本页搜索范围、独立统计及关闭后的迟到结果丢弃。真实客户端展示适配只通过Node/管道验证，静态页仍是fixture；[W01–W10与T01–T08](web/tests/BROWSER_ACCEPTANCE.md)全部等待回家实测。

N-018加入[有界通知展示](docs/decisions/ADR-012-bounded-notification-view.md)：最多100条已加载待确认通知，满额停止读取，确认成功后清理本批；失败保留原批/原位置供显式重试，断连不伪装确认或自动重连。名称仅查当前页/预览，静态页仍不连接数据库。回家清单新增N01–N06，窗口/任务/通知及实际DOM均待测；后续计划为[有界目录查询](docs/plans/N-019-BOUNDED-DIRECTORY-PAGES.md)。

N-019加入[有界目录页原型](docs/decisions/ADR-013-bounded-directory-pages.md)：每页最多100，单次8192项/1MiB名称/5秒扫描预算；目录变化要求重读，继续链绑定目录批准/会话并限64条、60秒。已有1000项数组仍超限拒绝，元数据按读取时返回，没有文件系统快照或生产规模承诺。N-019完成时静态文件窗口尚未接入；接续任务为[目录当前页展示](docs/plans/N-020-DIRECTORY-PAGE-PRESENTATION.md)，实际网页验收仍等回家。

N-020加入[目录当前页展示](docs/decisions/ADR-014-directory-page-presentation.md)：文件窗口每页3项，本页搜索/类型过滤、独立资料库摘要、面包屑及有界只读文本预览；目录来源借用会话，关闭文件窗口不关闭任务/通知连接，迟到结果不覆盖新目录。页面仍是固定内存演示，时间/估计未知，没有真实NAS连接。[回家清单](web/tests/BROWSER_ACCEPTANCE.md)新增F01–F08，全部待测；下一步为[通知消费位置只读核对](docs/plans/N-021-NOTIFICATION-CONSUMER-STATUS.md)。

N-021加入[通知消费位置只读查询](docs/decisions/ADR-015-read-only-event-consumer-status.md)：第13个固定方法返回当前受众的ack/delivered位置，不创建消费者或推进游标；不可见与他人占用同样返回null，恢复只读可查但仍拒绝poll/ACK。客户端只观察，不据此清除旧通知批或获得ACK权限；静态网页未接入新查询。新的完整回归与实际管道结果见[验收记录](docs/plans/N-021-ACCEPTANCE.md)，后续为[来源上下文与显式核对模型](docs/plans/N-022-NOTIFICATION-SOURCE-CONTEXT.md)。

N-022实现[可信合成管道来源上下文与显式核对](docs/decisions/ADR-016-fixture-event-source-context.md)：第14个观察消息、固定事件来源、捕获原库的事件操作，显式新客户端只读核对原批目标；不清旧批、不接管连接，也不是生产认证。N-023实现[连续浏览模型与窗口基础](docs/decisions/ADR-017-continuous-file-browser.md)，[证据](docs/evidence/n023-2026-10-16.json)分别记录模型、原生基线与网页待测。接续[N-024文件操作流程](docs/plans/N-024-FILE-OPERATIONS-WORKFLOW.md)，控制面板/网络业务按详细对照落实；SYS-09远控不提前开发。

N-024的[文件操作契约与边界](docs/decisions/ADR-018-guarded-fixture-file-operations.md)包括独立写批准、父目录/源身份复查、不覆盖发布、短期同宿主回执和结果未知时禁止重提。原生消息不接收根路径或授权指令；这两类短同步操作尚无重启后的持久结果。接续[N-025有界文件传输](docs/plans/N-025-BOUNDED-FILE-TRANSFERS.md)，仍采用PostgreSQL18，远控按用户要求留在很后期。

N-025/N-026的[传输契约](docs/decisions/ADR-019-bounded-fixture-file-transfers.md)和[验收范围](docs/plans/N-025-026-ACCEPTANCE.md)将原生实际合成文件、Node→Swift管道、网页内存与DOM结构替身、真实浏览器分开。复制、移动、回收站、共享权限及控制面板业务继续按[N-027接续](docs/plans/N-027-FILE-COPY-WORKFLOW.md)推进，不提前启用远控或系统服务。

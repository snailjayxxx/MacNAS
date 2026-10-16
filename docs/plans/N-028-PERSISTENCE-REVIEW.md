# N-028：回收记录的持久化与Schema4接续审查

日期：2026-10-16，Asia/Tokyo。本文是独立的源码审查与候选设计；第二次审查已对齐[主设计](N-028-RECYCLE-BIN-DESIGN.md)及[ADR-021](../decisions/ADR-021-recoverable-recycle-journal.md)的首版约束。**没有实现或应用Schema4，没有修改运行源码、Tests或database目录，没有运行数据库实验或全量回归。** 审查对象是当前PostgreSQL18-only、Schema1/2/3实现。Schema3既有迁移及旧源数据保持原样。

## 审查结论与保守门槛

`recycle_entries`加`file_effect_operations`两表可以表达受限单文件回收/恢复；第二张表必须是独立的文件效果协调记录，不能复用`job_steps`的“数据库事务内效果已提交”含义。PostgreSQL事务不能同时提交文件系统rename。`armed`先提交、rename后写`observed`，中间必然存在“文件已移动、数据库仍为armed”的窗口；把长事务跨过rename也不能消除该窗口。

主设计采用的更保守门槛可行：**N-029普通export、Schema4源升级、恢复候选发布要求两张新表完全为空，且vault经明确批准核对为空；允许纯Schema3→空Schema4的隔离候选升级。** 这一门槛必须在冻结下检查，且必须覆盖resume/已经存在的候选路径。不能仅在UI或第一次preflight检查一次。

首版“非空”包括任何历史，已released/restored/completed的记录也拒绝普通可携流程；这有意比仅阻断活跃payload更保守。不能为了通过门槛而删除历史。非空数据库仍可在独立隔离只读诊断流程中快照/导入并验证元数据摘要，但不作为完整可恢复包或普通restore发布成功。过了保留期仍保留记录，未明确完成恢复的payload继续计量；N-028不因此获得永久清理或审计裁剪授权。

Schema4数据库恢复只恢复这些**元数据与历史证据**。它不恢复外部回收payload，不恢复文件原位置，不恢复系统权限，也不授予旧操作继续rename的权限。旧候选库、旧pgdump和`MigrationCoordinator.rollback`不能作为文件回退工具。当前`PortableInstance.cutover()`仍明确拒绝；本设计不解除该门槛。

## 当前实现已经提供什么

| 现有代码 | 当前真实语义 | Schema4接续要保持的边界 |
| --- | --- | --- |
| `StateStore.swift:223`的`schemaVersion()` | 只认可完整迁移链1、1/2、1/2/3 | 认可4必须要求1/2/3/4完整且无额外/重复版本，不能只看最大值 |
| `StateStore.swift:227`的`validate()` | 精确比对5或10张持久表、部分列可查询、两套件列清单、事件时钟不变量 | 新表不能靠pg_dump“已经带上”而跳过验证；还须验证列型、约束、索引和状态数据不变量 |
| `StateStore.swift:257`的`migrate()` | 事务式版本迁移；目标已是当前版本时不重复DDL | 新增0004，保留0001–0003；提交后/进度日志前中断必须识别已完成4而不重插数据 |
| `StateStore.swift:277`的两类摘要 | `baseDataDigest`只含历史基础列；`contentDigest`含当前版本的已知完整数据 | base摘要不能证明Schema3任务元数据或Schema4回收记录未被篡改 |
| `WriteBarrier.swift:52` | 一个独立SQL事务对硬编码表清单持有SHARE锁，SQL写者等待，读取/pg_dump继续 | 不是文件系统冻结，不会自动阻止rename、宿主sidecar写入或另一个实例写同一vault |
| `PortableInstance.swift:172`的`export()` | 先实例独占文件锁，再SQL屏障，导出固定文件白名单与pgdump、摘要、签名后发布 | 文件效果写者必须参与同一实例锁；新表屏障与阻断检查不可缺失 |
| `MigrationCoordinator.swift:194`之后 | 单独候选库、数据库attestation、导入/迁移/封包、只读发布、可重试日志 | 不在原库就地升级；候选发布前必须再次证明符合Schema4可携门槛 |
| `MigrationCoordinator.swift:286`的`rollback()` | 将候选保持只读，记录rolledBack，保留原实例及候选 | 不撤回原宿主已发生的文件rename，不重建外部payload |

`DatabaseSnapshotBarrier.check()`只检查子进程仍存活；它不验证文件vault的一致性。外部效果写者不能用一次SQL“可写检查”替代贯穿实际rename、两父目录同步和结果提交的协作锁。

## 两张表的具体字段建议

以下是建议字段和约束面，不是可执行DDL；主设计确定名字和状态后再生成0004及对应Swift迁移常量。首轮保持单常规单链接文件、同设备、不覆盖。不要为了接入回收站扩展现有`macnas.jobs.kind`及既有两步任务语义。

### `macnas.recycle_entries`

| 字段 | 建议类型及约束 | 用途 |
| --- | --- | --- |
| `entry_id` | UUID，主键 | 整个payload生命周期的稳定逻辑ID；不得用原文件名作私有对象名 |
| `entry_version` | integer，固定1 | 记录语义版本；与数据库schema版本分开；整行规范JSON上限4KiB，详见元数据预算 |
| `instance_id`、`origin_generation` | UUID、非负bigint | 历史实例作用域；不是恢复后自动生效的授权 |
| `owner_user_utf8` | bytea，1–128字节，写入前确认有效UTF8 | 原主体原始字节；不按Unicode规范化合并两个主体 |
| `library_id_utf8`、`original_path_utf8` | bytea，分别1–128与1–4096字节 | 逻辑资料库及原相对路径；应用层严格分量校验，拒绝绝对路径、NUL、点分量、反斜线及超深路径 |
| `volume_id`、`vault_id`、`payload_id` | UUID；`(instance_id,volume_id,vault_id,payload_id)`唯一 | 卷逻辑身份、独立私有vault身份、稳定对象ID；不是任意磁盘根路径或批准token |
| `byte_count` | bigint，0至首轮单文件上限 | 声明并固定的数据字节；建议延续16MiB原型边界，最后由主设计固定 |
| `source_sha256` | 可选的64位小写十六进制摘要 | 若单独批准内容读取，可补充内容证据；摘要相同不能替代inode/父目录/来源身份或证明所有权 |
| `state` | 精确枚举：例如`planned/resident/restored/cancelled/uncertain` | `planned`不是已移动；`resident`须有完成的回收效果；`uncertain`不能当成不存在payload |
| `charge_state`、`charged_bytes` | 精确枚举`reserved/retained/released`，非负bigint | reserved或retained时恰等于`byte_count`，released时为0；预留和实际保留只记一次 |
| `created_at`、`recycled_at`、`restored_at`、`retain_until` | timestamptz；必要字段非空，阶段字段可空 | 使用UTC规范化摘要；保留截止是策略资料，不是自动删除许可 |
| `current_operation_id` | 可空UUID，指向本entry的效果操作 | 同一entry最多一个未解决操作；循环外键需明确延迟约束或同事务插入顺序 |
| `revision` | 正bigint | CAS更新；状态、预算转账与当前操作必须在同一事务推进 |

原路径不应有“仍在回收站的全局唯一”约束：用户可以重建原路径，再次回收新文件，产生另一entry；恢复时仍需单独冲突预览。`payload_id`与entry不可重用于另一份来源内容。首轮不提供任意UPDATE修改原主体、原路径、大小或payload身份的业务入口。

### `macnas.file_effect_operations`

| 字段 | 建议类型及约束 | 用途 |
| --- | --- | --- |
| `operation_id` | UUID，主键 | 一次回收或一次恢复尝试的固定ID；恢复冲突后重新预览形成新ID |
| `operation_version`、`kind` | integer固定1；`recycle/restore`精确枚举 | 不把未来purge/move混入首轮；整行规范JSON上限8KiB，详见元数据预算 |
| `entry_id` | UUID，非空外键，禁止级联删除 | 关联payload；不能删entry使未解决效果失去凭据 |
| `actor_user_utf8`、`instance_id`、`origin_generation` | 同上；必要字段非空 | 固定操作者与原实例上下文，不持久化session/批准能力 |
| `idempotency_key_utf8`、`intent_sha256` | 有界bytea；64位小写摘要 | `(instance_id,actor_user_utf8,kind,idempotency_key_utf8)`唯一；相同key仅在完整不可变intent相等时返回原操作，否则collision |
| `intent_version`、`intent` | 固定版本；闭合JSONB对象且有序列化字节上限 | 固定来源/目标逻辑库、相对父路径、单名称、entry/payload及原主体；禁止任意根路径、覆盖标志或客户端身份覆盖 |
| `origin_scope_sha256` | 64位小写摘要 | 原宿主/数据库/实例/卷挂载/批准作用域的等值历史标记；新宿主不可凭旧值继续执行 |
| `source_stamp`、`source_parent_stamp`、`target_parent_stamp` | 有版本、闭合字段、大小受限的JSONB | 捕获原设备/inode、类型/权限/UID/链接数、大小/mtime/ctime及父描述符身份；只作历史变化证据 |
| `phase` | `prepared/armed/observed/completed/uncertain/cancelled`等精确枚举 | 枚举必须与主状态机完全一致，不能用自由文字或通用job.state暗示效果 |
| `revision` | 正bigint | 同阶段推进也要有CAS，禁止两个同ID工作者各自执行rename |
| `prepared_at/armed_at/observed_at/completed_at` | timestamptz，阶段配套可空约束 | `armed`提交已被确认是允许尝试rename的必要条件；“提交回复不明”不能当作已armed |
| `post_stamp`、`source_parent_post_stamp`、`target_parent_post_stamp` | 可空的版本化JSONB | `observed`之后必须有捕获对象身份的证据；rename引起的预期ctime变化与原地改写需分开判断 |
| `source_parent_synced_at`、`target_parent_synced_at` | 可空timestamptz | completed须两父目录同步已返回并且后核对通过；同一父目录也需有明确处理规则 |
| `error_code` | 可空的封闭错误枚举 | uncertain必须有固定错误或固定恢复原因，不存主机路径/堆栈/秘密 |
| `reconciliation_version`、`reconciliation`、`last_observed_at` | 可空、有界闭合JSONB及时间 | 只读分类结果；不能靠写入分类把armed自动提升为已拥有payload或completed |

`intent`和各stamp是为说明字段分组；若主设计选择展开列，仍要覆盖这些信息。操作的intent、actor、来源/目标身份以及幂等键在prepared后不变，后续只更新阶段、核对证据和修订。不可变性必须由受限写入路径/CAS并辅以可检查的约束实现，不能仅靠DTO说明文字。

设备号/inode可能来自无符号原生类型，不要直接塞进有符号PostgreSQL bigint或JavaScript Number。可用受范围约束的decimal字符串或`numeric(20,0)`保存，向JS输出仍保持精确字符串；纳秒为0至999999999。stamp中的宿主路径、打开FD、批准UUID及真实token不进入可携业务记录。其历史身份在换挂载/换主机后不能直接用于写入。

### 共同约束、配额和索引

- 两表都用明确的PK/FK、NOT NULL、字段字节上限、状态枚举和阶段相关CHECK；phase到达observed/completed而poststamp缺失、completed而两父fsync证据缺失、released但仍resident等组合必须拒绝。跨表不变量由同事务更新和显式验证承担，普通CHECK不能引用另一表证明文件已存在。
- `prepared`与entry的reserved计量同事务提交；`armed`的提交得到明确确认后才允许文件效果。回收完成把reserved转retained；恢复完成再释放。armed/observed/uncertain、保留期已到、撤权、数据库断连均不得释放可能仍占用的payload计量。
- 两表方案仍需数据库事务级固定配额锁，对同一真实vault的确认/恢复转账串行后再聚合entries。只靠API内NSLock、先SELECT总和再各自INSERT，或按库别名各记一份预算，都会并发绕过。若两个数据库/实例可写同一vault，单库配额锁无法提供跨库保证，首轮应拒绝这种绑定而非声称已解决。
- 可以用明确约定的PostgreSQL事务级advisory锁实现两表配额串行；若改为第三张budget表，其自身也必须加入迁移、验证、屏障、摘要、权限和负测清单。不要在本审查文档中默增第三张表。
- 建议索引包括：幂等键唯一索引；同entry未解决operation的部分唯一索引；`(instance_id,owner_user_utf8,created_at,entry_id)`的受众分页；`(instance_id,volume_id,vault_id,charge_state)`的计量；`(phase,operation_id)`的有界核对。首轮不添加自动清理计划任务。
- 主设计首轮固定64MiB reserved+retained、64个entry历史、256个operation历史、8个未解决操作；entry规范JSON最多4KiB，operation最多8KiB。满额拒绝新确认，保留既有记录和文件，不驱逐uncertain记录来让新请求通过。终态历史保留/压缩是另一明确策略，不能套用N-027的“32条300秒内存回执”删除持久效果凭据。

## 确认、效果与崩溃分类

| 中断边界 | 数据库可能记录 | 文件系统可能状态 | 首轮可做的事 |
| --- | --- | --- | --- |
| prepared提交前或提交未确认 | 无记录或prepared | 原文件仍在；按协议不得rename | 通过原幂等键只读确认；不自动新建意图 |
| prepared已提交、armed前 | prepared及完整预留 | 尚无获准的文件效果 | 同ID/CAS确认未armed后可取消并释放；与arm串行 |
| armed提交回复不明 | prepared或armed | 必须先不发rename | 只读查阶段；不能根据网络超时猜测提交失败，也不自动继续执行 |
| armed后、rename前后 | armed | 原处、回收处、两处冲突、两处都无或身份不匹配 | **只读分类，保留计量和原凭据；不自动重搬、认领、删除或恢复** |
| rename后、observed提交前 | armed | 效果可能已发生 | 即使路径存在、inode/摘要相同，也不自动把旧操作升格为所有权证明 |
| observed已提交、两父fsync前后 | observed | 名称效果已观察，耐久性仍需核对 | 不能显示已完成；新批准后原post证据与现场完整匹配才可补同步/终结，不重复rename、不补造缺失post证据 |
| 两父fsync及后核对成功、completed提交回复不明 | observed或completed | 目标可能已耐久存在 | 原ID只读核对；DB回复缺失不允许再次rename，数据库rollback不撤销文件效果 |
| 已completed后结果丢失 | completed | 目标可能后来被外部改动 | 返回历史完成，不把历史stamp当成新的实时文件读取/恢复批准 |

主设计的armed崩溃只读分类规则可以显著收紧重放风险，但它意味着“可恢复记录”不等于“自动崩溃续做”。若恢复决策仍无法证明对象属于原操作，就保持uncertain并阻断普通可携切换，不用超时、同名、同大小或摘要相同自动接管。取消在armed后不能直接写cancelled释放；至少要有持有协调锁时可证明未发生效果的独立规则，否则只记录取消请求/uncertain。

若使用vault内的宿主协调sidecar，它必须有独立版本、归属/完整性、固定名字和持久化顺序；DB记录与sidecar同样不是一个事务。`host-binding`下日志默认不会随可携包导出。已有MigrationCoordinator的签名journal是**数据库/可携候选迁移**日志，不能把它直接解释为回收payload的效果日志。

## Schema4需要修改和验证的位置

以下为本次全库文本搜索发现的版本判断、持久表清单和相关入口；是将来实施检查单，本阶段不修改。行号指当前源码，实施时以符号名为准。

| 位置 | 必须处理的内容 |
| --- | --- |
| `database/migrations/0001_initial.sql`、`0002_app_state_revision.sql`、`0003_durable_jobs_outbox.sql` | 保持原字节；仅新增0004。`StateStore.migration4SQL`须与新文件对齐，不通过改0003插入回收表 |
| `StateStore.swift:174` `createSynthetic` | 显式支持1/2/3/4，4初始化走顺序迁移，默认版本是否变化单独决定 |
| `StateStore.swift:223` `schemaVersion` | 新增完整1/2/3/4链；缺号、未知号仍拒绝 |
| `StateStore.swift:227` `validate` | version>=4加入两张新表及完整列型/约束/索引/状态不变量；无第三表时Schema3共10表，Schema4应为12表；其他意外表仍拒绝 |
| `StateStore.swift:257` `migrate` | target白名单4及3→4事务；当前1→2→3路径保留；失败注入覆盖0004 COMMIT前；target<source继续拒绝 |
| `StateStore.swift:267` `validateUpgradeDefaults` | source<4升级时两张新表应为空、预算无占用、无伪效果；独立非空4→4诊断导入应比较完整4摘要，不冒充普通可携发布 |
| `StateStore.swift:277` `baseDataDigest/contentDigest/dataDigest` | 版本白名单4、两新表固定排序/精确列投影；`asVersion:3`完整保留Schema3 jobs/outbox，不含4表；旧摘要算法兼容不能被新列`SELECT *`悄悄改变 |
| `StateStore.swift:184/293` `importArchive/snapshot` | pg_restore单事务及macnas schema全量dump已包含新表，但必须在import后验证及Schema4门槛；不要仅追加表名单就当payload已备份 |
| `StateStore.swift:195` `installAppRoles` | 套件仍只可用各自schema；验证对两张新核心表无SELECT/INSERT/UPDATE/DELETE权限。新索引/触发器/函数不能形成权限提升 |
| `WriteBarrier.swift:52` | schema>=4时把两张新表放入同一SHARE屏障，保持统一锁顺序；若另加持久表全部覆盖，不只冻结展示entry |
| `Models.swift:87` `DatabaseDescriptor.version` | 数据库版本白名单4；`InstanceIdentity/PortableConfig/ExportManifest`的schemaVersion=1是另一格式，不应机械全部改成4 |
| `PortableInstance.swift:19/64/149` | createSynthetic白名单4；descriptor版本、layout、套件manifest和app-data版本联动；新增冻结下的effect/entry门槛，失败前不发布目的地 |
| `PortableInstance.swift:7/9/108/131/158` | fixed requiredFiles、excluded、manifest验签、copyFiles/seal与新增外部对象边界复核；首轮**不**把vault payload或宿主sidecar自动加进白名单 |
| `MigrationCoordinator.swift:76/100/119` | journal源/目标版本白名单、upgrade目标[2,3,4]、perform上限4；保持旧journal可读和未知版本拒绝 |
| `MigrationCoordinator.swift:194–222` | 候选attestation/空库跳过、import后内容摘要、已提交4的幂等恢复；未来source3→4不能重放效果或建立非空默认记录 |
| `MigrationCoordinator.swift:224–260/270` | Schema4新表默认检查、旧版本投影摘要、新快照/descriptor/manifest、只读候选与发布前检查；已发布候选resume也必须检查同样门槛 |
| `MigrationCoordinator.swift:286` | rollback保持原库和文件、不执行payload反向rename；只读/rolled_back_recovery不被新API绕过 |
| `Plugins.swift:18/46` | `.sample`的dataSchema/version/migrations与DB版本绑定，register白名单目前[1,2,3]；即使Schema4未改套件物理表，也需明确沿用此绑定并扩容，或独立版本解耦，不能漏改导致已升级实例启动拒绝 |
| `DurableJobs.swift:74` | `DurableJobQueue`当前硬要求expectedVersion:3；Schema4不能让overview/旧任务不可用。改成验证支持3/4并保留已有任务语义，不借机加recycle kind |
| `PrototypePlatformAPI.swift:102/161`及各FixtureFile*API | `<3`是拒绝旧enqueue的行为门槛，不能无脑改成`<4`重新开放旧写入；identity.schemaVersion==1与数据库Schema3不同。新文件效果必须受managed-write/恢复只读门槛 |
| `DesktopBridge.swift:153/216` | 初始化和overview目前硬要求databaseSchema==3；要允许4需明确兼容契约，不能只改数据库层 |
| `Sources/MacNASCLI/main.swift:14/19/23/25/57/125` | fixture/schema与upgrade目标白名单/帮助/预览/doctor及演练入口更新；target默认2是否保留独立决定，不能默改旧脚本语义 |
| `web/dist/model.js:89`、`bridge-client.js:63`、`directory-view.js:55`、`task-pages.js:23`、`notification-view.js:27` | 当前fixture与typed context硬标3；真接入4时版本能力协商/兼容策略需同步。Schema4仅迁移验证阶段可继续让现有网页保留Schema3，须明确尚未接线 |
| `scripts/dev.py:79–90`、`scripts/test_desktop_bridge.cjs:58/68/320` | 保留旧Schema2/3演练，新增空4的隔离升级/导出/恢复及阻断反例；既有3的fixture不能整体替换掉而丢旧版本覆盖 |

目前`schema_migrations`只存版本与applied_at，没有迁移源码hash。是否引入新版本校验记录需独立定格式，不能在0004倒改0001–0003；至少要在QA中验证0004 SQL文件与Swift常量一致，并保留历史迁移字节收据。

## 摘要、升级幂等和候选失败

`baseDataDigest()`有意只包含早期labels/jobs基础字段及套件基础值，不能充当升级的全部守卫。source3→target4必须同时做到：原source3 `contentDigest`不变；candidate的`contentDigest(asVersion:3)`等于签名包中的源摘要；Schema4新表均为空；目标完整4摘要写入新descriptor。独立诊断导入非空4库时比较完整4摘要，不能套用“新表默认空”；普通可携发布仍要求两表空。

需要保持三个不同失败边界：

1. 0004 SQL中途失败：事务回滚DDL和版本4标记，候选仍是源Schema3、原10表；源库不变，目的地不发布，重试沿用经过attestation验证的候选。
2. 0004已经提交、迁移journal尚未推进：候选`migrate(toVersion:4)`只校验不重复DDL；再核对Schema3投影与Schema4空默认。不能以“版本已经4”跳过篡改检查。
3. 目录/数据库已发布、journal仍为needsAuth：走现有已发布候选核验分支，重新核对attestation、manifest、只读、完整摘要及效果阻断门槛；不创建新库、不重签变化后的数据、不执行文件效果。

现有流程在CREATE DATABASE后、COMMENT attestation前中断时，会保留未证明归属的空库并记录abandonedDatabases，最多8个，再分配新候选。Schema4必须保留此行为；不能为“清理回收元数据”删除未知库、接管同名库或自动复用外部vault。

### 元数据字节预算与DB端摘要候选

当前`dataDigest`一次构造整份JSON输出，`PostgreSQLTools.run`对输出有4,000,000字节预算，随后`SafeFS.readData`默认也为4,000,000字节。新entry的路径、stamp、操作历史会更快触及此限制，payload只有16MiB不能证明元数据摘要一定有界。

主设计的行预算建议明确解释为**数据库完整规范行投影的UTF8文本**，不是磁盘行大小、Swift对象大小、某个intent字段大小或客户端压缩JSON大小：

| 资源 | 首轮上限 | 必须计入什么 |
| --- | --- | --- |
| 每个entry | 4096字节 | 全部字段名、JSON空格/转义、原主体/路径、UUID、时间及将来阶段字段，不只计原路径 |
| 每个operation | 8192字节 | 不可变intent、全部pre/post证据、actor/reconciler、错误和UTC阶段时间；不附无界history数组 |
| 两新表历史 | 64个entry、256个operation | 最大行文本合计`64×4096+256×8192=2,359,296`字节；数组分隔/括号和表键还需额外空间 |
| 两新表规范文档预留 | 建议2,363,392字节 | 上述行合计再留4096字节固定结构余量；实现仍对实际投影长度做精确检查 |
| 完整Schema4规范文档 | 建议首轮4,000,000字节以内 | 包括原Schema3的所有数据，不能只对新两表计量；失败返回budgetExceeded，不截断 |

单字段“路径最多4096字节”与整行4KiB同时生效：长路径或大量需JSON转义的字符可能更早触及整行预算，必须在预览及确认前明确拒绝，不能截断路径或摘要。若存成bytea，规范JSON中的hex/转义还会膨胀；测量使用实际固定投影，不能按原始bytea长度估算。恢复目标也可能使8KiB操作预算不满足，同样在prepared前拒绝。

prepared时必须给该entry/operation的**最坏终态**留够空间，包括observed证据、两父同步时间和reconciler资料；不能先用几乎满8KiB的prepared记录执行rename，之后才发现poststamp无处保存。可用固定字段上限/完整最坏形状计算保留量，在持有DB配额锁时一并验证；后续只读核对也不能追加无界历史或覆盖原证据来腾空间。poststamp超出已准入的固定形状时保留uncertain，不清理对象。

仅靠新两表的64/256行数和4/8KiB上限，**无法保证整库旧摘要都容纳**。现有Schema3持久jobs/events/receipts未设置全局总行数，`DurableJobQueue.jobs`中的4096只是单次完整数组读取界限，不能当作存储配额。按上述新表预留，4,000,000字节中只剩1,636,608字节供旧数据及其它结构使用。旧数据可能已经超过这个数；不能声称新行预算自动解决全库问题。首轮应在构造全量JSON前按同一固定投影预检总字节，超限安全拒绝摘要/诊断；若业务要求“完成后始终可算摘要”，还必须让会增长旧表的全部写者参与总元数据准入，或另行采用有版本的分段/流式算法。只冻结某一时刻不能限制之后旧任务继续增长。

可避免客户端4MB输出瓶颈的候选是：对**同一份既有canonical JSON文本**在数据库内执行`encode(sha256(convert_to(canonical_text,'UTF8')),'hex')`，仅回64位hex。PostgreSQL18官方文档列出了内置`sha256(bytea)`、`convert_to`和`encode`，无需引入pgcrypto：[Binary String Functions and Operators](https://www.postgresql.org/docs/18/functions-binarystring.html)。这里只核实文档能力；**未在本机SQL实测，也未改现有摘要实现。**

把SHA计算搬到DB不等于可以无限jsonb_agg：总投影/行大小/聚合内存和语句时间仍须有界。建议先计有界固定投影的总长度与行数，再构造受限规范文档；沿用进程输出/60秒工具等待界限，并为摘要SQL明确statement_timeout。首轮4,000,000字节是保守的完整文档建议上限，不是PostgreSQL内存用量承诺，聚合中间对象可能占更多内存。

兼容性必须用旧Swift/CryptoKit路径独立交叉验证：

1. Schema1/2/3的base/content及`asVersion:1/2/3`产生与现有签名descriptor完全相同的摘要；列、行排序、NULL、JSONB文本、时区和bytea表示不得无声变化。
2. 当前`PostgreSQLTools.run`会对psql输出执行`trimmingCharacters(in: .whitespacesAndNewlines)`，psql还有记录末尾换行。DB端应哈希原canonical值本身，是否与旧“psql输出再trim”的字节恰好相同必须真实验证，不能假定追加换行或盲目套SQL trim。
3. 覆盖中日文/emoji、引号/反斜线/可转义字符、空数组、嵌套JSONB、时间戳/UTC切换、bytea/无符号身份字符串，以及接近输出边界的数据。不得把`sha256(旧摘要hex)`、各行摘要拼接或删减列误当原算法。
4. 新4文档显式增加两表；旧投影继续排除它们。DB端SHA与原Swift路径在可输出样本上逐份一致后，才能说计算位置改变而摘要语义未变。超大/超时场景要证明固定错误和正常清理，不能只验证64hex长度。

若未来必须支持超过首轮完整文档上限的元数据，再设计带版本/域分隔/长度边界的流式语义摘要，并保留旧算法；不能在本次迁移无声换算法或只摘要前N行。

## 普通可携流程的保守阻断如何落地

建议使用一个明确的`assertNoExternalFileEffectsForPortableSnapshot`语义（名称仅示意），同时覆盖来源和候选：

- Schema1–3保留既有只读可携流程，不凭旧数据库证明外部raw数据存在或没有N-027崩溃孤儿；Schema3→4只创建空新表。原有外部库内容仍按既有规则不打包。
- Schema4在当前实例独占门、vault执行锁和完整SQL屏障均已持有后，要求`recycle_entries`与`file_effect_operations`行数都为0，且当前明确批准的vault核对为空；released、restored、completed、cancelled历史也阻断。vault缺失、未批准、身份不明、孤儿或读取失败不能当作空。不得自动创建/清扫目录或删除历史以通过检查。
- 实际文件效果写者从确认后持久prepared直至rename、同步和最终DB提交持有同一实例shared协调门及vault锁；固定实例门→vault锁→DB锁顺序。仅让metadata INSERT参加锁而rename脱离锁，仍会出现“包校验通过时文件继续移动”。进程崩溃释放锁后，任何持久记录仍使普通可携拒绝。
- upgrade的源包创建、恢复包导入后、schemaMigrated及validatePublished/resume都要使用相同规则。已签名包也不能绕过：签名只证明可信来源及元数据完整，不证明payload随包存在或当下批准有效。
- 阻断时返回固定unsupported/busy等由主设计确定的错误，保留源和候选，不自动删元数据、释放未知计量、搬回文件或临时放宽只读。非空诊断pgdump/隔离只读导入可以核对数据库历史，必须有独立入口/结果语义并拒绝普通发布。若未来需要携带非空回收站，应另设计payload清单、复制校验、保留期、跨设备与双实例fencing，不在本阶段暗启。

该门槛保证的是“当前受控单实例协议中，两张回收表和已批准核对的vault都空”。它牺牲了携带已完成历史的便利，不能证明任意外部进程、另一台Mac或绕过协议的宿主从不写盘，也不是全局强fencing。实例file lock和库内配额锁都不能用来声称真实多宿主已验收。

## 需要新增或扩展的验证位置

本阶段仅列检查点，未编写或执行这些测试。旧Schema1/2/3测试保持原版本，不做全量数字替换；为4新增对应场景。

| 现有测试/入口 | Schema4应覆盖的反例和断言 |
| --- | --- |
| `Tests/MacNASCoreTests/CoreTests.swift` `testVersionedMigrationRejectsUnknownSchema`、PORT03–06/08/14/15 | 缺号/未知4之后版本、未知表列型/约束、4描述符/套件不匹配；任一新表含历史（包括released/completed/cancelled）或vault非空/未知均拒绝普通export且无目的地；签名包不含外部payload或宿主sidecar |
| `Tests/MacNASCoreTests/MigrationRecoveryTests.swift:7–73` | 3→4独立候选、源Schema3完整内容不变、重复升级同库同ID、0004失败仍3、afterSchemaCommit恢复不重放DDL、完整1/2/3/4链；target99拒绝维持 |
| 同文件`:109–180` | 同名外库不接管；未attested空库保留并换候选；4新表任意插入/更新/删除及字段篡改不能重签为成功；rollback保留源、旧包、候选且禁止resume，不产生文件效果 |
| `Tests/MacNASCoreTests/DurableIntegrationTests.swift:6–80` | 仿照2→3新增3→4；Schema3投影摘要及4默认检查；新12表冻结写者真实进入Lock等待；读取/pg_dump继续；timezone改变不改完整摘要 |
| 同文件`:124–138`及`PostgreSQLIsolationTests` | 两套件角色对两新核心表的SELECT和写入均拒绝；恢复的Schema4所有原任务/新效果写入口均只读拒绝 |
| `SnapshotBarrierTests`及`PrototypeAPITests` | prepared/armed/observed/uncertain阻断；迟到确认/rename与export冻结串行，不能导出一半状态；取消/超时正常回收自己屏障进程和锁，无副作用清理 |
| `DurableJobTests.swift`、`DesktopBridgeTests.swift`、`JobPageTests`、`EventConsumerStatusTests`、`EventSourceContextTests` | 保留3并新增4兼容，旧jobs/outbox正常读写/恢复拒写、同源标记改变失效；不因4开放旧enqueue或陌生效果接管 |
| 新Schema4记录约束/预算定向测试 | 并发确认不超额、entry/operation CAS/唯一键、相同幂等键不同intent collision、恢复冲突、uncertain不释放、到期不删除、跨库/别名vault不双算；完整规范行4/8KiB边界、转义膨胀、最坏终态预留、64/256历史满额、整库旧数据增长和摘要总预算；SQL注入文字仅为数据 |
| 新文件效果故障测试与Node→Swift管道 | armed提交回复丢失不rename；armed前、rename后/observed前、observed后/fsync前及完成回复丢失；真实自有进程SIGKILL；armed重启仅只读分类，绝不自动搬/删/认领；非空诊断DB快照只恢复元数据、不恢复payload，不绕过普通可携拒绝 |
| `scripts/dev.py`完整入口/前端QA | 实施运行源码/Tests/迁移/嵌入依赖后按守卫重跑完整新基线、全部CLI/管道、需求与前端；保存真实失败及测试库正常关闭证据，不用本审查取代 |

“schema升级失败可回滚DDL”“pg_dump/pg_restore内容相同”和“文件rename在SIGKILL后仍可核对”是三个不同结论，证据必须分开。当前网页显式内存树、Node模型、元素替身、真实Swift合成APFS管道与实际浏览器也继续分别记录；本文不增加任何实际浏览器通过项。

## 本次审查执行记录

首轮使用本地文件读取、文本检索和文档写入；二次审查另读取PostgreSQL18官方binary-string文档以核实DB端SHA候选，未执行任何SQL。写入前再次核对开发卷UUID为`C1755FBB-FCA8-4EA4-BEE2-AA6BF3258B6C`。首次把不可seek的stdin直接传给Python `plistlib.load`报错，改为`plistlib.loads(stdin.read())`后完成只读身份检查；没有在身份未核对时写文件。文件检索时两个假设独立源码文件名不存在，随后确认`PostgreSQLTools`实际在`StateStore.swift`、`InstanceLock`实际在`SafeFS.swift`，据此完成引用。二次审查最初采用的ADR-021文件名猜测不匹配，随后按实际`ADR-021-recoverable-recycle-journal.md`读取。以上均为审查工具使用情况，不是产品测试失败或新的回归收据。

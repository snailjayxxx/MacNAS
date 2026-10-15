# ADR-003：可恢复迁移事务、隔离升级和统一停写

日期：2026-10-15。实现范围：当前Mac上的合成实例与独立PostgreSQL18测试集群；最终实测见N-009证据报告。

## 日志与恢复

目标目录旁的 `.目标名.macnas-journal.json` 保存带Ed25519签名的宿主日志。记录事务UUID、源实例/代际、源导出ID及清单hash、源/目标schema、目标主机逻辑ID、新库UUID、可推导的staging名称、已核对文件和事件序列。日志不记录绝对业务路径、密码或私钥；文件位置和锁属于宿主状态，不进入可携包。

阶段为 preflight → exported → copying → databasePlanned → imported → schemaMigrated → needsAuth → publishedReadOnly。readyForCutover保留为契约值，尚无有效转移条件，加载和状态转移均拒绝把它当作已授权。任何生产cutover继续拒绝。

每次重试核对可信宿主公钥、源包签名、相同源指纹、目标名称和计划参数。逐文件重新核对hash；只修复本事务staging中已知的普通文件，不清除未知文件。数据库名由预先写入日志的UUID生成；数据库owner和事务注释必须匹配，身份不明时拒绝接管。

数据库导入、schema提交、目录rename可能先于日志推进完成。恢复时检查实际schema、语义数据hash、数据库身份、目标Host Binding和只读状态，识别已经完成的步骤，不重复导入或迁移。当前恢复的是文件级复制进度及事务步骤，不是大文件字节级续传。

创建数据库与写入身份注释之间不是一个PostgreSQL事务。在该窗口终止后，如果原计划库确为预期测试owner、没有身份注释且仍为空，恢复不会接管或删除它，而是在签名日志登记保留的新库名并重新分配UUID继续。最多重新分配8次；非空、已有不同身份或owner不符仍拒绝接管。孤立库保留待审计清理，绝不凭名称覆盖。

## Schema升级与回退

Schema1→2使用编译内置且版本化的SQL，给两个套件状态表增加revision及约束，并插入migration2记录。数据库不执行包内任意migration脚本。升级先保留签名的源快照，再在新的隔离库执行DDL事务；故障注入的除零错误会回滚该事务。未来版本和降级不在支持范围。

数据库快照仍为一个逻辑导出，包含核心和两个套件Schema。签名元数据携带语义数据摘要：标签、任务/检查点、应用行与schema版本；它不是所有系统目录、角色和审计元数据的逐字节校验。导入后核对摘要；升级后重新快照和签名，保留parentExportID。

候选库通过验证才设置默认事务只读并生成新的Host Binding。这里的回退是停止接受该候选、保持它只读、将日志及Host Binding标记rolledBack，保留源库、候选库、快照和目录。没有切换生产服务/域名或存储池，所以不能把它称为生产切换后的全量数据回滚。

## 配置和数据库统一停写

所有受控写入持有实例共享文件锁；导出获取实例排他锁，等待正在执行的受控任务完成。随后独立PostgreSQL会话在五张已知核心/套件表上持有SHARE锁，等待数据库已有写事务结束，并阻止新的直接SQL写入；SELECT与pg_dump继续。

锁、导出与子进程均有超时或取消路径。取消数据库停写等待时，只对本次随机application_name、当前测试数据库及预期owner匹配的会话发送pg_cancel_backend，再关闭会话，不终止源写任务。数据库锁跟随会话释放，实例锁跟随进程释放。导出在发布前确认锁会话仍存活。表清单是显式白名单，未来新增数据表必须扩展契约；对绕过API直接改配置文件的本机用户不提供一致性保证。普通进程锁及表锁不能替代跨Mac分布式fencing。

## 权限和证据边界

每个实例为两个套件生成不同PostgreSQL角色，只授予各自Schema的现存表权限，撤销PUBLIC连接和共享Schema权限。数据库级GRANT/REVOKE负测与核心API授权分开。测试socket采用私有目录与本机trust认证，证明的是数据库授权语义；它不能认证任意本机恶意进程的身份，正式主机认证/OS隔离仍需后续实现。

测试签名密钥继续由测试进程环境注入。正式Keychain密钥、签名信任分发和重启后的宿主安全配置不在本轮范围。受控SIGKILL验证是当前Mac进程崩溃测试，不代表断电、跨Mac或真实磁盘故障通过。

依据：[PostgreSQL锁模式](https://www.postgresql.org/docs/18/explicit-locking.html)、[GRANT](https://www.postgresql.org/docs/18/sql-grant.html)、[pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html)。数据库属于共享对象，其身份注释使用[shobj_description](https://www.postgresql.org/docs/18/functions-info.html#FUNCTIONS-INFO-COMMENT-TABLE)读取。

## N-010 后续实现

ADR-004将版本化迁移扩展至Schema3，全部新增任务/outbox表进入停写与语义摘要；候选发布前同时核对源版本的数据投影。上文N-009证据保留为历史记录。

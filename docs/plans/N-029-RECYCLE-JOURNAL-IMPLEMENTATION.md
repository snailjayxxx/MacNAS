# N-029：分步实现回收站持久基础与同卷效果

接续[N-028设计](N-028-RECYCLE-BIN-DESIGN.md)和[ADR-021](../decisions/ADR-021-recoverable-recycle-journal.md)。N-028阶段只有设计与抽象模型、运行Schema3；N-029 A现已实现Schema4与内部数据库日志并通过新完整自动回归，完整验收结果见[A矩阵](N-029-A-ACCEPTANCE.md)、[ADR-022](../decisions/ADR-022-schema4-file-effect-foundation.md)和[阶段证据](../evidence/n029-a-2026-10-16.json)。仍没有文件回收/恢复效果、按钮或RPC。以下保留编码交付顺序，不以计划替代实现；每个独立步骤相关验证/文档齐全后可按长期授权中文提交并正常推送dev/bootstrap。

## A：Schema4与日志基础

1. 核对开发APFS UUID C1755FBB-FCA8-4EA4-BEE2-AA6BF3258B6C、Git用户改动、N-027完整原生/前端源码收据；工程仍在MacNAS-Dev，不用Gen 8。
2. 新增0004和内置顺序迁移；两核心表按主设计封闭字段/约束，未知表仍拒绝；旧0001–0003字节不变。保留旧1/2/3覆盖，不机械改所有schemaVersion=1。
3. 同时扩展StateStore精确验证、asVersion:3兼容投影/4完整摘要、升级空默认；解决DB输出4MB与总元数据预算，不能截断/漏表。新表进入统一写屏障/角色拒绝，确认/阶段/预算转账在单个SQL事务中。
4. 实现DB侧不可变意图、幂等键冲突、revision CAS、单entry未决排他、prepared取消和预留/retained/released规则。A阶段无文件移动入口，observed/completed只用封闭测试夹具构造来验证约束，不能据DB结果宣称文件已移动。
5. 增加普通portable空两表+vault绑定门槛接口；A未创建vault时明确定义未启用状态。候选import/升级/已发布resume同样守门。两表非空（含released历史）拒绝普通可携包；允许隔离只读DB快照诊断但不作为payload恢复。
6. Schema3源保留，隔离候选升4；旧任务/outbox/套件数据投影不变；故障注入DDL事务回滚、COMMIT后journal前、导入/发布前后、源与候选篡改拒绝、空4导出/恢复/回退、非空门槛及12张表真实SQL停写。按持久审查逐个检查硬3版本门（包括Plugins/Jobs/Bridge/CLI/前端上下文），保留兼容，不假装网页已支持4。
7. 新原生/测试变化后运行新的完整未过滤Swift、全部独立CLI管道/演练，再运行前端并核对完整及内嵌依赖hash；保留实际失败、PG关闭和本阶段仍无文件回收实现的边界。不要用N-027的271项冒充新执行。

## 再做 B：原生文件效果与故障恢复

- 独立宿主回收/恢复批准和不可自动unlink的vault；实例门→vault锁→DB锁，持锁贯穿一次准入/rename/证据/同步/终结，确认容量跨进程串行。两个数据库/实例不能绑定同vault。
- 同设备单常规单链接文件0..16MiB，双父目录FD、SHA、RENAME_EXCL、post-stamp、严格同步失败语义；没有普通rename/copy+unlink/逆向回滚降级。
- prepared→armed→observed→completed；最后检查后撤权或替换可已有作用，结果uncertain且保留。armed崩溃无post证据不自动完成/续做/取消；只读观察与新批准的写结算分开。缺证据手动采纳、永久删除、到期清扫继续不接入。
- 新建批准合成目录真实测试0/16MiB/超限、冲突/规范化碰撞、硬链接/符号链接/特殊文件、双父/源/目标替换、既有写FD改写恢复mtime、满额/到期/并发、重启未批准和卷变化、每阶段DB丢回执、rename前后两处真实SIGKILL与observed中断。内存模型不能替代这些证据。
- 非空回收记录后的导出/回退明确拒绝，不把DB回退当文件回退，不扫描家庭/NAS目录找孤儿。

## 最后 C：严格桥接、fixture与界面

先固定具名DTO/方法白名单与受众、Schema3/4协商，再接真实Node→Swift合成管道；网页版仍只连明确fixture。preview/operation/entry ID分离，确认后dispose不取消已移动文件或删除持久记录，旧状态只读查询不能取得批准。不关共享连接、不重连扩大预算。

文件中心接入回收确认、列表原路径/主体/时间、同库目标恢复预览、冲突重选和原结果核对；共享64MiB包含回收保留，不随窗口/会话退出释放。中日文表达结果待核对与取消边界。元素替身/模型/管道各自记录，不计为浏览器通过。

## 沿用限制

52项现有浏览器仍全待验收，站点权限状态未变，不重复请求/启动预览或换通道。独立回收UI到位后另加专项清单。不得sudo、正式NAS/家庭文件、生产数据库、系统账户/ACL/服务/网络/防火墙/公网改动或新依赖。目标仍Apple Silicon/macOS15+，当前macOS26.5.2不是15运行证据；Intel以后做、SYS-09很后期未开始。父需求/原规划字节/优先级不变。

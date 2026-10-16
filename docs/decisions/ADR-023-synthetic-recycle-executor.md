# ADR-023：合成回收执行器与后置记录预算

日期：2026-10-16。状态：N-029 B第一段已实现并通过新完整自动回归，结果见[阶段证据](../evidence/n029-b-2026-10-16.json)。沿用[ADR-021](ADR-021-recoverable-recycle-journal.md)与[ADR-022](ADR-022-schema4-file-effect-foundation.md)，不修改已发布0001–0004。

## 宿主与锁

第一段仅在MACNAS_TESTLAB下的新建Schema4合成实例建立固定资料库/vault布局。固定注册绑定实例、generation、DB、宿主和两个目录身份，私有根/slot为0700、锁为600。注册与payload位于host-binding，不能被普通目录来源浏览或装入可携包。新宿主只读取已知实例元数据，不因旧注册或operationID打开旧payload。

明确的回收、观察、结算、prepared取消批准互相分离，令牌留在内存并绑定宿主、用途和撤权代次，重启不恢复。执行持实例共享门、vault的具名inode独占flock，再进入短DB事务；hash/rename/fsync期间不持有容量SQL事务。此锁只协调可信本机进程，不作为跨主机fencing。

批准缓存固定签发时的注册规范字节；有效但不同的后续注册也使旧批准失效。原始UTF8主体必须在当前配置中唯一且角色为administrator，不能从重复主体中的任一管理员记录推断权限。这两项分别有实际红例和修复，见B验收矩阵。完成阶段还需协调器文件内部生成的现场核验凭据，通用permit不能直接设置observed/completed/cancelled。

预留64个随机、已登记的空slot，对应64条entry历史上限。被DB拒绝的确认可以继续保留一个已知空slot，不制造需要自动删除的陌生目录；slot一旦进入历史不循环使用。数据库ID与注册slot之外的目录/payload使新效果准入拒绝并保留现场。没有析构unlink、自动孤儿回收或到期清扫。

## 后置写入的容量边界

A的新准入/普通transition会计算旧业务元数据的4MB预算，旧写者在armed后仍能增长。B不能在rename后再次用整库预算拒绝唯一的post证据。

准备时已要求规范operation行加3072字节不超过8192、entry加32不超过4096。post证据按PG规范文本最多2048字节；其余新增时间、最大长度原始主体核对者、phase和revision增长仍在该预留内。B后置CAS只访问原operation/entry及固定索引，用同一事务更新证据、阶段和费用，逐行调用已验证的封闭函数检查最终行。它不聚合旧jobs/events，也不重新收取新的历史或对象容量。总DB摘要仍可能超过4MB而明确拒绝，这不是整库容量fencing。

必须在真实测试中于armed之后增加旧元数据超过4MB，再确认后置记录可落库，且后续整库摘要仍拒绝、不截断。还须验证最坏证据/主体/时间/revision行预算、并发阶段CAS与丢回执。没有声称任何SQL事务都必然成功；数据库不可用、锁超时、损坏或身份失效仍保留不确定记录和对象。

日志事务使用SET LOCAL synchronous_commit=on，且在同一事务检查fsync/full_page_writes开启；不更改数据库的默认配置。数据库默认异步提交的回归在本次新完整运行中验证。普通portable继续拒绝任何登记后的vault，包括空池；载荷备份和空登记迁出另设计。

## 一次移动和恢复核对

双父FD、源FD、单链接、同设备、完整stamp与SHA复核后，armed提交核实才允许RENAME_EXCL。rename不是源FD-CAS，最后检查后的替换或撤权可能已经产生效果；此时保留现场，不逆向rename或删除目标。observed必须保存包含ctime的完整post证据，再同步双父、复核并完成reserved→retained。

真实SIGKILL分别停在rename前、rename后无post和observed。新批准的只读观察不改DB/费用；无post保持uncertain。只有已有post且现场匹配时，新readWrite结算批准才允许补同步/CAS原ID并另记核对者，不能再rename。prepared取消需新批准、执行锁和未移动的正面证明。A无执行者arm/cancel入口不得用于已登记执行器的实例。

恢复动作另一个独立切片，C再接严格DTO、真实合成管道和网页。本轮用户要求暂不使用浏览器；过去45 PASS/7 PARTIAL不构成新回收界面验收。

## 实际验证

最终未过滤20261016T184142-5cba9f0d通过355项Swift（4259.458秒，含4项内嵌Node→Swift及3次真实SIGKILL）、16项独立CLI管道（370.742秒）及全部CLI演练，测试库正常关闭。前端20261016T200328-04a217c3通过273 Node/15静态策略/16语法/9需求负测。68份完整核心、91份原生运行收据及联合116份当前源码已核对；原生期间91份均不变，结束后仅修正前端QA脚本dev_web.py的漏导入并由新前端覆盖，旧/新SHA明确记录。需求输入前后冻结通过。恢复方向另一个独立步骤，C再接桥接/界面；当前通过不覆盖真实断电/跨Mac/生产NAS。

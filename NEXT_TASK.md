# 接续任务：N-029 B，独立批准的同卷合成回收与真实中断

2026-10-16用户要求“先继续开发”。N-029 A已编码Schema4与内部持久日志，最终未过滤20261016T152343-61e5e23c和前端20261016T163726-d71f6e06均通过；下一项按[N-029](docs/plans/N-029-RECYCLE-JOURNAL-IMPLEMENTATION.md)推进B，不再重复A设计。先读HANDOFF、AGENTS、PROJECT_SPEC、ARCHITECTURE、PROGRESS、[ADR-021](docs/decisions/ADR-021-recoverable-recycle-journal.md)、[ADR-022](docs/decisions/ADR-022-schema4-file-effect-foundation.md)、[A验收矩阵](docs/plans/N-029-A-ACCEPTANCE.md)及[A证据](docs/evidence/n029-a-2026-10-16.json)，核对SSD/Git。A开始提交0961830，最终以Git和仓库外publication收据为准。

最终未过滤20261016T152343-61e5e23c通过323项Swift（3252.431秒，含4项内嵌Node→Swift）、16项独立CLI管道（332.192秒）及全部CLI，测试库正常关闭。前端20261016T163726-d71f6e06通过273 Node/15静态策略/16语法/9需求负测。83份运行收据、60份完整核心、12内嵌/4独立依赖和联合108份源码一致，需求输入前后字节冻结通过。 首次完整323项曾有1次意外database错误，根因仍未定；失败/单例诊断/新完整成功分别保留。抽象模型不是文件/SIGKILL证据。

## 已有边界

- 单个常规文件0至16MiB、32KiB服务端分块，来源/目标/暂存同设备。独立目标复制批准，固定两端，不覆盖发布，源不删除；冲突/同源同目标无提交能力。8活动、64MiB复制预留、32条/300秒短期结果，不是持久文件任务。
- 共享合成树总64MiB覆盖所有库已发布字节和上传/复制预留；来源与窗口关闭后清理迟到头及在途操作，保留共享连接，不重连或扩大预算。
- 发布后改写并恢复mtime的反例已修；目标异常为uncertain且保留，复制/上传取消不会回滚目标。仍不是敌对本机进程强fencing或文件系统快照。
- 网页只连Schema3内存fixture；真实Node→Swift管道另使用批准的新建APFS目录，没有生产浏览器通道或登录。PostgreSQL18.6-only，数据库支持Schema1–4，既有任务/Bridge具名客户端允许3/4。
- A日志只管理元数据，没有vault/文件效果/完成setter；prepared取消方法专用于无执行者的A。64MiB、64entry历史、256operation历史、8未解决及整行4/8KiB；0字节/到期/uncertain不消失。普通4可携拒绝全部历史和未知/payload宿主布局。

## 下一步

B先交付一个独立可验收切片：仅在新建同设备合成目录中实现单向移入回收站，常规单链接0..16MiB，独立宿主批准/私有0700 vault注册，固定双父FD、RENAME_EXCL、完整post-stamp持久化与双父同步；不接生产NAS或浏览器。observed/completed写入口仅供持批准和vault跨进程锁的执行者，禁止通用setter或旧队列自动重放。恢复动作随后单独完成，C再接严格DTO/fixture/界面。

同一切片必须验证真实rename前后及observed阶段SIGKILL：重启后没有新批准就不打开旧路径；新只读批准只分类/报告，不写DB；已有完整post证据的写结算需新readWrite批准，只补同步/CAS原ID，不再rename。armed缺post证据保留uncertain与收费。prepared取消必须有当前批准、锁及明确未移动证明，不能直接复用A的无执行者方法或自动unlink暂存对象。

A摘要在同一只读快照按实际规范大小和最坏预留守4MB/10秒，但旧jobs/events写者可在之后或并发增长；连取消也可能预算拒绝，尚非整库容量fencing。B在首次真实效果前必须实现或证明后置证据能够提交的预算/锁协议，不能仅引用A准备时的余额。A发布后0001–0004均保留原字节；如需改数据库结构应新增迁移，不改写已发布迁移。保留源库和所有未知记录，普通portable仍拒绝任何历史/未知vault，DB回退不逆转rename。

外部效果必须prepared→armed→observed→completed；只有prepared能在当前批准/锁/未移动证明下取消，armed无post证据只保留uncertain。只读观察与新批准的写结算分开，均不能重搬旧ID。普通portable在新两表任何历史或vault非空/未知时拒绝，DB回退不逆转rename。独立回收/恢复批准、16MiB/64MiB边界和30天只记录不自动清扫见主设计。正式NAS/家庭文件、永久删除和后台清扫不授权。

之后分别设计跨设备移动（目标验证后另行批准来源处理）、共享权限，再推进DSM控制面板/网络的独立只读适配器。真实配置仍需生产认证/helper/秘密存储/预演及失联恢复，不改当前Mac的IP、代理、SMB、账户、ACL、防火墙或服务。Intel以后再做，网页远控很后期。

## 验证与权限

Chrome155.0.8059.85本轮52个复合项为45 PASS、7 PARTIAL，无剩余文件访问阻断。首轮CUA DOM/截图实测1440/390/320、中日文、两主题及原生200%，T05修正后中日分别等待69/79秒复测。用户自行开启扩展文件网址权限后，文本/70001字节/空文件/16MiB/超限上传、真实多块及空文件保存和逐字节/SHA256比对完成；上传/下载/复制的进行中取消、上传导航/切语言/最小化恢复/关窗/身份切换已补测。工具连接重置后续用Chrome原生控件，未改安全控制或注入模型。 详见[浏览器清单](web/tests/BROWSER_ACCEPTANCE.md)和[逐项收据](/Volumes/MacNAS-Dev/MacNAS-Workspace/Evidence/browser-n029-2026-10-16/cases.json)。

7项PARTIAL为N06（慢响应/迟到错误）、FO04（模态仍开时切身份）、FT05（关窗/身份后URL回收未分别独立验；已测下载中取消及一个替换旧Blob实际ERR_FILE_NOT_FOUND）、FT08（已补200%完整上传，精确320/390中日全流程仍缺；调试连接未附加导致重设viewport失败）、FC03（三种大小复制/中途取消已测，普通UI无法准备超限复制来源）、FC04（进行中复制关窗/导航/身份未全验）、FC05（无普通UI的uncertain核对入口）。

第四次预览13926正常退出0，8766无监听，任务标签已关闭、缩放恢复默认；首轮viewport已重置，补测重设未成功应用。首轮final-console.json=[]仅限首轮，补测DevTools截图报告8条错误，含runtime.lastError、favicon.ico404及DevTools探测被CSP拒绝；见resumed-native-console-observation.json，不称整轮控制台完全干净。网页仍为Schema3内存fixture，不连接Swift/PostgreSQL/NAS或证明Schema4回收效果。

工程在/Volumes/MacNAS-Dev/MacNAS-Workspace/MacNAS，开发APFS卷UUID C1755FBB-FCA8-4EA4-BEE2-AA6BF3258B6C，写入/构建/测试前核对。原生/测试/嵌入Node依赖变化后运行新的未过滤基线；只改网页时仍需精确匹配核心收据及新前端。保留全部实际失败、源码摘要及测试库正常关闭。不安装新工具，不用sudo，不连接正式数据库或家庭文件。独立阶段完成后按长期授权中文commit并正常推送dev/bootstrap，不合并main/强推/改历史。

基线111父项/97首版13后续1暂不需要不变，893条子记录；SYS-09独立7条，合并112父项/97-14-1/900条。原29份规划与5份来源字节保留。

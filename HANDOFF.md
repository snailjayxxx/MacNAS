# MacNAS 新对话交接

本轮接续（2026-10-16 17:29 JST开始）：用户明确继续后续开发、暂时不使用浏览器、无须确认则连续开发到11点以后。暂按今晚23:00 JST理解，已异步询问时区并继续独立工作；仍需持续到约定时间之后，不能发布第一段后提前停止。

N-029 B1已发布bbbfcf8，B2也已完成完整自动验证。B2在同一登记owner/library/vault内实现0..16MiB单常规文件恢复，来源恢复与物理目标父目录批准分开，固定双父FD/完整stamp/SHA且只尝试一次RENAME_EXCL。prepared及取消恢复仍保留原entry和计量；双父同步、后置证据复核及完成CAS后才释放原entry的回收计量，历史和slot不复用。 最终未过滤20261016T202932-7706e845通过374项Swift（5085.365秒，含4项内嵌Node→Swift、3次回收及3次恢复真实SIGKILL）、16项独立CLI管道（375.706秒）及全部演练，测试库正常关闭。前端20261016T220444-286b66e2通过273 Node/15静态策略/16语法/9需求负测。70份完整核心、93份原生输入及联合118份源码匹配，需求输入前后冻结通过；本阶段没有完整运行后再改QA输入。 只限新建TestLab/当前Mac/同设备，未接回收恢复执行RPC、共享fixture计量、完整网页或生产NAS。缺post中断不采纳/续做/取消/释放；只读观察不写DB，有post且匹配才可由新写结算及当前独立目标批准补同步/CAS原ID，不再rename。登记vault与任何日志历史仍拒绝普通portable，DB回退不逆转文件移动。 见[B2证据](docs/evidence/n029-b2-2026-10-16.json)/[矩阵](docs/plans/N-029-B2-ACCEPTANCE.md)/[ADR-024](docs/decisions/ADR-024-synthetic-restore-executor.md)。中文提交/远端核对以Git与Evidence/n029-b2-publication-2026-10-16.json为准。

C1也已完成模型自动验证。C1补齐严格只读核对正文、十字段日志记录与本地视图生命周期。candidateMoved/matchedPost不推进数据库阶段或释放计量，notVisible费用保持未知并标需核对；首个可见结果固定条目/意图，revision不倒退，历史entry后来释放仍能正确呈现。dispose忽略迟到成功/异常，不取消操作或关闭借用来源。 新前端20261016T220551-2740f6f4通过293项Node（新增20）、17语法、15静态策略和9需求负测，未启动监听。复用B2精确未变的70份完整核心及原始374Swift/16独立管道收据，没有在C1重跑或冒称新执行；只有前端验收脚本及两份新JS/测试文件变化，联合120份当前源码及需求输入冻结匹配。 见docs/evidence/n029-c1-2026-10-16.json及Evidence/n029-c1-publication-2026-10-16.json（实际提交/远端核对以Git和收据为准）。模块未接宿主/桥接/静态桌面，不称浏览器或新原生执行通过。

下一步C2只读观察桥接。外部Evidence/n029-c2-draft/manifest有13文件及C1前置SHA；17项Swift定义编译，5纯数据与305Node通过，12真实PG/管道待执行。准备器n029-c2-prepare-worktree.py会在发布/干净树/PG关闭条件下创建同级MacNAS-C2，使用MACNAS_DEV_BUILD_NAMESPACE=n029-c2隔离Build；实际工作树/运行状态以n029-c2-worktree-state.json和n029-c2-active-state.json为准。须先定向17，再新未过滤391/16独立管道/全部CLI/前端305，5内嵌场景已含Swift总数，14嵌入/4独立依赖要完整捕获。此轮仍继续到23点以后，必要回归跨时后完成收尾；不使用浏览器，不发布未验证草稿。

历史A基线（2026-10-16，Asia/Tokyo）：已按用户“先继续开发”实现N-029 A：0004/Schema4与内部持久文件日志，最终未过滤20261016T152343-61e5e23c和前端20261016T163726-d71f6e06均已通过。没有vault、真实回收/恢复效果、回收RPC/UI或永久清理。A验收完成后接N-029 B同卷合成效果与真实中断，C再接桥接/界面；没有新的暂停指令。

## 工程和Git

- 实际工程：`/Volumes/MacNAS-Dev/MacNAS-Workspace/MacNAS`。旧`/Volumes/Gen 8/AI方案/MacNAS`不再用于开发，不重新克隆覆盖。
- 外挂APFS开发SSD：`/Volumes/MacNAS-Dev`，卷UUID `C1755FBB-FCA8-4EA4-BEE2-AA6BF3258B6C`；写入/构建/测试前核对，离线或身份不同则停止写入。
- 同工作区Build/TestLab/DeploySandbox/Evidence仅放构建缓存、合成测试库/资料和证据，不作正式NAS数据。
- 仓库 https://github.com/snailjayxxx/MacNAS ，分支dev/bootstrap。N-029 A开始提交096183021392f796065ccb2658eaa3a06f2ad89f。最终中文阶段提交及远端核对见`git log -1`、`git status`和`../Evidence/n029-a-publication-2026-10-16.json`，不要把开始基线当最终提交；N-027/028发布收据仍保留。

## 先读

完整阅读AGENTS、PROJECT_SPEC、ARCHITECTURE、PROGRESS、NEXT_TASK，然后读[ADR-020](docs/decisions/ADR-020-bounded-file-copy.md)、[ADR-021](docs/decisions/ADR-021-recoverable-recycle-journal.md)、[ADR-022](docs/decisions/ADR-022-schema4-file-effect-foundation.md)、[桌面契约](docs/contracts/DESKTOP_API.md)、[N-028设计](docs/plans/N-028-RECYCLE-BIN-DESIGN.md)和[N-029实现步骤](docs/plans/N-029-RECYCLE-JOURNAL-IMPLEMENTATION.md)。原始规划只读保留，旧SQLite候选不是当前用户决定。

## 当前能力与边界

- Swift6、Apple Silicon/macOS15+目标，PostgreSQL18.6-only/Schema1–4，没有SQLite或其他引擎回退；当前机为macOS26.5.2，不等于15已运行验收。Intel/macOS14按用户决定以后再做。
- N-023连续浏览、N-024新建/改名、N-025/N-026有界上传下载已有；N-027新增独立目标批准的单文件复制、目标文件夹选择/预览/确认、进度/取消、原结果核对和目标重读，源始终保留。
- 复制0至16MiB单常规文件、32KiB服务端块、两端和暂存同设备，RENAME_EXCL不覆盖；来源/目标/会话/实例/批准固定并反复核对。8活动、64MiB复制暂存预留、32短期结果；跨设备明确拒绝。不是目录/批量/移动/回收站或生产大文件任务。
- 共享合成树总64MiB包括初始UTF8、全部库已发布二进制与上传/复制完整预留；发布同步转换，终止/到期仅释放未发布预留，已发布字节继续计量；会话结束或目录来源dispose清理该树，4096条目和其他预算继续生效。
- 窗口/来源中断能最终回收迟到头和已知在途能力，270次重复交错保持共享客户端open；本地所有权及预留有界、终态最多32，观察陌生ID不创建权限。传输丢失仍不能保证远端已取消，不自动重连或重交。
- 发布后同长度改写并恢复mtime的漏洞在上传/复制均已实际复现修复，rename后保存完整新标记，目录同步前后精确核对，异常uncertain且保留目标；没有回滚承诺或敌对本机进程强fencing。
- 网页只改显式Schema3合成内存树；原生及真实Node→Swift管道另用批准的新建APFS目录，具名宿主客户端接受Schema3/4并固定连接内版本。没有生产浏览器到Swift通道、NAS服务或真实登录。原上传/复制能力与短期结果仍不持久；B1/B2另在私有合成资料库实现持久回收/恢复及新批准核对，不接网页/上传复制，C再接桥接与共享计量。

## N-029 A实现与验证

最终未过滤20261016T152343-61e5e23c通过323项Swift（3252.431秒，含4项内嵌Node→Swift）、16项独立CLI管道（332.192秒）及全部CLI，测试库正常关闭。前端20261016T163726-d71f6e06通过273 Node/15静态策略/16语法/9需求负测。83份运行收据、60份完整核心、12内嵌/4独立依赖和联合108份源码一致，需求输入前后字节冻结通过。 见[阶段证据](docs/evidence/n029-a-2026-10-16.json)。

新增两张核心日志表及六个封闭验证函数，旧0001–0003不变；12表SHARE停写、完整UTC摘要/旧版本投影和精确Schema/权限检查。内部日志以原始UTF8字节隔离主体及幂等键，单事务准入64MiB、64entry历史、256operation历史与8未解决，revision/CAS防重复推进。prepared取消仅适用于A无执行者路径，armed/uncertain保留全部收费；没有observed/completed宿主setter，完成测试行由封闭SQL构造。

普通Schema4可携要求两新表完全空（含released/cancelled历史），宿主仅允许已知未启用布局；未知字段/目录及fixtures/transfer-staging均保留并拒绝。诊断DB快照可留非空元数据，不含payload。隔离3→4候选保留旧源和签名快照，导入COMMIT前后恢复、发布/resume/回退都检查。导入仅在bootstrap收紧pg_restore重建的六函数PUBLIC默认权限，之后普通验证不自动修复误授。

实际反例保留：JSON运算优先级初始化失败、套件真实TRUNCATE误授、恢复默认函数权限、协调锁/非法单分量长路径测试输入、测试漏try编译错误；二次复核又实际复现损坏版本行掩盖历史的错误回退及恢复CHECK后坏宽行绕过验证/摘要预算。修复后18项定向/16独立管道/全部CLI通过，但随后两项反例再修源码，不能以该定向收据代替最终完整回归。最终完整结果见[阶段证据](docs/evidence/n029-a-2026-10-16.json)。

完整摘要在单个repeatable-read只读快照先检查实际规范行大小及最坏预留，4,000,000字节/10秒，超限不聚合、不截断。旧jobs/events写者仍可能后续或并发增长，故新日志（包括取消）或摘要仍可能budgetExceeded；不是整库容量fencing，B真实效果前须重新审核后置证据准入。没有真实文件效果/SIGKILL/生产认证或强隔离声明。

## N-028设计验证

三份审查确认独立批准、保留式双父移动器、prepared→armed→observed→completed、缺post证据不自动接管、只读观察/写结算分离、完整持久表摘要和非空vault可携阻断。保留期到期不清扫，DB回退不撤销文件移动。模型、文件系统、持久化和交互的反例/实施清单见主设计及[证据](docs/evidence/n028-2026-10-16.json)。

抽象回收/恢复各2580状态/7726转移、96分类格、5额外边界和1151状态/1612转移配额模型通过；4错误策略获得4/6/7/6步最短反例。两项实际模型错误已修复并保留红日志，不是产品运行错误。模型只用stdlib，不调用文件效果/PG/SIGKILL。N-028新前端20261016T115907-5e66060d通过270Node/15静态/16语法/9需求负测；运行/测试/数据库/桥接依赖和联合101份源码与N-027完全一致，所以未重跑原生全量，也未宣称新271项。

## N-027保留的完整验证

未过滤原生20261016T105600-bbec24e7通过271项Swift（2033.066秒）、15项独立CLI管道及全部CLI演练，测试库正常关闭；最终前端20261016T113643-c381ba86通过270项Node、15项静态策略、16项语法和9项需求负测，联合101份源码一致。

- 原生原始记录：`../Evidence/runs/20261016T105600-bbec24e7/summary.json`及日志；271包含4项嵌入Node→Swift场景，不额外相加。77份运行源码前后一致，54份完整核心和12份嵌入依赖匹配，没有复用旧253项作新全量。
- 前端记录：`../Evidence/web-runs/20261016T113643-c381ba86/summary.json`，40份前端收据及联合101份源码在该N-027阶段收尾时匹配，当时全量后无运行源码变化；N-029已修改源码，须用新收据。5项新复制元素替身不代表浏览器。
- 修复前两项restored-mtime红例、source.dispose晚头红例、expired重放误关连接、40条终态累积、旧预期/白名单失败和首次主动中断均保留于仓库外Evidence。初过滤20261016T103502-b10c6731为FAILED且库已关闭；修复后20261016T104427-cbfc7221通过17项过滤/15项独立管道/全部CLI，再由最终全量覆盖。详见[结构化证据](docs/evidence/n027-2026-10-16.json)。

## 本轮实际浏览器验收与剩余条件

Chrome155.0.8059.85本轮52个复合项为45 PASS、7 PARTIAL，无剩余文件访问阻断。首轮CUA DOM/截图实测1440/390/320、中日文、两主题及原生200%，T05修正后中日分别等待69/79秒复测。用户自行开启扩展文件网址权限后，文本/70001字节/空文件/16MiB/超限上传、真实多块及空文件保存和逐字节/SHA256比对完成；上传/下载/复制的进行中取消、上传导航/切语言/最小化恢复/关窗/身份切换已补测。工具连接重置后续用Chrome原生控件，未改安全控制或注入模型。 详见[清单](web/tests/BROWSER_ACCEPTANCE.md)与[逐项收据](/Volumes/MacNAS-Dev/MacNAS-Workspace/Evidence/browser-n029-2026-10-16/cases.json)。

7项PARTIAL为N06（慢响应/迟到错误）、FO04（模态仍开时切身份）、FT05（关窗/身份后URL回收未分别独立验；已测下载中取消及一个替换旧Blob实际ERR_FILE_NOT_FOUND）、FT08（已补200%完整上传，精确320/390中日全流程仍缺；调试连接未附加导致重设viewport失败）、FC03（三种大小复制/中途取消已测，普通UI无法准备超限复制来源）、FC04（进行中复制关窗/导航/身份未全验）、FC05（无普通UI的uncertain核对入口）。

第四次预览13926正常退出0，8766无监听，任务标签已关闭、缩放恢复默认；首轮viewport已重置，补测重设未成功应用。首轮final-console.json=[]仅限首轮，补测DevTools截图报告8条错误，含runtime.lastError、favicon.ico404及DevTools探测被CSP拒绝；见resumed-native-console-observation.json，不称整轮控制台完全干净。网页仍为Schema3内存fixture，不连接Swift/PostgreSQL/NAS或证明Schema4回收效果。

首轮40/7/5及IAB权限拒绝保留为历史；后续成功不说明早期根因已定位。

## 用户决定与接续

- 独立阶段完成、相关测试通过且文档证据齐全后，已长期授权自动中文commit/中文说明并正常推送dev/bootstrap；无须重复确认。不合并main、不强推、不改历史，保留用户改动。
- 不用sudo，不擦盘，不读家庭/NAS正式文件，不连接蜗光集正式库，不擅改共享/账户/ACL/服务/IP/代理/防火墙/公网；新第三方组件另行准入。
- Finder/DSM文件中心继续完整流程开发。N-029 A完成验收后推进B，先单向合成回收、独立vault/宿主批准、双父FD及真实中断/只读观察/新批准结算，再做恢复；C接桥接与界面。不要直接复用自动unlink的暂存对象、自动重试队列或A的无执行者取消入口；不修改旧迁移，不将DB事务称为文件exactly-once。正式删除、永久清理、后台清扫不授权。
- 之后移动/共享权限、控制面板/网络独立只读适配器分别推进；真实配置仍需生产身份/helper/秘密存储/预演/失联恢复。SYS-09网页控制Mac桌面明确很后期，尚未开始，不启用录屏/控制或远程服务。
- 111原父项和97/13/1不变，B1/B2/C1共新增5条有限子记录至898条；SYS-09另1父7子，当前112父/97-14-1/905子。29份规划及5份来源保留原字节，不擅调优先级。
- 验证入口仍为系统`/usr/bin/python3 -X utf8 scripts/dev.py`、`scripts/dev_web.py`和`verify_requirements.py`，不安装新工具。原生/测试/内嵌Node依赖变化须新完整回归；只改网页也要匹配原生收据并新跑前端。保留实际失败、源码hash、库关闭及网页PARTIAL/BLOCKED条件，不把本轮40项PASS当成52项完整通过。

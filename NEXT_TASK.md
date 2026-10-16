# 接续任务：等待新对话恢复后开始N-027文件复制

2026-10-16最新安排：用户要求本轮收尾后暂停，准备新对话，尚未开始N-027。先读[HANDOFF.md](HANDOFF.md)，实际工程在外挂SSD，不能在旧Gen 8会话路径开发。Intel Mac/macOS14支持留待以后。文件中心继续以Finder式浏览和DSM/File Station日常流程为目标。

N-025有界上传/下载与N-026确认、进度、取消、保存及重读已接入；完整原生20261016T093753-0394608a通过253项Swift（1722.237秒）、15项独立CLI管道（257.140秒）及全部CLI，测试库正常关闭。最终前端20261016T101331-c6e3ce07通过221项Node、13项静态策略、13项语法和9项需求负测；70份运行、34份前端及联合90份源码匹配，完整核心50份、嵌入依赖9份。失败与最终证据见[PROGRESS](PROGRESS.md)及[N-025/N-026报告](docs/evidence/n025-n026-2026-10-16.json)。46项网页仍未验收；历史人工代点方案不是当前验收安排。

## N-024已实现的边界

- 新建文件夹/同目录重命名：单独的宿主写批准，开发管理员、readWrite卷绑定与已有内容批准共同约束；桌面消息不能批准根路径或扩大权限。
- 预览绑定会话、实例/代次、数据库、资料库/父路径、卷/挂载/批准和父目录/源标记；32条/30秒。mkdirat 0700与renameatx_np RENAME_EXCL只操作批准的合成目录，不覆盖已有目标。
- 短操作同步完成，结果最多32条/300秒且只在原API宿主内存。同ID不重复执行；系统调用后核对失败为uncertain，不假装回滚。notVisible不证明没有执行，关闭/超时不能自动重提或重连。没有持久传输任务或重启结果恢复，PostgreSQL18/Schema3不变。
- 第15至17个固定方法、具名客户端、file-operations控制器及实际Node→Swift测试宿主管道；网页接入输入→冲突预览→确认→结果→重读，但只修改显式内存树，没有NAS连接。
- 新未过滤全量20261016T081557-45efcba3通过239项Swift（1450.792秒）、15项独立CLI管道（252.958秒）及全部CLI；62份运行源码一致，45份完整核心与6份嵌入Node依赖匹配，测试库关闭。未复用旧224项代替本轮执行。
- 最终前端20261016T084559-012ee824通过193项Node（新增17）、11项静态策略、10项语法和9项需求负测；29份前端收据、联合79份源码匹配，全量后无运行源码变更。早期编译/模型失败、并发回执复现，以及两轮FAILED/exit -15及正常清理记录保留；第二轮确有1例/2断言错误码预期失败，不能将中断轮次当通过。

证据入口：[N-024结构化结果](docs/evidence/n024-2026-10-16.json)、[验收范围](docs/plans/N-024-ACCEPTANCE.md)、[ADR-018](docs/decisions/ADR-018-guarded-fixture-file-operations.md)、[桌面契约](docs/contracts/DESKTOP_API.md)。

## 接续工作

1. 用户明确继续后，读HANDOFF、AGENTS、PROJECT_SPEC、ARCHITECTURE、PROGRESS、[本轮范围](docs/plans/N-025-026-ACCEPTANCE.md)及[ADR-019](docs/decisions/ADR-019-bounded-fixture-file-transfers.md)，核对SSD、Git和最终证据。保留首次全量主动中断及发布后改写反例，不用旧239项或早期定向结果代替253项最终全量。
2. 推进[N-027文件复制](docs/plans/N-027-FILE-COPY-WORKFLOW.md)前先补合成树总字节配额与中断时预览能力回收。复制固定有权来源与目标、独立批准、冲突预览、分块暂存/校验、不覆盖发布与两端核对；不删除来源，不借上传/下载能力扩大权限。单文件原型和目录/跨设备/大文件任务分别设计，不只加按钮。
3. 若交付持久进度/重启恢复，设计新的版本化Schema迁移、外部效果协调日志和完整升级/恢复验收；现有数据库任务只保证事务内效果，不能直接宣称文件副作用exactly-once或给Schema3暗加表。
4. 文件操作与传输后继续复制/跨卷移动、回收站、共享权限，再按[DSM整体对照](docs/plans/DSM-FUNCTIONAL-BASELINE.md)和[控制面板/网络详细对照](docs/plans/DSM-CONTROL-PANEL-NETWORK-REFERENCE.md)推进业务。网络与服务概况先做独立只读适配器，真实配置需生产认证/helper/秘密存储/预演/失联恢复；不修改当前Mac的IP、代理、SMB、账户或防火墙。
5. 每阶段分别留下原生、真实管道、模型、静态策略、DOM和实际部署证据。核心/测试/嵌入Node依赖再变，按QA守卫重新验证，不沿用不匹配收据。

## 网页验收与运行约束

原W01–W10、T01–T08、N01–N06、F01–F08共32项，加FO01–FO06与FT01–FT08，总46项全部NOT_EXECUTED。布局、键盘/焦点、文件选择器、下载权限、对象URL、取消及窄屏不能由模型/DOM结构替身/管道勾选。用户真实移除8766站点例外后，单次正规复试仍在内容观察前被工具保存权限拒绝，根因未定；没有新权限变化，不重复同状态请求，不换浏览器、地址、端口、原始CDP或其它会话绕过。脱敏反馈已准备未发送。详见[恢复记录](docs/evidence/n011-acceptance-recovery-2026-10-16.json)与[完整清单](web/tests/BROWSER_ACCEPTANCE.md)。

只有正规浏览器入口实际允许后，沿用既有127.0.0.1:8766专项授权启动web/dist白名单静态预览并由Codex实测，结束关闭；不让用户替代完成。当前没有预览或生产HTTP/NAS监听。原生桥接测试只用已有stdin/stdout与私有Unix socket测试库。

工程实际在/Volumes/MacNAS-Dev/MacNAS-Workspace/MacNAS；写入/构建前核对APFS卷UUID C1755FBB-FCA8-4EA4-BEE2-AA6BF3258B6C。PostgreSQL18-only，无SQLite/回退、新第三方组件、正式库/家庭数据、sudo、系统服务或公网变更。用户长期授权独立阶段完成测试/文档后中文commit并正常推送dev/bootstrap，不合并main/强推/改历史。

原v0.6基线111父项及97首版/13后续/1暂不需要保持，当前基线884条子记录。用户单独新增SYS-09网页远控Mac，明确**很后期**，补充账目另7条；合并112父项、97/14/1和891条子记录。不提前开发或启用录屏、控制、系统共享/服务，见[补充账目](requirements/user-additions.json)及[后期计划](docs/plans/FUTURE-WEB-MAC-REMOTE-CONTROL.md)。

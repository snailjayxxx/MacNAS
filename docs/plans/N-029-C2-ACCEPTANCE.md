# N-029 C2：宿主独立批准的只读回收核对桥接

日期：2026-10-16开始，2026-10-17完成自动验收。状态：已实现并通过本阶段新完整原生/前端自动回归，浏览器按用户要求延期。

新未过滤20261016T224020-ea5f0bb6通过391项Swift（5589.763秒，新增17，含5项内嵌Node→Swift场景）、16项独立CLI管道（359.963秒）及全部演练，私有PG正常关闭。新前端20261017T002359-a2cfd8f7通过306 Node/17语法/15静态策略/9需求负测，无监听。74份完整核心、99份原生输入、联合126份当前源码及需求冻结匹配；隔离工作树使用Build/swift-n029-c2，没有并行干扰B2测试库。 收尾核对时间2026-10-17T00:24:01.524543+09:00。 见[阶段证据](../evidence/n029-c2-2026-10-16.json)。

## 本切片范围

宿主方法authorizeFixtureRecycleObservation需要明确confirmed，按原始主体、当前会话、实例/代次、数据库和宿主固定只读批准。它不是RPC；新CLI标志--approve-synthetic-recycle-observation默认不启用，仍由Authority的TestLab硬门限制。每API最多8个会话批准，重新批准同会话替换并撤销旧grant；end/revoke只改内存，不改日志/载荷或共享连接。恢复/回退只读模式可新批准观察，读者不能借用管理员会话。

唯一新消息observeRecycleOperation精确接受operationID标准小写UUID。无路径/确认/批准字段，无preview/commit/settle/取消/清理能力。Native许可校验在打开旧库/vault前及每个32KiB读取块检查当前会话；API构造时的实例/代次/DB/宿主锚点不可跟随重绑，响应编码后也复核。

## 数据和连接范围

传输外壳精确三字段：observationEnvelopeVersion=1、context、observation。context精确contextVersion=1、source=fixture-host、scopeID及当前userID/role/mode。scopeID以每API随机nonce作内部HMAC键、长度分帧固定、会话、实例/代次、DB/宿主、原始主体/角色/模式及批准签发时的注册字节；只作不透明防错等值标记，不是认证凭据，也不用于跨重启自动采用来源。同API/同会话/同注册重新批准保持相同标记，其他会话、API重建或注册变化必须不同。

observation仍是C1精确五字段投影，record仅十个日志字段，不输出FS stamp、inode、绝对/vault路径或grant。Native与C1均拒绝不一致计量/阶段；matchedPost必须有既存post，观察不推进completed、不释放计量。notVisible统一null记录，视图费用保持未知且需核对。

具名客户端要求Schema4/管理员，但允许只读恢复模式；固定首个有效来源标记，后续变化拒绝并保留旧视图。不创建操作所有权或执行权限。每ID一个查询、最多8个在途。借用模型适配器只在构造读取概览，显式refresh才观察；固定传入客户端，dispose不关闭/取消共享连接。显式AbortSignal和超时沿用已有连接关闭政策，不自动重连或重试。

## 实际验收与保留边界

真实Node→Swift管道分别读取0、4字节和16MiB合成回收文件：未批准拒绝，独立宿主批准后读取可见及不存在操作、通过具名客户端/模型解码，DB摘要及载荷字节保持。另11项API及5项纯DTO覆盖原始Unicode主体、角色/模式/Schema、构造锚点变化、每块会话结束、撤销、8会话上限、最终编码检查、严格公共字段和来源更新。旧回收/恢复各3次SIGKILL在本次新完整回归中重新执行。

保留4项实际早期草稿失败：错误revoke方法名、显式abort错误测试预期、Native投影缺少计量/分类约束的7个失败断言，以及只读let字段测试构造编译错误；真实定向另发现Native/C1错误耦合独立计数及RPC错误码测试预期，已修正并加入真实版本序列回归，实际4/2只读DB反例和模型红例均保留；修复、原始日志与所有后续真实运行见阶段证据，不把编译/模型结果冒充PG效果。

仅TestLab新建合成实例及当前Apple Silicon Mac，不接执行/列表/共享容量/网页DOM或生产NAS。回收计量尚未加入网页64MiB可见与传输预留；普通portable仍拒绝登记vault/日志。没有永久删除/到期清扫、真实断电、macOS15运行、跨Mac、物理池或生产认证证据；旧45 PASS/7 PARTIAL浏览器记录不用于本阶段，本轮按用户指令未使用浏览器或预览。 14项内嵌传递依赖及4项独立依赖均有精确源码收据；定向和新全量的实际运行ID及失败状态见阶段证据。

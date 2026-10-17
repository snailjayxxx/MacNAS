# 容量账目只读模型契约

N-029 C3C1先实现本地JavaScript投影与生命周期；C3C2现接通真实Schema6宿主批准、Native投影及只读桥接。26项原C3C1模型用例仍为MOCK，实际宿主证据另见[C3C2](../evidence/n029-c3c2-2026-10-17.json)。网页没有加载或提供此模块。

## 固定范围与来源

listSnapshot(value, expected)、summarize(value, expected)的expected只能含scopeID、ownerUserID、sourceID三个字段。scopeID为持久容量范围的标准小写UUID；ownerUserID按原始UTF8字节识别，不做Unicode正规化。主体限128字节且非空，不含NUL、CR或LF及不成对代理项。

sourceID为64位小写十六进制不透明等值标记，必须由调用方固定；响应必须与之逐字节相等。持久scopeID与主体相同仍不足以接受另一个来源的响应。C3C2宿主将标记固定到独立批准的API/会话/原始主体/角色/模式、实例/代次、DB/宿主/Schema和注册身份；每次批准包含新的grant身份及epoch，标记不会跨批准继承。标记不是认证凭据，不授予列表以外的权限，也不能授权执行。

## 有界完整快照

响应只含以下八个字段，字段必须为自有、可枚举的数据属性。不接受额外、缺失、继承、symbol或getter属性。验证不会调用输入getter。

|字段|取值|
|---|---|
|listVersion|整数1|
|scopeID|与expected相同的小写UUID|
|ownerUserHex|expected.ownerUserID原始UTF8字节的小写十六进制|
|sourceID|与expected相同的64位小写十六进制标记|
|evidence|固定ledgerOnly|
|limitBytes|整数67108864|
|totals|下列六项聚合|
|items|按allocationID严格递增、无重复的完整历史，最多64条|

items必须为普通、稠密数组，没有空洞、额外属性、symbol或子类。每条仅含allocationID、origin、intentSHA256、declaredBytes、state、revision和sha256。allocationID为小写UUID；origin仅upload/copy，未接管initial库存；intentSHA256为64位小写十六进制；declaredBytes为0..16777216安全整数。

|state|revision|sha256|
|---|---|---|
|reserved|1|null|
|armed|2|null|
|owned|3|64位小写十六进制|
|cancelled|2|null|

totals只含reservedBytes、unresolvedBytes、ownedBytes、allocatedBytes、historyCount和unresolvedCount。它们必须逐项等于当前完整items的计算结果：前三项分别累计reserved/armed/owned声明字节，allocatedBytes累计全部非cancelled声明字节；historyCount含cancelled，unresolvedCount统计armed条数。非cancelled总额不得超过64MiB，reserved+armed最多8条，零字节也占历史/活动槽。

这是账目读取，不是文件匹配、完整磁盘库存或可用空间测量。owned摘要不证明文件当前存在，armed零字节也会阻止增长。summary固定filesystemVerified=false、executionAuthorized=false，不提供freeBytes。回收/恢复后的owned仍收费，不从旧entry的released状态推导释放额度。

C3C2宿主从一次有界一致只读事务产生完整列表和聚合，投影前后复核同一来源，并提供只读前后摘要不变的实际管道证据。分别读取totals和items再拼接不能保证同一快照。实际新管道与完整回归收据见C3C2证据。

## 本地生命周期

createReadOnlyModel({scopeID, ownerUserID, sourceID, read, onChange?})只导出snapshot、refresh、dispose。创建不会读取；refresh只发出一次read(scopeID)，同时第二次refresh返回busy，不自动重试或取消宿主效果。

响应合格后返回深层不可变快照。同一模型中完整历史不能缩短；已有ID的origin、意图和声明字节不能改变，revision不能倒退。reserved允许前进为armed、owned或cancelled；armed只能保持或前进为owned；owned/cancelled不能复活，owned哈希不能改写。允许在两次读取间跳过armed，不把缺少中间观察误判为失败。

读取失败只返回有限错误码，保留前次列表并标记stale；任意错误消息不会进入视图。dispose清空当前列表/错误/过期标记，关闭后的迟到成功或失败均不更新视图，也不读取迟到对象的getter。reading回调立即关闭模型时，不再调用尚未发出的read。回调同步异常不妨碍busy复位。

dispose只结束本地模型，不撤销已经提交的操作，不清理宿主文件，不重建或继承批准。静态网页、宿主接口与真实Node→Swift管道由后续阶段分别接入和验证。

## C3C2宿主接线

C3C2实现Schema6的宿主批准、Native投影、context/list消息与固定客户端适配器，完整自动回归通过，提交推送以Git/外部发布收据为准；本阶段状态以[ADR-030](../decisions/ADR-030-host-approved-capacity-ledger-read.md)和[C3C2验收](../plans/N-029-C3C2-ACCEPTANCE.md)为准。

capacityLedgerContext精确空参数，仅返回已获独立宿主批准的{contextVersion:1,source:"fixture-host",scopeID,sourceID,userID,role,mode}。listCapacityLedger精确接受{scopeID,sourceID}并返回上述八字段完整列表。不给页码、游标、路径、confirmed或主体参数。标准小写UUID和64位小写hex严格验证；context/list不创建批准。重新批准后sourceID改变，旧客户端不得刷新为新来源。

createCapacityLedgerModel(client,{onChange?})借用现有具名客户端，先overview和capacityLedgerContext，再构造固定来源模型；创建不读取账目。refresh调用client.listCapacityLedger(scopeID)，sourceID来自已固定context。仅Schema6当前管理员，恢复只读模式允许；两种请求共用一个在途槽。客户端支持独立消息并不表示静态网页已经加载、提供或连接该模块。

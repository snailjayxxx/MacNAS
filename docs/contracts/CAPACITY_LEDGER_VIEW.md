# 容量账目只读模型契约

N-029 C3C1只实现本地JavaScript投影验证和读取生命周期。下述对象是拟定的宿主投影格式；当前Swift/桌面桥接没有返回该对象的方法，网页也没有加载此模块。26项Node测试中的来源标记和响应均为明确MOCK，不代表宿主批准或文件效果。

## 固定范围与来源

listSnapshot(value, expected)、summarize(value, expected)的expected只能含scopeID、ownerUserID、sourceID三个字段。scopeID为持久容量范围的标准小写UUID；ownerUserID按原始UTF8字节识别，不做Unicode正规化。主体限128字节且非空，不含NUL、CR或LF及不成对代理项。

sourceID为64位小写十六进制不透明等值标记，必须由调用方固定；响应必须与之逐字节相等。持久scopeID与主体相同仍不足以接受另一个来源的响应。未来宿主应将标记固定到独立批准的API/会话/原始主体/角色/模式、实例/代次、DB/宿主/Schema和注册身份；当前阶段没有实现该生成器、批准或客户端适配器。标记不是认证凭据，不授予列表以外的权限，也不能授权执行。

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

未来宿主须从一次有界一致只读事务产生完整列表和聚合，投影前后复核同一来源，并提供只读前后摘要不变的实际管道证据。分别读取totals和items再拼接不能保证同一快照。本阶段不声称已满足这些宿主要求。

## 本地生命周期

createReadOnlyModel({scopeID, ownerUserID, sourceID, read, onChange?})只导出snapshot、refresh、dispose。创建不会读取；refresh只发出一次read(scopeID)，同时第二次refresh返回busy，不自动重试或取消宿主效果。

响应合格后返回深层不可变快照。同一模型中完整历史不能缩短；已有ID的origin、意图和声明字节不能改变，revision不能倒退。reserved允许前进为armed、owned或cancelled；armed只能保持或前进为owned；owned/cancelled不能复活，owned哈希不能改写。允许在两次读取间跳过armed，不把缺少中间观察误判为失败。

读取失败只返回有限错误码，保留前次列表并标记stale；任意错误消息不会进入视图。dispose清空当前列表/错误/过期标记，关闭后的迟到成功或失败均不更新视图，也不读取迟到对象的getter。reading回调立即关闭模型时，不再调用尚未发出的read。回调同步异常不妨碍busy复位。

dispose只结束本地模型，不撤销已经提交的操作，不清理宿主文件，不重建或继承批准。静态网页、宿主接口与真实Node→Swift管道由后续阶段分别接入和验证。

# 网页桌面适配契约（N-011 / N-014，v1）

页面当前使用model.js的createFixtureAdapter。业务内容为合成数据、刷新重置；管理员/读者/只读恢复选择器是演示场景，不是登录。不连接Swift、PostgreSQL、NAS文件、系统账户或真实存储池。

## 当前fixture接口

每次调用校验adapter内部登记的会话；复制、跨adapter或退出后的会话无效。返回值为独立副本，修改不会改变适配层状态。该模型不构成浏览器内可防篡改的认证。

|方法|参数与结果|约束|
|---|---|---|
|beginFixtureSession / endSession|owner、reader、recovery；登记/退出会话|仅fixture，不在桥接白名单|
|overview|会话；版本、用户/角色/模式、任务计数、合成容量、unbound池|仅当前受众|
|authorizeApp|应用ID、会话|settings限管理员，preferences均可|
|listJobs|会话；任务数组|仅当前用户且app_id为空|
|submitLabelJob|id、key、value、会话；queued任务|仅开发模式管理员；幂等键绑定用户和值，冲突拒绝|
|cancelJob|任务ID、会话；当前任务|仅自己任务；恢复拒写；重复取消不改变终态|
|pollEvents|consumerID、会话、limit；事件页|consumer绑定用户，未确认可重放；limit为1至100；恢复拒写|
|acknowledgeEvents|consumerID、through、会话|仅推进到本受众已交付事件；拒绝倒退/越界；恢复拒写|
|listFiles / previewFile|虚构目录/文件ID、会话；元数据/文案键|每次直接请求验证受众；无真实路径或读盘|

任务状态沿用queued、running、waiting_for_volume、paused、failed、completed、cancelled。样例展示重试预算、错误、等待卷与终态；页面不运行工作者，也没有暂停/恢复/手动重试接口。进度0/2、1/2、2/2只描述两步检查点。

事件含sequence、job_id、revision、type、state。mergeEvents检查安全整数、类型和状态，按sequence去重，内容冲突拒绝。“全部已读”只确认实际交付上界。消费者/游标/收据仅在fixture内存中；真实持久性和事务顺序由N-010核心保证，尚未连通前端。

## N-014无监听宿主桥接

DesktopBridge绑定宿主已有的Schema 3 API和会话；createBridgeAdapter(transport)只暴露request(method, params)，不是已可直接替换fixture的客户端。静态页面没有连接此桥接。请求为：

```json
{"apiVersion":1,"requestId":"desktop-1","method":"listJobs","params":{}}
```

响应恰好包含apiVersion、requestId，以及data或error二者之一；error恰好含固定code。合法请求ID为1至128字节的ASCII字母、数字、点、短横线及下划线。无法安全解析的请求返回requestId:null；客户端不把无法关联的消息当作当前请求成功。缺失/异常传输报unavailable，版本/ID/结构不符报invalidResponse；不回退fixture。

|白名单方法|params精确字段|结果及限制|
|---|---|---|
|overview|空对象|fixture-host来源、用户/角色/模式、Schema 3、受众任务计数、逻辑估计容量及资料库；物理池unbound|
|authorizeApp|id|overview/files/storage/apps/tasks/settings/preferences；settings限管理员|
|listJobs|空对象|当前用户且app_id为空的持久任务DTO；没有工作者启动操作|
|submitLabelJob|id、key、value|仅开发模式管理员；id/key最多128字节；value最多80字符、1024字节且非空白；服务端推导标签目标|
|cancelJob|id|仅自己的任务，返回当前状态|
|pollEvents|consumerID；可选limit|limit默认50、范围1至100；消费者绑定受众，轮询更新交付上界|
|acknowledgeEvents|consumerID、through|through为0至9007199254740991的整数；只能确认本受众已交付范围|
|listLibraries|空对象|仅有权资料库的libraryID/volumeID/estimatedBytes/state，不返回根路径或内容授权|
|listFiles|libraryID；可选relativePath、maximumEntries|路径默认空，最多4096字节；条目默认1000、范围1至1000；仍需显式卷和内容批准|
|previewFile|libraryID、relativePath；可选maximumBytes|默认65536、范围1至65536；仅已批准合成文件的UTF-8纯文本|

除已列可选字段外，未知/缺失/错类型一律拒绝。所有字符串拒绝NUL；consumerID/libraryID/id/key最多128字节。协议整数不接受布尔、负数、小数或指数形式。SQL、shell、根URL、用户、角色、模式、数据库选择、会话创建、卷清单/绑定、目录批准、读者变更和套件执行不进入消息白名单。

submitLabelJob/cancelJob/pollEvents/acknowledgeEvents在恢复模式返回readOnly；轮询会写交付游标。底层仍逐次授权和执行停写锁。请求ID在宿主内一次性消费（最多4096个），重试必须新建请求ID并沿用业务幂等键；相同业务键/值返回原任务，不同值返回collision。

当前通用客户端以desktop-序号产生ID，应与一个宿主连接共同保持生命周期；在同一宿主上重新创建客户端会重置序号并可能收到replay。后续连接管理须保留序列或建立新的连接前缀，不能按每次业务调用重建适配器。

任务DTO包括id、idempotency_key、kind、owner_user/app_id（有值时）、title（标签值）、titleKey、state、attempts、max_attempts、effects、revision、checkpoint及last_error（有值时）。checkpoint只保留step/sha256/bytes；不返回原始payload和租约。overview中的taskTimestampsAvailable=false，不能自行补造updated字段。文件返回name/relativePath/text等普通内容，不能按fixture文案键渲染。事件字段继续沿用核心sequence/job_id/revision/type/state。

错误码为invalidInput、invalidResponse、unsupported、denied、readOnly、unavailable、budgetExceeded、replay、collision及现有核心固定码；未知IO/数据库诊断不回显。客户端接受的核心固定码为missingVolume、unsafePath、unsafeFile、integrity、database、busy、expired、staleState、interrupted、timedOut、cancelled、pluginFailed。

请求最多65536字节、16层和4096值节点；响应最多1048576字节，客户端最多65536值节点。拒绝重复解码键、非UTF-8及非法代理项。CLI `macnas bridge fixture --source SYNTHETIC_INSTANCE --user fixture-owner` 只使用调用方已有的stdin/stdout，按换行分帧；CRLF可用。stdout只含业务JSON，stderr只含固定启动/帧错误。超长帧/超过4096帧/非空EOF截断输出错误后退出；其它错误逐帧继续。完整环境由scripts/dev.py准备，不连接既有正式库。

尚待实现：生产认证、可靠浏览器传输/超时/重连、完整业务DTO验证、真实文件授权及DOM接线。宿主会话从现有fixture API显式取得，不能视为生产认证；close/退出撤销会话。系统副作用继续走现有授权门槛。静态页connect-src为none，不自动连接HTTP/WebSocket。设计依据见[ADR-008](../decisions/ADR-008-desktop-message-bridge.md)。

## 状态与恢复

localStorage键macnas.desktop.preferences.v1只含version、locale、theme和允许应用的窗口几何；损坏/不可访问时使用默认值。会话/业务数据/令牌不保存，此偏好不属于可携实例配置。数据库仍为PostgreSQL 18-only。

身份切换退出旧会话、关闭窗口、清空数据通知，并通过epoch丢弃旧响应。恢复模式可看任务/文件，拒绝创建、取消和事件游标修改。生产认证、浏览器接线和跨Mac会话均未验收。

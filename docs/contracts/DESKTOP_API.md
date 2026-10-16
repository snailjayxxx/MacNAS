# 网页桌面适配契约（N-011至N-026，v1）

页面当前使用model.js的createFixtureAdapter。业务内容为合成数据、刷新重置；管理员/读者/只读恢复选择器是演示场景，不是登录。不连接Swift、PostgreSQL、NAS文件、系统账户或真实存储池。

## 当前fixture接口

每次调用校验adapter内部登记的会话；复制、跨adapter或退出后的会话无效。返回值为独立副本，修改不会改变适配层状态。该模型不构成浏览器内可防篡改的认证。

|方法|参数与结果|约束|
|---|---|---|
|beginFixtureSession / endSession|owner、reader、recovery；登记/退出会话|仅fixture，不在桥接白名单|
|overview|会话；版本、用户/角色/模式、任务计数、合成容量、unbound池|仅当前受众|
|authorizeApp|应用ID、会话|settings限管理员，preferences均可|
|listJobs|会话；任务数组|仅当前用户且app_id为空|
|listJobsPage / discardJobPage|params、会话；版本化页 / 本地释放|默认50、1至100；UTF-8编号排序、会话及页大小绑定、60秒整链、一次性、最多128待用/消费记录；只读可查询|
|submitLabelJob|id、key、value、会话；queued任务|仅开发模式管理员；幂等键绑定用户和值，冲突拒绝|
|cancelJob|任务ID、会话；当前任务|仅自己任务；恢复拒写；重复取消不改变终态|
|pollEvents|consumerID、会话、limit；事件页|consumer绑定用户，未确认可重放；limit为1至100；恢复拒写|
|acknowledgeEvents|consumerID、through、会话|仅推进到本受众已交付事件；拒绝倒退/越界；恢复拒写|
|eventConsumerStatus|consumerID、会话；版本化状态|不创建消费者或推进位置；无本受众行与他人行都notVisible/null；恢复可读|
|listFiles / previewFile|虚构目录/文件ID、会话；元数据/文案键|每次直接请求验证受众；无真实路径或读盘|

任务状态沿用queued、running、waiting_for_volume、paused、failed、completed、cancelled。样例展示重试预算、错误、等待卷与终态；页面不运行工作者，也没有暂停/恢复/手动重试接口。进度0/2、1/2、2/2只描述两步检查点。

事件含sequence、job_id、revision、type、state。旧mergeEvents通用函数仍保留，网页已改用N-018有界待确认视图；“确认本批通知”只使用实际交付上界，成功后清理展示。消费者/游标/收据仅在fixture内存中；真实持久性和事务顺序由N-010核心保证，尚未连通网页。

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
|listJobs|空对象|完整数组或明确拒绝；最多4096条，另受输出/响应字节预算约束；当前用户且app_id为空|
|listJobsPage|可选pageSize、cursor|pageSize默认50、范围1至100；仅当前用户；返回版本化实时任务页，见下文|
|submitLabelJob|id、key、value|仅开发模式管理员；id/key最多128字节；value最多80字符、1024字节且非空白；服务端推导标签目标|
|cancelJob|id|仅自己的任务，返回当前状态|
|pollEvents|consumerID；可选limit|limit默认50、范围1至100；消费者绑定受众，轮询更新交付上界|
|acknowledgeEvents|consumerID、through|through为0至9007199254740991的整数；只能确认本受众已交付范围|
|eventConsumerStatus|consumerID|第13个固定方法；只读观察本受众ack/delivered，无权或不存在均notVisible/null，恢复可读|
|eventConsumerObservation|consumerID|第14个固定方法；只读返回observationVersion=1、context及上述status，见N-022|
|listLibraries|空对象|仅有权资料库的libraryID/volumeID/estimatedBytes/state，不返回根路径或内容授权|
|listFiles|libraryID；可选relativePath、maximumEntries|路径默认空，最多4096字节；条目默认1000、范围1至1000；仍需显式卷和内容批准|
|listFilesPage|libraryID；可选relativePath、pageSize、cursor|第12个方法；默认空路径及50项，1至100，目录标记/授权绑定继续；见N-019|
|previewFile|libraryID、relativePath；可选maximumBytes|默认65536、范围1至65536；仅已批准合成文件的UTF-8纯文本|
|previewFileOperation|libraryID、kind、name；可选parentPath、sourceName|第15个方法；只预览createDirectory/rename，需独立宿主写批准|
|commitFileOperation|operationID、confirmed=true|第16个方法；只应用已登记预览，同宿主回执有界，不覆盖目标|
|fileOperationStatus|operationID|第17个方法；只读查询本会话短时预览/结果，不授予提交权限|
|previewUpload|libraryID、name、totalBytes；可选parentPath|第18个方法；独立宿主上传批准、冲突预览，0至16MiB|
|beginUpload|transferID、confirmed=true|第19个方法；只接受原会话ready预览，固定私有暂存，不创建库内假成品|
|appendUpload|transferID、offset、parts|第20个方法；最多32KiB原始数据，1至16段规范base64，偏移与背压绑定|
|finishUpload|transferID、sha256|第21个方法；完整接收后双重摘要核对，不覆盖发布；可能uncertain|
|beginDownload|libraryID、relativePath|第22个方法；固定打开的已批准常规单链接文件，0至16MiB|
|readDownloadChunk|transferID、offset|第23个方法；每块最多32KiB，编码成功后才推进，源变化拒绝|
|transferStatus|transferID|第24个方法；原会话有界状态或notVisible；不赋予写/读/取消能力|
|cancelTransfer|transferID|第25个方法；原主体清理私有暂存/句柄，已发布文件不回滚|

除已列可选字段外，未知/缺失/错类型一律拒绝。所有字符串拒绝NUL；consumerID/libraryID/id/key最多128字节。协议整数不接受布尔、负数、小数或指数形式。SQL、shell、根URL、用户、角色、模式、数据库选择、会话创建、卷清单/绑定、目录批准、读者变更和套件执行不进入消息白名单。

submitLabelJob/cancelJob/pollEvents/acknowledgeEvents在恢复模式返回readOnly；轮询会写交付游标。底层仍逐次授权和执行停写锁。请求ID在宿主内一次性消费（最多4096个），重试必须新建请求ID并沿用业务幂等键；相同业务键/值返回原任务，不同值返回collision。

当前通用客户端以desktop-序号产生ID，应与一个宿主连接共同保持生命周期；在同一宿主上重新创建客户端会重置序号并可能收到replay。后续连接管理须保留序列或建立新的连接前缀，不能按每次业务调用重建适配器。

任务DTO包括id、idempotency_key、kind、owner_user/app_id（有值时）、title（标签值）、titleKey、state、attempts、max_attempts、effects、revision、checkpoint及last_error（有值时）。checkpoint只保留step/sha256/bytes；不返回原始payload和租约。overview中的taskTimestampsAvailable=false，不能自行补造updated字段。文件返回name/relativePath/text等普通内容，不能按fixture文案键渲染。事件字段继续沿用核心sequence/job_id/revision/type/state。

错误码为invalidInput、invalidResponse、unsupported、denied、readOnly、unavailable、budgetExceeded、replay、collision及现有核心固定码；未知IO/数据库诊断不回显。客户端接受的核心固定码为missingVolume、unsafePath、unsafeFile、integrity、database、busy、expired、staleState、interrupted、timedOut、cancelled、pluginFailed。

请求最多65536字节、16层和4096值节点；响应最多1048576字节，客户端最多65536值节点。拒绝重复解码键、非UTF-8及非法代理项。CLI `macnas bridge fixture --source SYNTHETIC_INSTANCE --user fixture-owner` 只使用调用方已有的stdin/stdout，按换行分帧；CRLF可用。stdout只含业务JSON，stderr只含固定启动/帧错误。超长帧/超过4096帧/非空EOF截断输出错误后退出；其它错误逐帧继续。完整环境由scripts/dev.py准备，不连接既有正式库。

尚待实现：生产认证、实际浏览器传输/重连、真实文件授权及DOM接线。宿主会话从现有fixture API显式取得，不能视为生产认证；close/退出撤销会话。系统副作用继续走现有授权门槛。静态页connect-src为none，不自动连接HTTP/WebSocket。设计依据见[ADR-008](../decisions/ADR-008-desktop-message-bridge.md)。

## N-015具名客户端

bridge-client.js提供createDesktopClient({transport, closeTransport?, timeoutMs?, maximumPending?})和prepareLabelJob(value)。Node可require该模块；未来浏览器加载须先有model.js。当前不加入index.html或静态预览路由，网页仍显式使用fixture。

客户端先调用overview()固定宿主userID/role/mode，其余业务方法不接受会话、角色或身份参数。overview/authorizeApp/listJobs/listLibraries与对应白名单方法同名；submitLabelJob接收{id,key,value}，cancelJob接收任务ID，pollEvents接收consumerID和可选limit，acknowledgeEvents接收consumerID及through，listFiles/previewFile接收上表的参数对象。所有方法最后可传{signal}；未知字段、显式null默认值及错误参数类型拒绝。close()幂等，closed可读。

|结果|额外DTO校验|
|---|---|
|overview|来源/版本/角色/模式/语言固定集合，安全计数，逻辑容量与有权资料库估计值之和一致；后续身份/角色/模式变化拒绝并关闭|
|任务|仅当前用户且无套件受众；label或fixtureHash，固定titleKey，尝试不超过1至8的预算，revision正整数；completed须有已完成检查点/一次效果，其余状态不能伪装提交；不接受payload/租约/未知字段|
|事件|序号升序且不重复，revision正整数，类型与状态匹配；相同序号重放内容须一致|
|资料库|逻辑ID唯一、UUID格式、已知卷状态、安全估计值；元数据不产生内容授权|
|目录项|相对路径必须恰好为请求目录加文件名；拒绝碰撞、越界和错误种类；普通文件必须有安全字节数，目录省略bytes；UTC日期需有效|
|文本|libraryID/relativePath与请求一致，实际UTF-8字节数等于声明且在预算内；HTML及NUL只作为文本数据|

返回对象递归冻结，文件名和标题不能作为i18n键。标签提交响应须保持业务key/value，幂等重试允许返回原任务ID；取消响应须对应请求ID并为终态。

默认等待15000ms、并发32；配置范围1至60000ms、1至128。超时返回timedOut，主动取消/关闭使未完成调用返回cancelled，后续调用unavailable。无效响应、传输失败或身份变化使连接失效，迟到响应丢弃。普通业务拒绝保留连接。AbortSignal通过transport的第二个上下文参数传递，closeTransport可选回调负责实际通道清理；不提供自动重连/重试，也不保证不配合的传输被强制结束。

每个客户端使用独立随机请求前缀，通用适配器可选requestIdPrefix（1至96个允许ASCII字符，默认desktop），单适配器最多4096次请求，不能绕过宿主4096总数限制。新业务操作调用prepareLabelJob一次，保留其不可变id/key/value；超时不能证明数据库未提交，重试沿用原业务键和值。客户端不把意图写入localStorage。

每客户端至多32个消费者，每消费者最多100条未确认事件，并串行轮询/确认。只能确认已交付序号或重复确认已知位置，确认成功后才清理；它不代替宿主数据库受众与交付上界校验。详细取舍见[ADR-009](../decisions/ADR-009-typed-desktop-client.md)。

## N-016任务页

新增第11个白名单方法listJobsPage；具名客户端调用listJobsPage({pageSize?,cursor?}, {signal}?)，不接受显式null默认值。首调用省略cursor；后续页传回同一客户端所得cursor和相同pageSize。N-017静态页面接入fixture版本，真实客户端来源只在Node/管道验证。

返回值恰好为{pageVersion:1, order:"id-utf8", consistency:"live", pageSize, items, nextCursor}。items沿用任务DTO且最多pageSize条；有继续游标时为满页，终页nextCursor显式null。没有total字段；overview统计独立聚合，不是列表快照。按原始UTF-8 ID字节升序，不按语言、JS UTF-16或Unicode规范化排序。翻页间可见提交的新状态；插入在已越过ID之前的记录要从第一页重新读取。

cursor为随机小写UUID、宿主内存一次性能力，不是SQL afterID。宿主每API最多128个待用游标和128个消费墓碑；从第一页开始整条链60秒单调时间，到期不续期。绑定会话、用户、角色、模式、实例、数据库和页大小，客户端不能选择这些上下文。退出清除待用游标，重启/恢复不能延续。保留墓碑时重复使用报replay；未知或被清理令牌denied；已知到期expired；格式错误invalidInput。错误上下文不消费合法所有者令牌。Scope恢复后仍可能在原期限继续，没有撤权epoch承诺。

查询/后置会话校验/DTO编码/字节预算失败不消费游标，重试必须换请求ID。成功编码后传输丢失可能已消费，需显式重启扫描。只读恢复允许此内存查询游标；pollEvents/acknowledgeEvents修改数据库交付位置，仍拒绝。

客户端最多保留128条未结束链，同一令牌请求串行，校验页内与跨页字节递增、受众和精确DTO。完成继续请求后移除旧令牌；expired/denied/replay也移除，关闭清空；没有自动翻页、重试或本地持久化。旧listJobs不悄悄截断：超过4096条或字节预算返回budgetExceeded。详情见[ADR-010](../decisions/ADR-010-bounded-job-pages.md)。

## N-017任务展示来源和控制器

task-pages.js在model.js之后加载，提供async createFixtureTaskSource(api, session)和async createClientTaskSource(client)，后者须显式传入已创建的具名客户端；缺失报unavailable，不创建fixture回退或网络连接。来源公开context、overview、page、cancelJob、submitLabelJob、discardCursor、close及closed。close拥有原会话/客户端生命周期，调用方不能继续旧来源；窗口只dispose控制器。

来源page({pageSize?,cursor?})校验原页后返回恰好为{viewVersion:1,pageSize,tasks,nextCursor}的展示页。tasks是固定投影：id、name、kind、state、attempts、maxAttempts、revision、steps、lastError。name={kind:"text"|"key",value}；只有固定key进入词典，text始终原文。没有payload、幂等键、租约、路径或updated；overview只含固定上下文、active/completed和taskTimestampsAvailable:false，不按已读取页补造统计。

createTaskPager({source,pageSize=50})接受以上来源，pageSize为1至100；snapshot()返回冻结的{phase,items,pageNumber,hasNext,error,requiresReload}，不暴露游标。reload/next/cancelJob返回Promise，失败为固定ServiceError并设置error/显式重读状态；cancelJob限本页任务并使用服务端结果更新该行。dispose幂等清空当前页并忽略迟到结果，不关闭共享来源。没有自动聚合所有页、快照或自动重试承诺。

具名客户端新增同步discardJobPage(cursor)，仅释放本地已见令牌，无RPC；进行中报busy，未知/已丢弃返回false，错误格式invalidInput。fixture同名方法为async discardJobPage(cursor,session)，实际释放其本地内存令牌并检查会话。来源discardCursor是尽力清理；进行中的页在迟到结果完成后再释放。真实宿主待用令牌仍按N-016上限/时限清理，反复重读可能触发budgetExceeded。

网页任务窗口每页3条，首页2项编号顺序预览；搜索和状态过滤仅当前页。空页、无本页匹配、末页、加载、修改及失败分别显示，失败页注明是上次结果并禁用继续/修改；创建后从首页重读，取消后更新当前行及独立统计。身份/窗口/模态框和刷新代次检查用于防止旧结果覆盖，但实际DOM/焦点仍待浏览器验收。

HTML/白名单只新增task-pages.js，bridge-client.js仍不加载/不静态提供，connect-src仍为none。当前fixture权威队列仍在内存，显示页上限不是生产数据库规模证明。详细范围见[ADR-011](../decisions/ADR-011-task-page-presentation.md)及[验收记录](../../web/tests/BROWSER_ACCEPTANCE.md)。

## N-018有界通知展示

notification-view.js在model之后、desktop之前加载，导出async createFixtureNotificationView(api,session,{consumerID,capacity?})、async createClientNotificationView(client,{consumerID,capacity?})及notificationTaskName(event,tasks,translate)。必须显式传入来源，无连接创建/fixture回退。consumerID为1至128个UTF-8字节，capacity默认100、范围1至100；未知字段、getter和错类型拒绝。来源overview固定用户/角色/模式，恢复模式在调用提供者前拒绝poll与ACK。

返回视图公开context、snapshot()、poll()、acknowledge()及dispose()。snapshot为冻结的{phase,items,capacity,full,confirmedThrough,error,ackRetryRequired,unavailable}；items仅含sequence、jobID、revision、type、state，倒序显示、最多capacity条。精确字段、正安全整数、升序原始交付、类型/状态及重放内容均检查。confirmedThrough只代表当前视图已收到成功响应的位置，不是数据库消费状态查询；初始0不推断持久ACK。

同一视图及同提供者/consumerID串行操作，进行中锁表最多32项；跨独立客户端/fixture包装器仍需宿主协调。poll请求完整capacity以容纳重放；满额明确budgetExceeded并停止请求，不截断未确认内容或伪ACK。合并超预算保留旧内容并报错，非法/冲突响应隔离视图。acknowledge无外部位置参数，捕获当前已加载最高序号；失败保留原批及目标并阻止poll，显式重试始终同一位置，成功true才清空并推进。

ACK可能已提交但成功响应丢失。连接可用时可显式重试相同位置；客户端超时关闭时保留未解决内容，旧视图不可继续。当前协议没有消费状态查询/安全重连核对；不能以新连接轮询为空推定旧批已确认，也不自动重连或回退fixture。dispose清理并忽略迟到成功/失败，不回滚数据库ACK、不删除事件/收据、不关闭借用的共享会话/客户端。调用方身份切换需先dispose视图，再关闭旧会话。

名称仅查当前页加2项预览，辅助函数最多接受102行；固定名称key可以翻译，普通标题保持文字，缺失用普通通知文案，不按jobID翻译或全量取任务。静态界面容量100、仅显示已加载待确认数；确认成功后清空，本批之外等待手动刷新，关闭面板保留批次。没有定时后台轮询。

静态HTML/白名单只增加notification-view.js，bridge-client.js仍不加载/提供，connect-src为none。Node/Swift管道证明不等于网页连接数据库或DOM验收。详见[ADR-012](../decisions/ADR-012-bounded-notification-view.md)、[范围](../plans/N-018-ACCEPTANCE.md)及[回家N01–N06](../../web/tests/BROWSER_ACCEPTANCE.md)，W/T/N均待测。

## N-019目录页与客户端继续链

listFilesPage参数为{libraryID,relativePath?,pageSize?,cursor?}，默认空路径及50条，每页1至100。wire结果恰好为{pageVersion:1,order:"name-utf8",consistency:"directory-stamped-live-metadata",libraryID,relativePath,pageSize,items,nextCursor}；items沿用普通文件元数据，终页nextCursor显式null，有继续令牌时必须满页。没有total/搜索/外部after名称/任意根路径参数。

服务端每次完整有界扫描，最多8192项、名称共1MiB、单调5秒，保留最多101份候选及有界碰撞摘要。UTF-8名称排序；页外不安全条目同样拒绝。超过预算整体budgetExceeded，时间检查timedOut；5秒不是OS强制中断I/O的保证。目录标记在翻页和扫描/编码前后核对，变化staleState并要求重读；文件原地修改可只改变文件元数据，因此后页内容是live，不能称为目录或文件内容快照。

宿主每API最多64个待用/64个消费墓碑，整条链60秒单调寿命；绑定会话/实例/数据库/用户/角色/模式、资料库/路径/大小及卷/挂载/介质/批准/修订/内容reader身份。格式错误invalidInput，范围或未知位置denied，已知到期expired，保留墓碑重放replay。授权与路径读取/编码后再核对，成功编码/复查才消费原位置；响应传输丢失可能已消费，需要显式重读。无数据库Schema变化或持久目录令牌。

具名客户端listFilesPage(params,options?)校验精确页形状、上下文、名称/相对路径、安全字节数、日期、普通类型、页内碰撞及UTF-8页内/跨页递增；最多64条目录链，和任务链独立，同令牌串行。staleState/expired/denied/replay/missingVolume移除本地位置，不自动重试或聚合全部页。discardFilePage(cursor)同步本地释放，进行中busy、未知false，无RPC，不能释放宿主预算。close清空并拒绝迟到结果，继续受既有并发/超时/4096请求上限约束。

恢复只读可查询同进程既有批准目录，不能扩大批准；新宿主/恢复实例没有自动目录授权。实际Node子进程管道由Swift测试宿主先显式批准新建合成目录，不为生产CLI添加自动批准入口。静态fixture页面尚未接入本方法，主机客户端仍不加载/提供，HTML/CSP/白名单不变。详见[ADR-013](../decisions/ADR-013-bounded-directory-pages.md)、[合成资料库契约](FIXTURE_STORAGE_API.md)及[N-019范围](../plans/N-019-ACCEPTANCE.md)。

## N-020目录展示来源与控制器

directory-view.js在model之后、desktop之前加载。async createFixtureDirectorySource(api,session,{monotonicNow?}?)借用已注册会话；async createClientDirectorySource(client)借用显式创建的具名客户端，不创建连接/会话或失败回退。context固定source/userID/role/mode；libraries/page/preview/discardCursor/dispose及closed公开。dispose不endSession或close客户端，身份所有者负责最后统一关闭共享提供者。

libraries()最多1024个不可变{libraryID,state,estimatedBytes}，没有根路径；具名值来自原宿主授权元数据，估计是逻辑值，不是物理剩余容量。fixture的state为synthetic、estimatedBytes为null。摘要与目录页分别读取，不拿当前页行数补总数/容量。

page({libraryID,relativePath?,pageSize?,cursor?})默认空目录及50条、1至100，校验路径/上下文/精确页/名称碰撞/UTF-8页内跨页递增后返回{viewVersion:1,libraryID,relativePath,pageSize,items,nextCursor}。items仅{name,relativePath,kind,bytes,modifiedAt,canPreview}；目录bytes为null，宿主modifiedAt仍来自有效UTC日期，fixture为null。没有翻译键、宿主根、total或伪造日期。来源64条链、首请求有界预留、同令牌串行，丢弃仅清理本地位置，不释放宿主预算；失败不自动重试/扩大扫描上限。

fixture是新固定树而非旧翻译键文件数组，页原始consistency为synthetic-fixed-directory，共享根8项、空/嵌套及私有样例；60秒整链、64待用/64消费或过期记录。它对已注册会话每次检查，读者看共享、管理员含个人库；不证明真实目录标记、卷修订、内容批准或8192项全扫描。真实宿主页继续使用N-019的directory-stamped-live-metadata，不改变后端语义。

preview({libraryID,relativePath})固定最多65536 UTF-8字节、仅txt/md/json/csv/log；结果{libraryID,relativePath,text,utf8Bytes}校验上下文及实际字节数。createDirectoryPager({source,pageSize=50})只允许预览当前页可预览文件；宿主继续独立检查读取授权与实际大小，不因列表声明取得更大权限。所有内容作为普通文字。

控制器snapshot为冻结的{phase,libraryID,relativePath,items,pageNumber,hasNext,error,requiresReload}，phase为idle/loading/ready/previewing/error/closed；不暴露游标。open({libraryID,relativePath?})切换上下文并清旧页；reload从头、next替换，preview(relativePath)仅本页。参数错误/并发/非法继续可同步抛ServiceError；异步读取错误固定code并保留标注的旧页、禁用继续/预览，待显式重读。open可在旧读/预览中失效旧代次，迟到预览返回null，迟到页只清理位置，不覆盖新状态；dispose清空并拒绝迟到结果，不关闭共享来源。filterFiles只接最多100项、all/directory/file和最长256字符查询，仅查当前页普通名称。

N-020历史静态窗口采用每页3项、下一页替换。N-023已在此来源上新增独立文件浏览器，当前交互见下文；基础createDirectoryPager的本页语义保留，不能把旧N-020的3/3/2预期用于新界面。实际浏览器功能、视觉/焦点与F01–F08全部待测。见[ADR-014](../decisions/ADR-014-directory-page-presentation.md)、[范围](../plans/N-020-ACCEPTANCE.md)及[回家清单](../../web/tests/BROWSER_ACCEPTANCE.md)。

## N-021通知消费位置只读观察

原生jobEventConsumerStatus(consumerID:session:)与固定eventConsumerStatus消息读取现有event_consumers表，不创建消费者、不推进交付/确认、不删除事件/收据。数据库用只读事务的一条受众限定SELECT观察两个位置，读取后及最终编码后复查会话、实例/数据库、用户原始字节、角色/模式。允许开发、只读恢复、回退恢复；不授予写入或文件权限。

请求参数恰好{consumerID}，ID为1至128个UTF-8字节，拒绝NUL/CR/LF和非法代理项。结果恰好{statusVersion:1,consumerID,visibility,acknowledgedThrough,deliveredThrough}。visibility=visible时两个位置是安全非负整数、ack不大于delivered；notVisible时两位置显式null，覆盖未创建和他人/套件行，不作为全局不存在的证明。自己的空消费者可visible/0/0。没有owner、数据库名、宿主路径、任意翻译键或来源认证凭据。

具名客户端eventConsumerStatus(consumerID,{signal}?)需要已有overview，恢复模式可直接查询。精确校验/冻结结果，同客户端同ID与poll/ACK串行，沿用既有等待/并发预算。查询不分配本地delivery消费者、不回填ack/seen、不清旧通知批，也不赋予新连接ACK权限；可观察超过32个不同ID而不耗尽32个交付消费者槽，但在途仍受原并发预算限制。关闭/超时/取消丢弃迟到响应，无自动连接/重试或fixture回退。

fixture同名方法借用注册会话，读取已有内存受众ack/delivered而不写Map；不存在与其它受众同样notVisible/null，恢复可查，持久性不由fixture证明。网页未调用此方法，notification-view未提供旧批核对入口。即使新宿主查询显示ACK已推进，旧批仍未自动确认；现有overview还不能证明跨连接同实例/同数据库，不能把查询成功或空轮询当作安全重连/批次清理。详见[ADR-015](../decisions/ADR-015-read-only-event-consumer-status.md)及[验收](../plans/N-021-ACCEPTANCE.md)。

## N-022来源上下文与显式只读核对

jobEventConsumerObservation / eventConsumerObservation精确返回{observationVersion:1,context,status}。context精确为{contextVersion:1,source:"fixture-host",scopeID,userID,role,mode}；scopeID为64位小写十六进制等值标记，绑定当前合成集群配置、数据库及事件表身份、实例/generation、用户原始字节及权限/模式。原始路径、数据库名、目录OID和密钥不输出；恢复、换库、重建事件表或权限变化失配。标记仅用于可信合成管道防错，不是未知宿主认证或生产安全凭据。

宿主首次事件操作固定上下文；后续poll/ACK/status/observation必须匹配。事件写入使用通过校验并捕获的原StateStore，不在执行时重新解析可变绑定。操作前后再次检查，后检查失败不回滚已提交的原库操作，但不会把这次写入改投另一个新库。没有强fencing或对任意外部修改的原子授权承诺。

具名客户端eventConsumerObservation(consumerID,{signal}?)要求已有overview，严格验证上下文、嵌套status及受众一致性；同ID与poll/ACK/status串行，查询不分配交付消费者或授予ACK权限。来源改变即失效，超时/取消/关闭不接受迟到结果。

notification-reconciliation.js的async createClientReconciliationView(client,{consumerID,capacity?})借用已有客户端和有界通知视图；初始化先复制严格数据选项再异步捕获来源。ACK失败固定原consumerID、原批和目标，显式reconcile(另一个已初始化候选客户端)只读核对。全上下文相同、开发模式、可见且ack覆盖原目标时reconciliation.outcome="acknowledged"；不足/不可见为unresolved，错源/模式/权限或查询失败为固定错误。并发/迟到/dispose不能覆盖当前状态。

核对结果不清旧items、不推进confirmedThrough、不清ackRetryRequired、不采用候选连接、不发ACK或自动重试。静态HTML和预览白名单均不加载/提供此模块或bridge-client.js；没有网络连接、fixture回退或生产认证接线。完整连接采用与旧批UI协调仍未完成。见[ADR-016](../decisions/ADR-016-fixture-event-source-context.md)。

## N-023连续文件浏览

file-browser.js在directory-view.js之后、desktop.js之前加载。createFileBrowser({source,pageSize=50,maximumLoaded=1000,maximumHistory=64})只接受既有显式目录来源，页大小仍1至100，加载上限不超过1000，历史2至128。来源和共享会话由调用者所有，dispose仅释放自身页位置/历史/选择，不关闭来源或客户端。

open/back/forward/up/reload成功后才提交历史，失败保留原位置与已加载行、标注错误并要求重读；新导航截断前进历史。next累加当前目录的已加载页，保留前页条目；达到窗口预算停止继续，不静默丢弃项目。续页仍受后端目录标记、60秒链和原有扫描预算约束；没有total、文件系统快照或全目录搜索承诺。

snapshot新增visibleItems、selectedItems、selectedPaths、activePath、导航能力、limitReached、maximumLoaded、settings及previewPhase；不公开游标/内部历史。configure接受search/filter/sort/direction/locale，搜索与自然名称/大小/类型/时间排序只作用于已加载项目，文件夹优先，未知值最后。相同设置不打断预览。select支持toggle/range，selectAll仅选择已显示项目，过滤清理隐藏选择，普通名称/内容不作翻译键。

preview仅限当前目录已加载且可预览文件，可预览前页已加载条目；直接使用同一受控source而非绕过授权。上限仍64KiB纯文本，未知类型只可选择/看详情。导航、选择变化、过滤或dispose丢弃迟到预览。窗口/身份切换清理状态；资料库授权集合变化重建浏览器，避免保留已撤销库历史。

窗口接入位置侧栏、面包屑、导航、列表/图标、多选与详情、键盘和已加载范围提示。共享根8项首次全部显示；基础页模型的小页单元测试不决定产品加载量。connect-src仍none，网页仍仅合成fixture；真实DOM/键盘/窄屏与F01–F08继续未执行。服务端全目录排序、真实NAS连接、上传/下载/改名/复制/移动/回收站及生产认证均需后续实现。见[阶段计划](../plans/N-023-FINDER-STYLE-FILE-BROWSING.md)和[DSM控制面板/网络对照](../plans/DSM-CONTROL-PANEL-NETWORK-REFERENCE.md)。

## N-024文件操作预览与结果

原生authorizeFixtureLibraryMutations是宿主专用批准，不在消息白名单。须开发模式管理员、readWrite绑定和已有内容批准；只读根批准不自动获得写入。预览绑定会话、实例/generation、数据库配置、卷/介质/挂载/清单修订、读/写批准及父目录/源标记，重批或上下文改变失效。

previewFileOperation的kind只接受createDirectory/rename；parentPath默认空，最多127段且总4096字节，名称为单分量、最多255 UTF-8字节，完整目标也不超过4096字节/128段。rename须sourceName，创建时wire省略sourceName（不接受null）。只允许同父目录改名，不允许任意根、覆盖、移动或删除。结果精确为{previewVersion:1,operationID,intent,state,expiresInSeconds}，intent精确为{libraryID,parentPath,kind,sourceName,name}，创建的sourceName在响应中显式null。state为ready/conflict/unchanged；只有ready登记30秒预览，其余expiresInSeconds=0且无提交能力。

commitFileOperation要求真正的JSON布尔true，不能以1或字符串替代。operationID是小写UUID；提交不再接受可修改的意图。原生用mkdirat 0700、renameatx_np RENAME_EXCL，不退回普通覆盖式rename。结果精确为{resultVersion:1,operationID,state,intent,error}；completed时error=null，failed/uncertain时为固定错误，notVisible时intent/error均null。status还可返回ready；ready/notVisible都不证明操作成功或没发生。

每API最多32个预览/30秒、32个回执/300秒，单调时钟。相同ID在本宿主内重复提交只回已有结果；同会话且当前批准/身份一致才可读取。系统调用成功后的验证/fsync失败为uncertain，不能称为回滚；同ID丢失/退出/重启不重新执行，回执不是持久队列。预览编码失败不登记，提交响应编码失败可能已应用，显式查询原ID核对，禁止自动重复新意图。

具名客户端增加previewFileOperation、commitFileOperation、fileOperationStatus与本地discardFileOperation。仅本客户端获得的ready预览可提交一次，查询不创建该权限；同ID提交/查询串行，32个本地预览限额与在途预留。输入在await前复制，响应严格校验精确字段、意图与状态。普通传输失败/超时仍关闭客户端，不自动新建连接；固定业务错误遮蔽成功响应时，存活连接可显式只读核对。

file-operations.js提供校验、显式来源和createController。prepare/commit/check保留原预览ID/意图，异常进入uncertain并禁止重复提交；只显式check查询，notVisible/ready继续未解决。dispose丢弃迟到响应，不关闭借用来源、不撤销已应用动作。directory-view来源可带fileOperations；旧只读测试提供者缺少相关方法时为null，不自动创建写入源。目录来源dispose清理其操作源；窗口控制器dispose不关闭共享目录/客户端。

静态fixture的操作确实修改同一内存目录树，目录改名保留子树、父修订使旧续页和旧预览stale；并发同ID在异步授权返回后再检查已完成回执，避免后到提交覆盖成功结果。界面新建/重命名经输入、预览、确认，冲突可编辑，成功后重读；失败与不确定结果分别显示，读者/恢复禁用。HTML在directory-view之前加载file-operations.js，白名单仅增该静态模块；CSP connect-src仍none，主机客户端/授权入口仍不加载或提供。

原生真实落盘与网页内存演示分别验证。新增FO01–FO06全部待实际浏览器验收；没有真实NAS/生产认证、系统helper/ACL/SMB、持久文件任务、跨Mac/断电或规模承诺。详见[ADR-018](../decisions/ADR-018-guarded-fixture-file-operations.md)。

## N-025 / N-026文件传输

原生额外批准`authorizeFixtureLibraryUploads`仅供宿主，不进入消息白名单，也不由内容读取或mkdir/rename授权推导。需要开发管理员、readWrite卷绑定与已有内容批准；下载沿用现有读取范围。意图中的资料库最多128字节、名称单分量最多255字节，parentPath可省略为空但不能显式null；完整相对目标最多4096字节/128段。上传不接收可更换目标、任意宿主路径、覆盖选项或用户身份。

上传预览精确为`{transferVersion:1,transferID,intent,state,chunkBytes:32768,expiresInSeconds}`，intent恰好为`{libraryID,parentPath,name,totalBytes}`。state=ready/conflict，过期时间分别30/0秒；仅ready登记能力。transferID为小写UUID，整个后续流程保持原ID。确认必须JSON布尔true，数值1、字符串、缺失和多余字段拒绝。

状态精确为`{transferVersion:1,transferID,state,direction,libraryID,relativePath,totalBytes,transferredBytes,chunkBytes:32768,sha256,lastChunkSHA256,error}`。state为ready/uploading/downloading/completed/cancelled/failed/uncertain/notVisible；notVisible所有业务元数据显式null，不能作为未执行证明。其余direction为upload/download；完成字节数不能超过totalBytes，completed/uncertain须传完且有64位小写十六进制摘要，uncertain仅上传；failed/uncertain携带固定错误，其他状态error=null。

appendUpload的parts是1至16段规范base64，每段最多2048原始字节，非最后段必须2048字节，每段字符串最多2732字节。除最后块外原始总数必须32768；禁止空块、跳偏移、更换最后块内容。最后一个相同块可显式重放；更早块不缓存。零字节上传不调用append，finish携带空文件SHA256。既有65536字节请求、4096字节单字符串、1MiB响应及4096次连接请求上限全部不变。

最后块缓存只服务进行中/已完成的会话；取消、失败和uncertain会清理块内容，不承诺其后重放append或读取旧块，原结果仍按短期状态规则查询。释放本地能力只移除客户端所有权，不等于宿主取消；当前控制器在明确开始下一次操作时丢弃上一条本地记录，普通连续45次传输已有模型验证。

下载块精确为`{transferVersion:1,transferID,offset,nextOffset,parts,eof,chunkSHA256,sha256}`，每次最多32768原始字节，最后块的sha256是整文件摘要，其余显式null。仅空文件使用空parts，eof=true且nextOffset=0。最后块可明确重放；成功编码和最终来源复查后才推进偏移/摘要，不按同名路径重新打开替换文件。EOF后缓存是历史块，不能当作新的实时读取。

每API最多8个活动预览/上传/下载，共享上传声明大小预留64MiB。单文件16MiB是原型限制；预览30秒、活动空闲60秒、绝对30分钟，按请求回收。最多32条终止结果保留300秒，只在原API宿主。私有暂存0700/0600、单链接、同设备，发布采用RENAME_EXCL并同步文件/目录；清理只移除仍属于自己的名字。进程崩溃遗留不会自动清扫，结果/配额不跨重启，不冒充持久任务或磁盘剩余空间调度。

具名客户端增加同名八个方法及本地`discardTransfer`。previewUpload/beginDownload获取本客户端的能力；beginUpload(transferID)、appendUpload({transferID,offset,parts})、finishUpload({transferID,sha256})只使用原本地意图和进度，且同ID串行。状态查询不能接管陌生能力，也不从观察偏移自动续传；写入回复不明后禁止自动再次append/finish。最多40个本地已登记头/结果及在途预留，显式discard或close释放本地记录，宿主另有8/32预算。超时/传输断开关闭客户端，不重连；同一仍存活连接可明确查询原结果。

directory-view来源新增fileTransfers；静态来源仍使用原内存树，新增二进制字节和父修订，上传发布后旧分页失效，文本按严格UTF-8解码。file-transfers提供原意图、进度、取消和不确定结果控制器；每块等待I/O与接收端并让出事件循环。file-transfer-view的有界Blob接收端最多16MiB，完整校验后提供需用户点击的保存链接；替换/取消/失败/窗口关闭释放内存和对象URL，不自动触发浏览器下载。

网页新增本机单文件选择、目标名编辑、冲突预览、30秒确认、进度/取消、同宿主核对及匹配目标目录重读。目录导航不会把上传目标改到另一个目录；身份/窗口关闭丢弃迟到结果但不假称回滚已发布文件。HTML加载自有sha256、file-transfers和file-transfer-view，connect-src仍none；不提供bridge-client、主机授权接口或暂存文件的静态路由。

N-025实际合成APFS/Node→Swift管道、N-026内存/DOM结构替身与实际浏览器分别留证。FT01–FT08全部待测；没有GB级、断点/重启恢复、生产认证数据通道、跨设备发布或文件审计。见[ADR-019](../decisions/ADR-019-bounded-fixture-file-transfers.md)及[验收范围](../plans/N-025-026-ACCEPTANCE.md)。

## 状态与恢复

localStorage键macnas.desktop.preferences.v1只含version、locale、theme和允许应用的窗口几何；损坏/不可访问时使用默认值。会话/业务数据/令牌不保存，此偏好不属于可携实例配置。数据库仍为PostgreSQL 18-only。

身份切换退出旧会话、关闭窗口、清空数据通知，并通过epoch丢弃旧响应。恢复模式可看任务/文件，拒绝创建、取消和事件游标修改。生产认证、浏览器接线和跨Mac会话均未验收。

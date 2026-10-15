# 网页桌面适配契约（N-011 / N-014 / N-015 / N-016 / N-017 / N-018 / N-019，v1）

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
|listLibraries|空对象|仅有权资料库的libraryID/volumeID/estimatedBytes/state，不返回根路径或内容授权|
|listFiles|libraryID；可选relativePath、maximumEntries|路径默认空，最多4096字节；条目默认1000、范围1至1000；仍需显式卷和内容批准|
|listFilesPage|libraryID；可选relativePath、pageSize、cursor|第12个方法；默认空路径及50项，1至100，目录标记/授权绑定继续；见N-019|
|previewFile|libraryID、relativePath；可选maximumBytes|默认65536、范围1至65536；仅已批准合成文件的UTF-8纯文本|

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

## 状态与恢复

localStorage键macnas.desktop.preferences.v1只含version、locale、theme和允许应用的窗口几何；损坏/不可访问时使用默认值。会话/业务数据/令牌不保存，此偏好不属于可携实例配置。数据库仍为PostgreSQL 18-only。

身份切换退出旧会话、关闭窗口、清空数据通知，并通过epoch丢弃旧响应。恢复模式可看任务/文件，拒绝创建、取消和事件游标修改。生产认证、浏览器接线和跨Mac会话均未验收。

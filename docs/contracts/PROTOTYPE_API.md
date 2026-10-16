# 无监听的原型业务API（P02）

`PrototypePlatformAPI`是Swift业务层；没有HTTP、XPC、网络端口或生产登录系统。`beginFixtureSession`仅为合成用户测试签发进程内会话，不能作为真实身份认证。每次调用按平台配置重新核对用户/角色，读者不能借业务接口写配置、标签或签发套件授权。

## 业务方法

- overview：版本1、逻辑用户/角色、中日语言、数据库schema和恢复模式；不返回秘密引用或系统凭据。
- setLanguages / writeLabel / enqueue：管理员+开发模式校验，受实例共享写锁保护；幂等任务键落在PostgreSQL。
- issueAppGrant / appState / putAppState：不透明随机授权绑定实例、套件、注册epoch、权限和期限。每次重新验证，数据库连接使用该实例该套件的角色，套件不能指定任意schema、数据库或SQL。
- runSample：只运行编译内置白名单中的两个自研可执行文件；普通结果经授权复核后才写入该套件状态表。文件索引还需显式授权实例host-binding/fixtures下的合成目录，返回相对路径。

授权撤销/卸载/重新注册会使旧epoch失效，旧授权不会因重新启用而复活。已经进入受保护数据库调用的操作先结束，撤销随后生效；撤销不是对已提交数据的回滚。运行中受监督的示例会在循环检查到撤权时终止，不发布其结果。

进程运行时有时间预算和输出字节上限，失败不拖垮核心，未引入自动无限重启。输出文件检查存在轮询间隔，不能承诺绝不发生瞬时磁盘写入超量。没有CPU/内存硬限制，也没有OS沙箱。可信示例与启动用户拥有相同OS权限，不能据此开放第三方原生插件。

样例环境只含最小PATH、临时HOME与语言设置，剔除数据库连接配置、会话和导出私钥。数据库role和文件系统进程权限仍是不同边界；清理环境变量不是文件系统隔离。

read_only_recovery和rolled_back_recovery模式在业务层先拒绝写入；恢复数据库的默认事务只读提供独立负测。默认事务只读不是抵御本机管理员/数据库owner的防篡改机制，生产写权限切换仍未实现。

## N-010：Schema 3 的任务与事件

submitLabelJob 接受管理员当前身份，创建属于该用户的标签任务。durableJobs、cancelJob、jobEvents、acknowledgeJobEvents 只操作调用者自己的受众；管理员也不能通过这些接口指定另一个用户。事件页最多100条，确认不能超出已交付范围。poll 会保存交付上界，因此只读恢复不能调用 poll/ack；durableJobs 仍可读取。

submitAppValueJob、appJobs、cancelAppJob、appJobEvents、acknowledgeAppJobEvents 使用现有套件票据，每次核对实例、epoch、权限及期限。套件不能选择另一个受众或核心 SQL；已提交的应用任务只能写自己应用的状态表。应用角色不能直接访问新任务或 outbox 表。已入队的数据任务由可信核心管理，临时 UI 票据失效不自动撤销已接受的工作；取消需要调用对应任务接口。

这些任务/事件方法目前支持Schema3/4；N-010初始实现为Schema3。历史 enqueue 接口只保留给 Schema 1/2 的第一轮测试；Schema3/4拒绝该旧入口，使用有载荷及作用域的 submit 方法。旧 legacy fixture 任务不由新工作进程领取。

DurableJobQueue 是可信核心执行器，不传给 native 样例。内置工作只有测试标签、应用私有状态、合成文件摘要；没有任务脚本、网络发送、系统授权或真实卷绑定。workOne/CLI work-once 供当前合成测试手动驱动，不安装常驻服务。具体一致性、租约和事件语义见 ADR-004。

## N-016：有界只读任务查询

jobStatistics(session:)按当前用户受众在PostgreSQL聚合active/completed/total；jobPage(pageSize:cursor:session:)返回当前用户的实时任务页，pageSize默认50、范围1至100。只读恢复可调用，继续令牌仅修改宿主内存，不修改数据库事件消费位置。durableJobs/appJobs保留完整数组语义，超过4096条或字节预算明确拒绝，不悄悄截断。

DurableJobQueue.page(audience:afterID:pageSize:)供可信核心使用；afterID不是桌面输入。桌面通过API内存游标绑定会话、实例、数据库、用户、角色、模式和页大小。跨页不持有一致性快照；继续令牌短期、一次性、有界，重启或传输丢失可能需要重扫。详细预算及失败语义见[ADR-010](../decisions/ADR-010-bounded-job-pages.md)和[桌面契约](DESKTOP_API.md)。

## N-021：通知消费位置只读查询

jobEventConsumerStatus(consumerID:session:)返回EventConsumerStatus：consumerID、visibility、acknowledgedThrough、deliveredThrough。只读事务限定当前用户受众，自己的行visible，未创建或其它用户/套件行统一notVisible及空位置；不创建消费者，不改变交付/确认，也不删除事件/收据。恢复及回退只读允许查询，poll/ack继续拒写。

实例/数据库、注册会话、用户原始字节、角色和模式在查询前后与最终编码后复核；上下文变化拒绝结果。核心可保留Int64，桌面消息拒绝超出JS安全整数的值。DurableJobQueue.consumerStatus的受众参数仅供可信核心，桌面不能选择受众。该结果是一次观察，不是跨连接来源证明或自动重连/清理旧批授权。详见[ADR-015](../decisions/ADR-015-read-only-event-consumer-status.md)及[桌面消息契约](DESKTOP_API.md)。

## N-029 C2：宿主独立批准的只读文件效果观察

|宿主API|作用与边界|
|---|---|
|authorizeFixtureRecycleObservation(session:confirmed:)|confirmed必须true；仅新建TestLab、Schema4、原始UTF8唯一管理员。固定当前会话/角色/模式、API构造时实例/代次/DB/宿主和登记字节；允许当前只读恢复模式的新observe批准。不是RPC。|
|revokeFixtureRecycleObservation(session:)|只撤销该会话内存批准，不写DB/载荷；endSession同样撤销。|
|observeFixtureRecycleOperation(operationID:session:)|标准小写operation UUID，返回严格C1正文投影；每许可/读取块和最终编码复核。只分类，不移动/取消/结算或释放费用。|

每API最多8个会话批准。同会话重新批准替换并撤销旧grant；失败清理只移除仍属于该Entry的注册，不撤销后来的替换。管理员会话之间、读者、已结束/撤销会话、旧实例/代次/DB/宿主/登记不能借用批准。新明确批准不重新运行旧文件效果。

直接宿主调用返回正文RecycleOperationObservation；DesktopBridge唯一新消息observeRecycleOperation另包装版本化来源context，具名客户端固定该来源和借用连接。ID、观察结果及scopeID都不授予回收/恢复/结算权限，宿主批准无消息签发入口。数据字段、原始主体、安全整数、独立operation/entry计数及生命周期见[正文契约](RECYCLE_OBSERVATION_MODEL.md)、[桌面契约](DESKTOP_API.md)和ADR-026。

本阶段有实际只读API、CLI开关及Node→Swift0/4字节/16MiB证据，新391 Swift/16独立管道和306 Node通过；旧C1纯模型计数耦合反例、修复和完整新收据见[C2证据](../evidence/n029-c2-2026-10-16.json)。这不是生产认证/网页接线、共享容量、执行/列表/清理RPC或浏览器验收。

# ADR-015：通知消费位置的只读查询

2026-10-15（Asia/Tokyo），N-021。PostgreSQL 18、Schema 3和现有表结构不变，查询功能本身不新增依赖、监听、文件授权或生产身份。用户回家后的临时静态预览沿用既有8766专项授权并独立记录。为“ACK可能已提交，但响应丢失”的已知限制先补查询能力；自动重连、来源证明、旧批协调和网页接线另行处理。

## 数据库与权限

DurableJobQueue.consumerStatus仅按consumerID和固定受众条件读取event_consumers主键行。沿用BEGIN READ ONLY、5秒锁等待及10秒语句预算，不使用队列mutation、临时表、行锁、INSERT、UPDATE或DELETE。返回同一SELECT可见的ack_sequence与delivered_sequence，既不创建消费者也不推进交付/确认位置，不删除通知/收据。它是当次读取时的观察，后续其它消费者仍可改变持久位置，不是永久快照或跨实例凭据；单行查询不等于生产吞吐验收。

当前用户有权行返回visible，无本受众行一律notVisible，包含“尚未创建”和“其它用户/套件已占用此ID”两种情况。两者不作存在性区分，位置均为null，不泄露owner_user/app_id、宿主路径或数据库名；回显的consumerID是调用方已提供的数据。自己的空消费者可见且位置0/0，与不可见不同。全局ID碰撞后的写操作仍由原事务授权拒绝。

PrototypePlatformAPI.jobEventConsumerStatus借用已有会话，绑定当前API的实例身份及generation、数据库、会话、用户原始UTF-8、角色及模式；查询后与最终DTO编码后都复查。API构造时验证完整实例，查询时仍验证队列Schema 3；前后复查只读取相关身份/绑定/会话元数据，避免为每次复查重复启动完整结构验证。允许的模式仅开发、只读恢复和回退恢复，未知模式拒绝。退出、角色/模式、实例或数据库变化拒绝返回旧观察，响应预算失败也无业务副作用。poll/ACK仍按原规则拒写。最终检查后仍存在并发变化窗口，不能当成OS隔离、主机认证或强fencing。

## 固定消息与具名客户端

第13个固定方法eventConsumerStatus参数恰好{consumerID}，不接收through、身份、模式、数据库或任意查询。ID为1至128个UTF-8字节，拒绝NUL/CR/LF和非法代理项，引用字符只作为数据。

wire结果恰好为{statusVersion:1,consumerID,visibility,acknowledgedThrough,deliveredThrough}。visible的两位置必须为0至9007199254740991的安全整数且ack不大于delivered；notVisible两位置必须显式null。原生查询保留Int64，消息编码拒绝超出JS安全范围的值，不截断、不降精度、不回显原始数据库诊断。

具名客户端eventConsumerStatus(consumerID,options?)要求已有overview，恢复模式也允许。严格校验精确字段/版本/上下文/可见性/空值/整数后递归冻结。与同客户端、同消费者的poll/ACK串行；不同消费者仍受原有并发/等待上限约束。查询不分配本地交付消费者、不填ack/seen、不提升ACK权限、不清旧通知批，不受已查询ID总数而无限保留状态。关闭/超时/取消丢弃迟到结果，没有新连接、自动重试或fixture回退。

## 合成演示与后续

model.js增加同名只读fixture方法，使用已有注册会话/受众的内存ack/delivered，不新建消费者，恢复模式可读。它不证明数据库持久性；实际持久性、响应扣留后重启查询、数据库强制只读及无写副作用由Swift/PostgreSQL和独立Node管道验证。

当前notification-view.js未增加核对入口，query返回成功也不会改变旧视图的confirmedThrough或items。显式新客户端没有旧seen，查询位置不能授权它确认任意through。即使查询到ack已推进，仍不能在缺少同实例/同数据库/同用户/同消费者来源证明时据此清理另一个视图；overview现有上下文不足以完成该证明。

HTML、CSS、desktop.js及静态白名单不变；bridge-client仍不加载/提供，connect-src为none，网页仍为内存演示。用户现已回家，授权静态预览可手动显示，但用户截图已核实8766的“浏览：始终允许”，但工具仍拒绝内容访问、原因未知；W/T/N/F全部待测。实际DOM、布局、焦点、键盘、翻译质量、生产身份/服务、真实NAS、macOS15运行、跨Mac/物理盘及规模继续未验证。验证与失败记录见[N-021验收](../plans/N-021-ACCEPTANCE.md)及[结构化证据](../evidence/n021-2026-10-15.json)。

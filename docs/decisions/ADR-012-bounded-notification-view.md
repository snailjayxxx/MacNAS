# ADR-012：有界待确认通知与响应不确定性

2026-10-15（Asia/Tokyo）。N-018收紧通知展示；Swift、SQL、Schema 3和核心测试不变，无依赖、监听或外发渠道。原state.events保留已读历史且无限累积，改为只展示有上限的待确认批次。

notification-view.js提供async createFixtureNotificationView(api, session, options)和createClientNotificationView(client, options)。options只接受consumerID和capacity（默认100、范围1至100）。显式来源先读overview固定来源、用户、角色及模式；客户端自身校验后续宿主上下文，fixture每次检查登记会话。没有自动创建连接或fixture回退。视图借用会话/客户端，dispose不关闭共享提供者；宿主会话仍由任务来源/调用方管理，身份切换先dispose通知再关闭旧来源。

公开context、snapshot()、poll()、acknowledge()及dispose()。事件固定投影为sequence、jobID、revision、type、state，递归冻结。验证正安全整数、UTF-8逻辑编号、精确事件字段、类型/状态关系、严格升序交付和相同序号内容一致；显示时按序号倒序。无时间、payload、文件路径或任意翻译键。任务名仅查当前任务页与2条预览（辅助函数最多102项），找不到用普通通知文案，不反向全量取任务；普通标题即使恰好为jobHash或含HTML也保持文字。

视图只保留最多capacity条未得到确认成功响应的事件，不保留已确认展示历史。snapshot包含phase、items、capacity、full、confirmedThrough、error、ackRetryRequired、unavailable。confirmedThrough只表示本视图收到成功响应的位置，初始0不代表已读取数据库消费状态；items数量只是本地已加载待确认数，不是全部未读或数据库总量。界面清理不删除数据库事件、收据或审计记录。

满额停止轮询并提示先确认；不自动ACK、不淘汰未确认记录。每次轮询仍请求完整capacity，因为服务端从持久ACK之后重放，使用剩余容量可能反复只取到旧记录而无法前进。原批次和新批次先验证再原子合并，超容量明确budgetExceeded并保留旧内容；服务端仍可重放未显示记录。非法或冲突响应隔离该视图并禁止确认，避免根据不可信数据推进。

同一视图和同一提供者/consumerID串行轮询与确认，共享进行中锁表最多32项；dispose不提前释放未结束操作的锁。具名客户端另有既有32消费者/100未确认预算，视图不能提高它。调用方须为不同用途分配消费者ID；跨客户端、进程或不同fixture包装器没有JavaScript全局锁，仍由宿主数据库范围/事务校验兜底，不承诺协调多个独立前端共同消费同一个ID。

acknowledge不接受外部through，首次只捕获当前实际显示的最高已交付序号；收到true才推进confirmedThrough并清理本批。失败保留原批次和原目标，暂停poll，等待显式重试相同位置；重试不能偷偷带上后来事件。fixture原ACK无返回值，适配器只在它成功完成后规范为true；具名客户端必须收到宿主true。

提交成功后响应可能丢失。若连接仍可用，明确重试同一目标利用核心持久ACK幂等性，不能把错误当作回滚。若超时/非法响应关闭了客户端，保留未解决批次及未确认标记，禁止旧视图继续，不自动重连。新客户端没有旧seen集合，当前协议也没有读取消费ACK状态的方法；即使新轮询为空，也不能据此宣称旧界面已确认。安全的重连状态核对需后续单独设计；dispose只丢弃展示，不宣称ACK或撤销已提交数据库操作。

phase为idle/polling/acknowledging/ready/error/closed。失败只保留固定错误码；关闭清空并废弃代次，迟到成功/失败不能填回或推进。恢复模式在调用提供者前拒绝poll与ACK，因为poll也写交付游标。读者可消费自己的事件；服务端仍校验消费者受众及已交付上界。

静态页容量100，“确认本批通知”成功后清空，后续通知等待手动刷新；关闭通知面板保留同一批次，身份切换清理旧视图。概览/任务变化可在无进行中请求、未满额且无待重试ACK时刷新通知，没有后台定时轮询。HTML/静态白名单只增加notification-view.js；bridge-client.js仍不加载或静态提供，connect-src仍为none，网页继续内存演示。

Node模型、静态HTTP及真实Swift/PostgreSQL管道验证范围见[验收记录](../plans/N-018-ACCEPTANCE.md)。W01–W10、T01–T08及新增N01–N06全部等用户回家实测；无DOM、焦点、布局、翻译质量或生产浏览器传输验收。核心源码完全一致时复用N-016全量186项，过滤解析器轮次不冒称全量回归。生产身份、macOS15运行、真实磁盘、跨Mac、规模及OS服务仍未验证。

后续N-021增加[消费位置只读查询](ADR-015-read-only-event-consumer-status.md)，读取现有表的受众ack/delivered而不写消费者或推进位置，恢复可读。它仍不提供跨连接来源证明或通知旧批自动核对/清理；历史N-018断连视图保持未解决，不能把新查询当作已完成安全重连。

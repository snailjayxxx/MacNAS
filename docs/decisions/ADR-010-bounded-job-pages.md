# ADR-010：有界任务查询、统计与实时继续游标

2026-10-15（Asia/Tokyo）。延续Schema 3及PostgreSQL 18，不增加表、索引、依赖或监听。网页仍使用内存fixture，浏览器窗口验收继续等用户回家。

原overview读取受众全部任务后再统计。改用一次受众约束的count聚合，只返回active、completed和total；桌面overview保留原字段，active包含queued/running/waiting_for_volume，completed只计已完成。legacy任务及其他用户/套件均排除。统计避免传输全部任务，但数据库仍需扫描匹配行，不能声称常数时间或生产吞吐。聚合语义参考[PostgreSQL 18聚合函数](https://www.postgresql.org/docs/18/functions-aggregate.html)。

新增listJobsPage，固定pageVersion=1、order=id-utf8、consistency=live，每页默认50、范围1至100。核心SQL按唯一id COLLATE "C"升序，用相同排序规则比较afterID，最多读取pageSize+1条判断后续页；不使用OFFSET或自然语言排序。UTF-8原始字节保留，组合/分解Unicode ID各自独立。SQL值经过既有quote，客户端没有SQL、排序、受众或数据库参数。[LIMIT要求明确排序](https://www.postgresql.org/docs/18/queries-limit.html)，[C排序规则按编码字节比较](https://www.postgresql.org/docs/18/collation.html)。本轮不增加专用索引，也不承诺现有索引在任意部署排序规则下必然命中。

实时页不是一致性快照：各次查询看到当时已提交数据。插入在当前ID之前的任务需重新从第一页读取；之后插入的任务可能出现在后页；后页可显示更新后的状态。没有持有跨请求SQL事务或完整结果缓存。统计和列表也不是同一时间的快照。

继续令牌是宿主内存中生成的随机小写UUID，不包含或接受外部排序键。每个PrototypePlatformAPI最多128个待用游标，另有最多128个已消费墓碑；到期回收。游标绑定该API实例的登记会话、实例UUID、数据库名、用户UTF-8身份、角色、模式及页大小。桌面仅提供当前用户任务页；核心仍可由可信调用方查询固定套件受众。重建API/进程或恢复实例不能延续旧令牌，退出移除该会话待用令牌。

从第一页查询开始计单调时钟60秒的整条链寿命，继续读取不续期。Scope/页大小不符拒绝且不消费原令牌；未知令牌denied，格式错误invalidInput，已保留墓碑的重放replay，已知过期令牌expired。过期清理或墓碑被上限淘汰后为denied，仍不会复活。Scope变更后又恢复的令牌可能在原期限内继续，本机制没有身份撤权epoch，不能代替生产认证或跨进程fencing。

游标注册表在锁内串行执行查询，查询后重新验证会话/实例/绑定，再完成DTO与响应预算校验，成功才消费旧令牌并登记下一枚。失败可用新请求ID重试原令牌；一旦响应已成功编码而在传输中丢失，令牌可能已消费，调用方应显式重新扫描，不能承诺分页重试幂等或自动恢复。与任务提交的持久业务幂等键不同，分页令牌不写数据库或localStorage。单API串行查询是一项原型取舍，不是并行吞吐设计。

查询使用只读SQL事务，lock_timeout为5秒、statement_timeout为10秒，继续保留底层30秒进程与4MB输出预算；桌面响应仍最多1MiB。旧jobs/listJobs至多读取4097行判定4096条数组上限，超过返回budgetExceeded，不返回部分数组；在该上限以内仍受字节预算限制。旧调用应迁移到显式逐页读取，不提供自动收集全部页的客户端方法。

具名客户端严格验证页版本/顺序/实时标记、请求页大小、任务DTO及受众，比较原始UTF-8字节并检查跨页递增；终页nextCursor必须显式null，有继续令牌时必须满页。客户端最多保留128条未结束链，只能继续本客户端收到的令牌，同一令牌一次一个请求。成功消耗本地令牌，expired/denied/replay也清除；其它可重试业务错误保留。关闭清空内存；不自动翻页或重连。

测试只用新合成实例，包括4096/4097条边界、私有受众、Unicode/引号ID、实时插入/取消、只读恢复、游标时限/容量/重放/退出/绑定变化、编码失败不消费和真实Swift管道。没有30TB任务规模、生产认证、浏览器DOM、真实磁盘或跨Mac性能证明。大目录分页与目录变化检测另行设计，不能复用数据库任务游标。

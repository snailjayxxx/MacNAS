# ADR-016：可信合成管道的通知来源上下文与显式核对

2026-10-16，N-022。沿用PostgreSQL 18与Schema 3，不新增DDL、依赖或监听。目标是区分“同一来源的新宿主”与“用户名相同但实例/数据库不同”，补足N-021只有消费位置、没有来源上下文的限制。最终未过滤224项Swift及15项实际CLI管道通过，网页/生产接线仍未完成。

## 来源上下文

上下文精确包含contextVersion=1、source=fixture-host、scopeID、userID、role、mode。scopeID是64位小写十六进制的等值标记，输入采用UTF-8字节长度分帧，绑定当前配置的私有测试集群socket、数据库名及数据库OID、event_consumers关系OID、实例UUID/generation、用户原始字节、角色及模式。数据库和关系目录标识只读取得，不新建业务行。

利用已有显式注入的合成签名种子，通过HKDF派生用途独立的HMAC密钥；不新增宿主密钥文件或在只读查询中写状态。上下文不输出数据库名、目录OID、socket路径、宿主路径或种子。更换测试密钥、集群配置、数据库/事件表重建、恢复/升级候选、实例代次或受众权限/模式都会保守失配。同配置集群、同数据库/事件表及实例身份不变时，重开API、会话或CLI宿主仍相等；路径迁移、集群替换和密钥轮换不承诺保持相等。

这是调用方显式信任合成管道中的防错上下文。HMAC标记本身不是生产认证、授权票据或可携身份；客户端没有藉此认证未知主机，恶意传输仍不可信。目录OID不是跨集群的全局身份，也没有强fencing或管理员篡改保护。生产认证/安全传输另行设计。

## 读取与消息边界

原生jobEventConsumerObservation与固定第14个消息eventConsumerObservation只接受consumerID，返回observationVersion=1、context和N-021精确五字段status。不允许请求指定scope、用户、数据库或through。查询保留missing/foreign统一notVisible/null的语义；恢复可读而poll/ACK仍拒写，不推进消费者位置或增加收据。

会话、原始受众、角色/模式、实例/generation、数据库与关系身份在读取及最终投影后复查。DesktopBridge在首次事件操作固定来源，后续poll/ACK/status/observation不随数据库或权限变化自动换源。提交后校验失败并不意味着数据库回滚；前后检查不是对任意外部配置篡改的原子授权或系统隔离。

事件写入单独捕获通过上下文检查的StateStore及队列，操作执行时不再解析可变绑定。重绑发生在操作中时，后检查拒绝结果，但旧库可能已经提交；新库不接收这次操作。此边界由原生重绑测试证明，不能用“返回拒绝”推断旧库没有提交。

具名客户端严格校验版本、精确嵌套字段、上下文与overview受众一致、scope格式及status范围。同消费者与poll/ACK/status串行，不增加本地ACK权限或无限保留消费者。观察到来源改变即失效，超时/关闭/取消丢弃迟到结果；不创建连接、自动重试或回退fixture。

## 显式核对模型

notification-reconciliation.js只提供createClientReconciliationView，借用显式提供的具名客户端与既有有界通知视图，不接静态HTML。初始化捕获不可变选项/受众/来源；ACK失败保留原批次、consumerID及原目标。调用方只能显式提供另一个已初始化的候选客户端进行reconcile。

仅当上下文全字段相同、原模式为开发、消费者状态可见且持久ack覆盖原目标，结果才是acknowledged。不可见或位置不足返回unresolved；错源、权限/模式变化、读取失败、超时或关闭保留未解决并给出固定错误。核对期间不允许本模型同时poll/ACK/再次核对；dispose代次阻止迟到结果恢复旧视图。

acknowledged只表示这次同源只读观察足以覆盖原目标；核对不清空旧items、不推进confirmedThrough、不消除ackRetryRequired、不接管候选连接，也不发送ACK。双方连接生命周期仍由调用方管理。显式采用新连接和旧批展示协调留待后续，不能冒称已完成安全自动重连。

## 证据边界

模型测试、Swift/PostgreSQL与独立CLI管道分别记录。源文件变化需要新的未过滤全量回归，不能复用N-021的217项摘要；网页32项仍全部待测。首次新16项模型中15项因通用消息白名单缺少新方法而失败，修复后16项通过；失败元数据保留在仓库外Evidence/n022-precheck。实际完整结果另见N-022验收与证据，不以本设计文本替代测试。

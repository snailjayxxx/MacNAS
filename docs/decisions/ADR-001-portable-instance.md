# ADR-001：便携实例与宿主状态分离

状态：开发原型已编码，实测见 PROGRESS 和 Evidence；生产切换未开放。

导出目录固定包括 `instance.json`、`config/platform.json`、`state/database.json`、`state/platform.pgdump`、两个套件的 `apps/<id>/manifest.json` 与 `app-data/<id>/schema.json`、`logical-storage/references.json`，以及 `manifest.json` / `manifest.sig`。

逻辑用户、角色、语言、逻辑卷 ID 与相对资料库路径保留；新目录重新生成 Host Binding。外部 35TB 为合成容量引用，不读取或复制真实文件。套件工作数据位于 PostgreSQL 的各自 Schema，随同一快照导出。

`host-binding`、`secrets`、`sessions`、可重建缓存和恢复日志不随导出复制；Keychain/TCC/SMB/系统服务必须重授权。测试只使用虚构秘密标记。未知配置字段拒绝，原型不声称能自动识别任意业务字段中人为塞入的秘密。

导出使用 `pg_dump --format=custom --no-owner --no-privileges --no-tablespaces`；不复制运行中的 PostgreSQL 数据目录或 WAL。恢复先验证可信宿主公钥的 Ed25519 签名及所有文件哈希、布局和版本，再将快照导入独立合成库，保留旧库与旧实例。

只有可信签名的自生成快照可以进入本轮恢复。PostgreSQL 提醒还原备份可能执行源方的 SQL，因此不能将 unsigned hash 当作包来源证明。正式包签名、数据库最小角色和隔离导入仍需产品化。

恢复默认预览；只有 `--confirm-create` 才创建明确的新目录。该参数只确认合成测试目录和测试库的建立，不授权正式系统操作。导入后数据库默认只读，生产 cutover 恒拒绝。

故障时保留 `.partial-*`，完整目标不存在就不能上线；重试创建新 staging。同一导出到同一已验证只读目标可幂等重试。尚未实现部分文件断点续传、孤立恢复库自动回收、真实断电日志恢复或跨主机 fencing；需要在下一阶段继续实现。

## N-009 后续实现（2026-10-15）

ADR-003补充签名宿主日志、文件级校验重试、新库身份和数据校验、Schema1→2隔离升级与非破坏性回退。统一停写已覆盖受控配置API与全部已知数据表。上文缺少journal的描述属于第一轮状态；字节级续传、真实断电、生产身份/服务注册和跨Mac强fencing仍未完成。

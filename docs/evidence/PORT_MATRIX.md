# PORT-01–16 本轮证据范围

统一证据：bootstrap-2026-10-15.json；原始日志在工作区 Evidence/runs/20261015T114957-24e3faa9/。以下都是原型范围的结果，不代表整条生产验收完成。

|用例|本轮状态|实际覆盖|仍未完成|
|---|---|---|---|
|PORT-01|LOCAL_MAC_PASS|不同中日文绝对路径恢复配置、逻辑用户/角色、两个套件数据、任务状态和PostgreSQL库|另一台Mac、另一个SSD|
|PORT-02|MOCK_PASS|新的hostID和数据库名重新绑定；源Host Binding不复制|真实UID/GID/系统用户映射|
|PORT-03|LOCAL_MAC_PASS|数据库运行中pg_dump；未提交事务期间导出后两行保持原值；源事务随后完整提交|多种生产套件并行任务/一致停写屏障|
|PORT-04|LOCAL_MAC_PASS（故障注入）|复制中断留下未发布partial；旧实例/导出完整；重试成功|真实断电、逐文件断点续传、崩溃journal重放|
|PORT-05|MOCK_PASS（部分）|应用Schema1数据随库恢复；未知版本拒绝|Schema升级、失败回退的真实迁移器|
|PORT-06|MOCK_PASS＋本机只读负测|源secrets排除；未知password配置拒绝；恢复库实际拒绝写入；列出重授权项|真实Keychain/TCC/SMB/Helper|
|PORT-07|MOCK_PASS|同名错误UUID、缺卷、重复UUID、系统盘fallback与未授权卷拒绝|真实热拔插/硬盘柜|
|PORT-08|MOCK_PASS|本地协作锁；模拟authority拒绝竞争主机；生产cutover恒拒绝|网络分区/掉电下的外部强fencing|
|PORT-09|MOCK_PASS（部分）|模拟generation失效/释放/回切；源数据保持|真实带数据回滚及跨机lease|
|PORT-10|MOCK_PASS|15/26能力分层、无本机模型时保持不可用；两个二进制minOS15|macOS15真实运行、未来硬件|
|PORT-11|BLOCKED|没有注册任何系统服务或改变账户/权限|需要具体对象及专项系统批准|
|PORT-12|BLOCKED|只运行5盘数学模型，没有创建任何磁盘集|缺专用可擦除测试盘/真实跨Mac池|
|PORT-13|MOCK_PASS|逻辑35TB引用列在预览，原件未读取/打包|真实大规模恢复/性能基准|
|PORT-14|LOCAL_MAC_PASS（CLI部分）|只读预览、明确新建、ImportedNeedsAuth日志、幂等重试|完整前端向导/完整状态机|
|PORT-15|LOCAL_MAC_PASS|Ed25519信任锚、文件hash、重新hash清单仍拒绝、未列出secret目录拒绝|正式发布签名/证书轮换/安装器|
|PORT-16|MOCK_PASS＋开发卷守卫|写前复核开发卷真实UUID；模拟错误卷/系统路径拒绝|不做真实开发SSD拔盘故障|

没有CROSS_MAC_PASS或PHYSICAL_POOL_PASS。原始失败的编译/测试轮次与首次混合OCR误判均保留，不被成功轮次覆盖。

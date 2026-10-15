# PORT矩阵：N-009增量

早期记录保留在PORT_MATRIX.md；本轮详情见n009-2026-10-15.json。

|用例|增量证据|级别与剩余范围|
|---|---|---|
|PORT-01|Schema1/2、配置、两个套件数据跨目录恢复|LOCAL_MAC_PASS，非跨Mac|
|PORT-03|受控任务/直接SQL排队、配置与数据库统一冻结|LOCAL_MAC_PASS，未做规模基准|
|PORT-04|文件级重试、导入/升级/发布检查点、两处SIGKILL、无身份空库安全重新分配|LOCAL_MAC_PASS，非断电/字节级续传|
|PORT-05|Schema1→2事务、DDL失败/重试/未来版本/篡改负测|LOCAL_MAC_PASS，未做生产升级|
|PORT-06|默认只读及业务拒写，样例剔除DB/签名环境|原型LOCAL_MAC_PASS；Keychain/TCC/SMB未做|
|PORT-08|本地锁与数据库停写、生产cutover恒拒绝|强分布式fencing仍未实现|
|PORT-09|候选只读退出，保留源库/候选/快照/目录|原型LOCAL_MAC_PASS，非生产回切|
|PORT-14|持久阶段、查询/预览/幂等/回退|CLI的LOCAL_MAC_PASS，GUI未实现|
|PORT-15|包/journal签名、文件/语义数据hash、篡改拒绝|LOCAL_MAC_PASS，生产密钥生命周期未做|
|其余|沿用早期状态|真实macOS15、系统授权、跨Mac、物理池仍未完成|

没有CROSS_MAC_PASS或PHYSICAL_POOL_PASS。强制终止的均为自行创建的测试进程。

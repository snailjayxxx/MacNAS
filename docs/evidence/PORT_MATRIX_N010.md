# PORT矩阵：N-010增量

|用例|本轮验证|范围|
|---|---|---|
|PORT-01|Schema3任务、步骤、事件及消费游标恢复|LOCAL_MAC_PASS，非真实跨Mac|
|PORT-03|五张新增持久表逐张阻止直接SQL写入，SELECT和pg_dump继续|LOCAL_MAC_PASS；无规模基准|
|PORT-04|任务准备/完成后两处SIGKILL，过期租约重领|LOCAL_MAC_PASS；任务层恢复，非物理断电|
|PORT-05|Schema2→3隔离升级、事务失败、提交先于journal、数据篡改拒绝|LOCAL_MAC_PASS；源库保留|
|PORT-06|恢复任务领取、确认与结果写入拒绝；应用角色拒读核心新表|LOCAL_MAC_PASS，合成授权|
|PORT-09|继续保留源库/候选/签名快照，只读恢复|无生产切换及回切|
|PORT-15|任务/事件/确认收据/UTC时间数据进入语义摘要|LOCAL_MAC_PASS，正式密钥生命周期未做|

N-009与第一轮证据保持原样。真实macOS15运行、第二台Mac、物理存储池、断电与强fencing仍无通过证据。

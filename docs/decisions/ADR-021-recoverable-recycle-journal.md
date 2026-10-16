# ADR-021：回收站的外部效果日志与保留式恢复

日期：2026-10-16。状态：接受为N-029实现约束；N-028仅完成设计/抽象模型验证，尚无回收API或Schema4。详见[N-028](../plans/N-028-RECYCLE-BIN-DESIGN.md)。

## 问题与决策

回收移动唯一原文件，PostgreSQL提交与文件rename不在同一事务；DB快照没有外部payload。不能复用自动重试队列或会unlink的短期上传暂存。

采用独立回收/恢复批准、同设备私有vault、单链接常规文件、双父目录FD、不覆盖rename和保留式协调器。第一实现只操作批准的新建合成APFS目录、0..16MiB单文件。30天只是保留策略记录，不自动到期删除/释放。

prepared→armed→observed→completed：确认先事务写意图/预留；armed提交核实后只准一次rename；observed持久完整post-stamp/SHA；双父目录同步复查后终结。丢回执查原ID，不重复效果；取消仅prepared且锁下证明未移动，未知保留对象和收费。RENAME_EXCL不是源FD-CAS，检查也不提供敌对进程强fencing或撤权原子性。

重启失去原能力。新批准后的观察接口只分类，不写DB/容量。已有post证据且现场完整匹配时，另一个经新readWrite批准的结算路径才可补同步/CAS终结，沿用原ID并另记核对者，从不rename/unlink。仅armed和看似匹配的目标保持uncertain，不自动认领。新批准/预览/ID的手动采纳另阶段设计。

N-029新增0004和recycle_entries/file_effect_operations，不改旧迁移。精确schema、全部持久表停写/UTC摘要/快照/角色拒绝必须覆盖新表；用Schema3投影摘要保护原任务/事件。隔离候选升级，保留源库。确认容量用DB事务锁，执行用真实宿主vault锁，固定实例门→vault锁→DB锁；过期租约不是外部效果fencing。

初始64MiB reserved+retained、64个entry历史、256个operation历史、8个未解决操作；未知/到期仍收费，重启不重置。网页回收不能给共享树额外容量。

当前可携包不带vault。新两表/vault非空或未知时普通export/upgrade/restore发布拒绝，不以DB备份宣称文件可恢复；payload备份另设计。DB回退不撤销rename，空Schema4候选保留原只读回退，有文件日志的候选不能回到旧可写执行者。

## 代价与验证

崩溃可停在uncertain并占住容量，历史上限满后拒绝新确认，清理/审计裁剪另设计。新锁和冻结门需要实测，既有Schema3任务和复制API不变。

N-028抽象模型不代替APFS、PostgreSQL、SIGKILL或浏览器证据；N-029需新完整原生/管道/前端回归。现有52项浏览器仍待正规权限恢复。未变更父需求、规划原件、生产服务或系统设置。

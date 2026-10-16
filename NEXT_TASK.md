# 接续任务：C1只读核对模型，然后C2宿主批准的观察桥接

B1已发布bbbfcf8；B2完整未过滤374Swift/16独立管道及新前端273Node通过，见docs/evidence/n029-b2-2026-10-16.json。B2中文提交及正常推送后，先核对Evidence/n029-b2-publication-2026-10-16.json和干净树，再推进C1。用户要求本轮自动连续至23点以后，暂不使用浏览器；没有新暂停指令。

先读AGENTS/HANDOFF/PROJECT_SPEC/ARCHITECTURE/PROGRESS、ADR-021至024及阶段证据，验证APFS UUID C1755FBB-FCA8-4EA4-BEE2-AA6BF3258B6C和Git，不使用旧Gen 8。

## C1前端数据模型

外部Evidence/n029-c1-draft只有recycle-observation.js及其20项Node测试需要复制；源码SHA在n029-c1-active-state.json，文档在n029-c1-draft-docs。三项实际反例已修复并保留：finally之前返回旧busy、同operation后续更换entry、notVisible误标无需核对。严格五字段正文/十字段记录、原始主体、安全整数/计量、分类不冒充完成、不可变身份/revision及借用生命周期均有模型覆盖。

C1不改原生或嵌入管道依赖，只改前端QA列表加新语法/模型测试，要求新的293Node/17语法/15静态/9需求负测、精确匹配B2核心和需求输入冻结。只新增1条有限MOCK_PASS，不称宿主DTO/桥接/DOM/浏览器通过；完成证据/文档后中文提交正常推送dev/bootstrap。

## C2只读真实桥接

Evidence/n029-c2-draft及manifest记录13文件和C1前置SHA；17项Swift定义编译、5纯数据和305Node通过，12真实API/内嵌管道未执行。只接独立宿主observe批准与operationID查询，固定原始会话/主体、API实例/代次/DB/宿主和注册。C1正文外包不透明来源context，客户端拒绝另一来源混进旧视图；标记仅防错等值，不是认证或强fencing。借用适配器固定客户端，dispose不关共享连接。

B2/C1都发布后可运行Evidence/n029-c2-prepare-worktree.py：它先验证主树干净、发布报告和PG关闭，再创建同级MacNAS-C2分支dev/n029-c2-observation；不覆盖已有路径/分支。运行器以MACNAS_DEV_BUILD_NAMESPACE=n029-c2选择独立Build/swift-n029-c2，默认工程缓存路径不变。先定向17，再全新未过滤391/全部CLI/16独立管道及前端；5内嵌Node场景已包含Swift总数，完整嵌入依赖14（旧12加C1 codec及新C2脚本），另4独立依赖保留。真实管道定义覆盖0/4字节/16MiB，必须实际执行并核对原始proof，不能按编译声明通过。新完整回归若跨23点，完成必要验证后收尾，不发布未验收草稿。

C2完成后方可中文阶段提交并正常推进开发分支，不合并main/强推/改历史。后续执行RPC、列表、共享可见+回收保留+传输预留计量与完整回收恢复UI分别推进；正式NAS、永久清理/到期清扫不授权。

旧0001–0004/29规划/5来源和111父项97/13/1原字节/优先级保持；目前897基线子项，SYS-09独立1父7子（合并112/97-14-1/904），远控很后期，Intel以后。只在新建TestLab做合成测试，PG18.6-only，不读家庭/NAS正式资料，不sudo或改账户/ACL/服务/网络/公网，不加第三方依赖。旧52浏览器45 PASS/7 PARTIAL仅历史，本轮不使用浏览器/预览。保留全部失败、源码/需求冻结和PG关闭，实际OS26.5.2不算15运行/跨Mac/断电/物理盘或生产规模。

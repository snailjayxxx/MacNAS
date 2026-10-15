# 首批离线任务与交接

|任务|需求|代码/文档|验证命令与证据|风险/清理/下一步|
|---|---|---|---|---|
|N-000|APP-12/MIG-03/MIG-04|ADR-000、STARTING_STATE、DEPENDENCIES|环境记录与Git基线；完整规划SHA|只写新开发工作区；不自动提交|
|N-001|全部111父需求|requirements/index.json、verify_requirements.py|verify_requirements.py / test_requirements.py|不改历史源；所有验收仍独立追踪|
|N-002|MIG-03/STO-01/SYS-02/SYS-03|CapabilityProbe.swift|Swift能力矩阵测试|真实SMB/服务枚举仍未做|
|N-003|SEC-06/SEC-08/APP-09|SecurityGate.swift、SECURITY_BOUNDARY|Swift SecurityTests|仅mock；真实XPC/认证需后续实现|
|N-008|MIG-05/BAK-09/BAK-10/APP-07/APP-08|PortableInstance/StateStore/Models、ADR-001/002|58项Swift套件中的Migration/PostgreSQL/Path测试与CLI演练|保留旧库/partial；集群测试后关闭；下一步N-009|
|N-004|STO-10|PoolSimulation、ADR-Pool-001|StorageAndCapabilityTests|数学模型；物理门槛RED|
|N-005|PHO-10四子项|PhotoSmoke、PHOTO_CAPABILITIES|photo-synthetic-smoke日志/PNG/report|保留混合语言失败；扩大数据集前不宣称准确率|
|N-006|APP-01..12|Plugins、HelloDiagnostics、SampleFileIndex、PLUGIN_CONTRACT|PluginTests真实子进程与API负测|可信样例；OS隔离/完整安装器未完成|
|N-007|MIG-03/MIG-04/MIG-05|PROGRESS/NEXT_TASK/证据矩阵|最终run summary和源码SHA清单|未提交；真实生产功能未验收|

日志/数据库/合成实例在工程之外的同一开发工作区，未放入Git；自动清理只针对本轮短路径socket和单元测试临时目录，完整演练实例与失败证据保留。

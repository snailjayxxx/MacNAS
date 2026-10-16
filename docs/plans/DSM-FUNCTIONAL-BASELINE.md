# DSM功能参照与MacNAS交付差距

2026-10-16用户明确：当前网页窗口功能与群晖DSM差距过大，后续应多参考DSM开发。文件中心还应具备Finder式连续浏览能力。本表以已读取的群晖官方资料为参照，将日常NAS操作映射到既有v0.6需求；不增加111父项、不改变97/13/1优先级。

当前网页是未连接NAS的合成演示，后端是无监听的Swift/PostgreSQL原型。模块、协议或模型测试通过不等于某个网页应用已可实际使用。下面的“未完成”包括尚未实现的业务能力，不能全部归因为浏览器验收受阻。

用户追加的控制面板、网络与安全管理要求已拆成[详细对照与交付要求](DSM-CONTROL-PANEL-NETWORK-REFERENCE.md)，覆盖接口、双栈、DNS/路由、代理、远程入口、证书、防火墙、共享服务、账户及系统管理。

## 核对表

|用户操作/DSM参照|MacNAS当前实际状态|既有需求|接续交付与验收|
|---|---|---|---|
|在桌面打开多个应用、管理窗口和任务|静态窗口管理代码与偏好模型已有；32项真实网页检查未执行|SYS-01、SYS-07|保留实测门槛，不能把桌面外观当完整NAS系统；参照[DSM桌面指南](https://global.download.synology.com/download/Document/Software/UserGuide/Os/DSM/7.2/enu/Syno_UsersGuide_NAServer_7_2_enu.pdf#page=11)|
|连续浏览目录、切换文件展示方式|当前仅合成树和三项/页演示；真实目录读取只在显式批准的合成测试宿主中验证，网页未连接|FIL-01|N-023优先补导航、路径、选择、详情与合理加载量；参照[File Station](https://www.synology.com/en-global/dsm/7.4/software_spec/file_access)|
|上传/下载、建目录、重命名、复制/移动|N-024新建/改名和N-025/N-026的16MiB有界传输已接代码/合成测试；实际网页未验收，复制/移动尚无实现|FIL-01、FIL-02、FIL-03|继续复制、回收站、持久任务/审计与大文件生产通道，不能将短期回执当重启恢复；参照[文件管理能力](https://www.synology.com/en-global/dsm/7.4/software_spec/file_access)|
|回收站恢复、管理保留期|未开发|FIL-04|在合成目录完成恢复流程及错误保护后才接真实目录；参照[File Station回收站能力](https://www.synology.com/en-global/dsm/7.4/software_spec/file_access)|
|查找文件、预览内容、受控分享|只有当前页过滤与64KiB文本预览原型；全局索引、照片/视频预览及分享未实现|FIL-05、FIL-06、FIL-07、FIL-08、FIL-09|全目录搜索不能由当前页过滤冒充；分享保持既定后续优先级；参照[搜索与分享](https://www.synology.com/en-global/dsm/7.4/software_spec/file_access)|
|查看与解释文件夹权限|合成API有读者范围及目录批准；无生产ACL编辑、有效权限解释界面|SHR-04、SHR-06、SEC-06|把可见目录、操作权限、拒绝原因做成一条完整流程；参照[文件夹权限](https://kb.synology.com/en-global/DSM/help/FileStation/privilege?version=7)|
|管理用户、组、共享文件夹与SMB访问|仅固定fixture用户和逻辑资料库；没有系统账户映射、共享创建或SMB服务接管|SHR-01至SHR-09|只读发现/预览先行，再实现受控变更与撤销；参照[账户与共享文件夹指南](https://global.download.synology.com/download/Document/Software/UserGuide/Os/DSM/7.2/enu/Syno_UsersGuide_NAServer_7_2_enu.pdf#page=15)|
|查看磁盘、存储池、卷和实际容量|网页容量为合成逻辑估计，物理池unbound；没有真实磁盘枚举和生产池管理|STO-01、STO-02、STO-05、STO-10|先真实只读清单与容量，再按MacNAS固定冗余策略实现管理；参照[存储管理](https://www.synology.com/en-global/dsm/7.4/software_spec/storage_management)|
|磁盘健康、故障提示和维护任务|有合成掉线/重绑/拒写测试；没有实盘健康与维护流程|STO-03、STO-04、STO-07、OPS-07|故障状态必须来自实际探测，维护操作另做可撤销预演与硬件验收；参照[磁盘健康与维护](https://www.synology.com/en-global/dsm/7.4/software_spec/storage_management)|
|安装、停用、升级套件并管理数据|只有两个可信样例、票据与版本迁移原型；套件中心卡片不是安装器|APP-01至APP-12|交付安装预览、来源校验、授权、生命周期、升级/回滚完整链；参照[套件操作指南](https://global.download.synology.com/download/Document/Software/UserGuide/Os/DSM/7.2/enu/Syno_UsersGuide_NAServer_7_2_enu.pdf#page=18)|
|查看CPU/内存/网络、日志、告警|没有生产资源监控面板和通知渠道；持久任务/事件只在合成CLI中运行|SYS-04、SYS-05、SYS-06、OPS-01、OPS-02|先接只读实际指标与诊断，再补操作状态/告警和受控维护；参照[管理工具指南](https://global.download.synology.com/download/Document/Software/UserGuide/Os/DSM/7.2/enu/Syno_UsersGuide_NAServer_7_2_enu.pdf#page=65)|
|配置备份计划、版本保留、选目录恢复|已有合成迁移快照、只读恢复与升级/回退；常规用户数据备份产品尚未开发|BAK-01至BAK-12、SYN-01|迁移导出演练不能当作日常备份完成；参照[备份与NAS保护指南](https://global.download.synology.com/download/Document/Software/UserGuide/Os/DSM/7.2/enu/Syno_UsersGuide_NAServer_7_2_enu.pdf#page=44)|
|从局域网登录并安全远程访问|无生产HTTP登录、TLS、MFA或远程通道|SEC-01至SEC-10|先本机隔离环境完成认证/会话/权限/审计，再进行已有授权范围内的部署验收；参照[账户安全指南](https://global.download.synology.com/download/Document/Software/UserGuide/Os/DSM/7.2/enu/Syno_UsersGuide_NAServer_7_2_enu.pdf#page=22)|

表内当前状态基于PROJECT_SPEC、ARCHITECTURE、requirements/index.json及实际源码，不代表已操作真实DSM。部分知识中心网页只返回站点外壳，未把该外壳当成完整内容；主要功能与流程依据可读取的官方技术规格和明确版本的DSM 7.2指南。没有访问用户群晖或家庭文件。

## 调整交付方式

1. 安全收尾正在运行的N-022通知来源测试，补完必要的来源绑定边界；不继续把同一通知模型无限拆成后端小阶段。
2. 下一阶段先交付N-023文件浏览基础；以“进入资料库 → 浏览多层目录 → 返回/前进 → 选择/预览 → 处理读取失败”为明确用户流程。
3. 随后围绕文件操作与传输、用户/共享权限、存储与监控、套件管理、备份恢复形成可运行的完整流程。执行顺序细化首版需求，后续需求和暂不需要项保持原优先级。
4. 每个阶段同时列出网页入口、实际后端能力、状态持久化、权限/失败处理及验证方式。仅演示的内容持续明确标注，不给尚未实现的功能放置可假装成功的按钮。
5. 网页实际验收仍由Codex完成，当前站点权限异常没有解除。代码/模型可继续开发，真实DOM、窗口、键盘、布局和业务联调分别保留待测，不能发布为已完成的NAS产品。

MacNAS继续采用Swift原生核心、PostgreSQL 18、macOS与既定存储/独立备份设计。DSM的用户流程是参照；其Linux存储实现、SHR/Btrfs和特定硬件能力不会未经设计直接套用到MacNAS。

用户其后直接新增SYS-09“网页内控制Mac桌面”，并明确放在很后期，独立记入[补充账目](../../requirements/user-additions.json)；原111项基线不变，合并有效范围112项。该新增不属于本次DSM参照扩展出来的首版功能，不提前开发，见[后期计划](FUTURE-WEB-MAC-REMOTE-CONTROL.md)。

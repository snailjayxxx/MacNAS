# ADR-014：目录当前页展示与借用来源

2026-10-15（Asia/Tokyo）。N-020在N-019查询能力上新增directory-view.js，不改变Swift、SQL、Schema 3、PostgreSQL 18或宿主目录批准。静态网页仍是显式合成数据，没有浏览器业务传输或生产登录。

## 来源、数据与生命周期

createFixtureDirectorySource(api,session,options?)和createClientDirectorySource(client)都需要明确的现有提供者。前者逐次核对已有注册会话，后者初始overview固定宿主上下文，继续由具名客户端和Swift执行每次授权；缺失或失败不创建会话、连接、磁盘批准或fixture回退。来源dispose仅隔离自身并尽力丢弃本地继续位置，不调用endSession/client.close。身份所有者先dispose窗口/通知/目录来源，再由任务来源关闭一次共享提供者；关文件窗口仅dispose自己的控制器。

来源返回不可变的普通libraryID、name、relativePath、bytes、modifiedAt及canPreview，不把名称、路径或内容传给词典。宿主资料库只投影逻辑估计值及固定状态，不暴露卷根、描述符或inode；该估计不是剩余物理容量，也不按本页数量回推总数。未知值显式null，没有补造日期、容量或total。

具名来源校验精确目录页、路径关联、类型、UTF-8字节顺序、页内名称碰撞、跨页递增及上下文。每来源最多64条继续链和有界首请求预留，同令牌串行；任一继续失败丢弃本地位置，由控制器要求显式重读，不自动重试或聚合。discardCursor仅清理本地所有权，不能释放宿主64条/60秒预算；频繁重读仍可能触发宿主budgetExceeded。无效响应只隔离此来源，不主动关闭共享任务/通知客户端；真正传输超时等仍由具名客户端关闭其连接。

## 固定内存样例的范围

新fixture独立于旧model.js的翻译键文件样例。固定树包含共享8项（6文件/2目录）、嵌套目录、空目录和仅管理员可见的个人库。名称是普通固定字符串，预览文本中的jobHash和脚本形状标签仍为原文。字节数按合成文本实际UTF-8长度计算；没有磁盘时间与库容量，因此modifiedAt/estimatedBytes为null。

fixture页标记synthetic-fixed-directory，宿主页仍是directory-stamped-live-metadata。样例树始终固定，不模拟真实目录标记/卷修订/内容重新批准，不假称8项数组排序是8192项受限扫描。其内存继续位置按UTF-8顺序，最多64待用/64消费或过期记录、60秒整链，显式discard和来源dispose释放样例自身内存。单调时钟注入仅供离线测试，没有网页故障注入入口、文件修改接口或目录授权。

## 当前页控制器与窗口

createDirectoryPager只持有当前一页（默认50、范围1至100；静态窗口3）。open切换库/相对目录并立即丢弃旧内容/位置；reload从头替换，next替换而不累加。搜索及文件/目录过滤仅查本页，范围提示始终在控制区；库摘要独立读取，重建界面、最小化或聚焦不自动翻页/重读。

加载、预览期间暂停本窗口内容操作。下一页或重读失败保留标注的最后一页，明确区分staleState、expired/replay、denied、missingVolume、budgetExceeded及断连；继续和预览禁用，等待显式重读或导航。未知异常投影固定unavailable，不显示IO/数据库诊断。资源超限不悄悄提高扫描预算。空目录、无本页匹配、末页及未读取状态独立。

预览仅允许当前页不超过64KiB的txt/md/json/csv/log普通文件，来源再校验UTF-8字节数与上下文，宿主仍独立授权/有界读取。只以textContent写入DOM，不执行HTML。窗口、库/路径、身份、页读取和预览代次丢弃迟到成功/失败；迟到页返回的继续令牌尽力清理，不覆盖新窗口或打开旧预览。已有弹窗/语言刷新也使旧预览不能夺取界面；dispose不取消已经发生的宿主读取。

## 验证与边界

Node验证来源/控制器及延迟次序，静态检查验证脚本加载、白名单/CSP和文本写入策略。批准目录的实际Node→Swift→PostgreSQL管道改为经展示来源/控制器，保持现有7个请求及两页间修改注入；独立CLI管道另验资料库元数据与missingVolume拒绝，关闭目录来源后任务查询仍可用。没有为通过测试新增生产自动批准入口。

核心40份文件未变，N-019完整205项中的204项纯原生测试复用原收据；其中1项嵌入Node的目录场景因脚本及新模块变化必须重跑并单独调和，不声称本轮新跑205项未过滤全量。新依赖集合为model.js、bridge-client.js、directory-view.js和scripts/test_directory_bridge.cjs，QA守卫同时检查全部摘要、完整核心集合及204+1证据组成。详见[N-020验收](../plans/N-020-ACCEPTANCE.md)和[结构化证据](../evidence/n020-2026-10-15.json)。

HTML/静态白名单仅增加directory-view.js，bridge-client.js继续不加载/不提供，connect-src为none。W01–W10、T01–T08、N01–N06和新增F01–F08均待用户回家实测；没有实际DOM、布局、焦点、键盘或翻译质量证明。目录前端展示不解决生产认证/连接、系统隔离、真实NAS、大目录索引/吞吐、macOS15运行、跨Mac/物理盘故障或通知断连后的持久ACK状态核对。

# MacNAS 工程约束

目标与优先级以 `docs/planning/v0.6/` 的只读原件及当前用户补充指令为依据。111 父需求：97 首版、13 后续、1 暂不需要；全部保留在 `requirements/index.json`。

最新用户决定：正式仓库 https://github.com/snailjayxxx/MacNAS；数据库使用 PostgreSQL，已确认采用推荐的 PostgreSQL 18。原规划中的 SQLite 候选不再适用于实际代码；保留历史原件便于审计。

Apple Silicon / macOS 15+，Swift 原生核心、自研中文日文网页桌面、固定聚合冗余池、独立备份、客户端和套件生态仍为目标。当前为命令行核心和未连接NAS的静态桌面原型；桌面仅用合成数据，浏览器验收待完成，尚无可部署NAS服务。

2026-10-16用户补充产品目标：文件中心应具备Finder式连续文件浏览体验；整体功能与日常操作需更多参照群晖DSM。以[DSM功能差距表](docs/plans/DSM-FUNCTIONAL-BASELINE.md)细化既有父需求并按完整用户流程交付，当前演示窗口和后端测试结果不能代表实际NAS功能已完成；N-022收尾后优先推进文件浏览基础。

控制面板与网络管理按[详细功能对照](docs/plans/DSM-CONTROL-PANEL-NETWORK-REFERENCE.md)逐页补齐。用户另增SYS-09“网页内控制Mac桌面”，并明确放在**很后期**；只登记于[补充账目](requirements/user-additions.json)和[未来计划](docs/plans/FUTURE-WEB-MAC-REMOTE-CONTROL.md)，当前不开发/启用。v0.6基线111项及97/13/1保持原样；含用户新增的当前有效范围为112项、97/14/1，不把新增项混写进历史原件。

开发盘仅供源码、构建、合成测试；生产数据池独立。禁止擦盘、sudo、擅改共享/账户/ACL/系统服务/公网、读取家庭照片或自动推送 main。第三方运行依赖目前仅新增用户明确选定的 PostgreSQL 18；其它依赖另行审查。

所有证据区分模拟、当前 Mac、本机 macOS15、跨 Mac 和物理盘。`MOCK_PASS` 不得替代生产验收。

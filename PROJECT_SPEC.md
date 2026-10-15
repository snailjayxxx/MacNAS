# MacNAS 工程约束

目标与优先级以 `docs/planning/v0.6/` 的只读原件及当前用户补充指令为依据。111 父需求：97 首版、13 后续、1 暂不需要；全部保留在 `requirements/index.json`。

最新用户决定：正式仓库 https://github.com/snailjayxxx/MacNAS；数据库使用 PostgreSQL，已确认采用推荐的 PostgreSQL 18。原规划中的 SQLite 候选不再适用于实际代码；保留历史原件便于审计。

Apple Silicon / macOS 15+，Swift 原生核心、自研中文日文网页桌面、固定聚合冗余池、独立备份、客户端和套件生态仍为目标。当前为命令行核心和未连接NAS的静态桌面原型；桌面仅用合成数据，浏览器验收待完成，尚无可部署NAS服务。

开发盘仅供源码、构建、合成测试；生产数据池独立。禁止擦盘、sudo、擅改共享/账户/ACL/系统服务/公网、读取家庭照片或自动推送 main。第三方运行依赖目前仅新增用户明确选定的 PostgreSQL 18；其它依赖另行审查。

所有证据区分模拟、当前 Mac、本机 macOS15、跨 Mac 和物理盘。`MOCK_PASS` 不得替代生产验收。

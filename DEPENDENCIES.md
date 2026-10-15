# 依赖与工具准入账本

|组件|来源/版本|许可证|用途|授权与状态|
|---|---|---|---|---|
|Swift / XCTest / Foundation / Darwin / CryptoKit|现有 Xcode，Swift 6.3.3、SDK 26.5|Apple 工具链/SDK 条款|构建、测试和原生运行|已存在；未另装|
|Vision / CoreGraphics / CoreText / ImageIO|现有 Apple SDK|Apple SDK 条款|本地合成图像验证|仅自生成图像，无家庭素材|
|PostgreSQL 18.6|postgresql.org 官方发布源码|PostgreSQL License|数据库、psql、pg_dump、pg_restore|用户在当前会话确认 PostgreSQL 18；开发 SSD 内构建|
|Python 3 / clang / make / Git / curl|现有 `/usr/bin` 与 Xcode 提供|各系统工具原有条款|仅开发脚本/编译/取官方源码|未新增第三方开发工具|
|Node.js / node:test|机器已有 /opt/homebrew/bin/node 26.5.0|Node.js原有许可及内置组件条款|前端语法/内置测试及管道桥接集成测试|未安装或升级，无npm包；非产品运行依赖|

Swift Package 无远端依赖。SQLite 草稿已移除。PostgreSQL 源码、SHA-256、配置参数及构建日志位于工作区 `Evidence/postgresql-source.json`、`Evidence/postgresql-*.log`。

开发 PostgreSQL 编译关闭 ICU、readline、zlib、LZ4、Zstd、NLS，且没有启用 TLS；只供私有 Unix socket 验证。这不是生产发行包。生产本机认证、签名分发、TLS、升级和恢复工具的依赖清单需后续决策。

不附带 Homebrew、Docker、第三方 Swift 数据库驱动、Web 框架、模型权重或媒体工具。PostgreSQL 独立运行；本轮没有连接蜗光集正式库。

兼容构建另设 `install-18.6-macos15`，用 Apple clang 的 macOS15 最低目标重新构建；首次默认26目标的开发构建保留作历史。`otool`与实际测试证据分别记录，部署目标15不等于已在15系统运行。

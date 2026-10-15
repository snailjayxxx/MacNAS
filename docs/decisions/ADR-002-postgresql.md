# ADR-002：数据库采用 PostgreSQL 18

依据：用户明确禁止 SQLite，要求参照蜗光集；只读核对蜗光集本地数据库 README，确认其为 PostgreSQL 15-only。进一步比较后用户确认采用推荐的 PostgreSQL 18。该决定优先于规划包中的 SQLite 候选描述。

MacNAS 新建独立开发实例，不连接蜗光集数据库。PostgreSQL 18.6 官方源码校验后在 Build 私有前缀内构建。运行工具链路径、socket、真实数据库名留在宿主适配层；可携清单只有 PostgreSQL 主版本、schema版本和快照格式。

选择理由：关系约束、事务化任务状态和幂等键、JSONB检查点，以及所有套件 Schema 在单库中统一一致性导出。30TB照片文件留在外部文件系统，数据库保存元数据。当前不是经实测得出的30TB/6并发性能承诺。

恢复采用逻辑快照，避免物理数据目录的主版本和宿主路径耦合。未来升级需要 migration、备份、隔离恢复与回退演练；没有数据库不可用时改用其他引擎的路径。

PostgreSQL 18官方支持周期至2030；15至2027。参考：https://www.postgresql.org/support/versioning/ 。本轮只测18.6，不声称已经验证18→未来版本迁移。

官方依据：https://www.postgresql.org/docs/18/app-pgdump.html 、 https://www.postgresql.org/docs/18/app-pgrestore.html 、 https://www.postgresql.org/about/licence/ 。

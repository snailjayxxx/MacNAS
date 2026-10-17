# ADR-031：管理范围操作观察与owned费用分开展示

日期：2026-10-17。状态：自动模型验收完成；提交推送以Git/外部发布收据为准。见[阶段证据](../evidence/n029-c3c3a-2026-10-17.json)。

C3C2接通完整ledgerOnly账目，仍不提供管理范围物理观察。C3C3先交付独立纯模型切片，再接宿主批准/实际观察。旧C1正文、entry计量与整树allocation计量保持各自语义：一个已恢复entry收费为0，同一allocation仍owned，不能误显示为释放整树额度。

新外壳固定持久scopeID、独立来源sourceID、原始主体/模式及operationID，包含旧精确观察正文和一个owned allocation。两种意图SHA、两种revision独立；非released entry字节须与owned声明相同，released不修改owned声明。已知entry/allocation可预先固定，首次可见后再不可替换；notVisible费用未知，不能当成0。

模型只验证公开数据与读取生命周期，matchingReported不证明现场匹配。未来宿主须另发物理观察批准及独立来源域，实际持锁检查隐藏路径/stamp/SHA与当前会话，不能借C3C2账目seal、旧未管理observe或可见ID授权效果。Native投影当前只在仓库外用虚构记录验证；没有该宿主方法/RPC、适配器、DOM或浏览器通过。

22项MOCK覆盖严格属性/来源/UTF8、owned与released守恒、独立revision、候选待核对、并发/错误脱敏、关闭清空、迟到getter与回调关闭。首轮20项及复核增加两项均通过，没有本切片实际失败。全量原生基线在C3C2发布后按完整核心/全部内嵌和独立依赖逐字节复核，不把这些MOCK计作新Swift/真实文件效果；新的无监听前端和需求冻结另行执行。

只追加有限MOCK_PASS，不改变父需求、原规划、旧迁移或真实NAS/家庭资料。用户要求连续开发，现已允许按需使用浏览器；阶段中文提交及正常推送dev/bootstrap授权继续有效，本模型切片未执行浏览器。格式见[模型契约](../contracts/MANAGED_RECYCLE_OBSERVATION_MODEL.md)。

## 本次实际验证

新无监听前端20261017T130247-2651d480通过368项Node（新增22）、19语法、15静态策略和9需求负测；联合152份当前源码及需求前后冻结一致。

完整核心94份及全部实际内嵌/独立管道依赖逐字节复核与已发布C3C2 126e3c9一致，复用其471Swift/16独立管道/全部CLI精确收据；本切片没有重跑原生套件。只有dev_web语法/模型测试入口改变，由新前端覆盖。

首轮20项、复核22项模型检查均通过，没有本切片实际失败。仓库外独立纯Swift投影实际执行15项拒绝断言并输出6份虚构JSON，再由旧C1/C3C1和新模型验证；这只是数据关系，不是PG/真实文件效果或新完整回归，Native投影未并入主树。C3C2及更早失败继续按原始收据保留。

本切片为MOCK；当前宿主没有该管理观察外壳的批准/来源生成器/RPC/客户端适配器，网页不加载或提供模块。matchingReported只代表报告，filesystemVerified/executionAuthorized/capacityReleaseAuthorized均为false。整体费用取C3C2完整列表，不能相加多次操作观察。没有新的文件效果、DOM/浏览器、生产认证/fencing、macOS15运行或跨Mac证明。用户要求自动连续推进、中文阶段提交/正常推送dev/bootstrap，浏览器已获准按需使用；旧迁移及正式资料边界保持。

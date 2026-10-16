# 接续任务：N-029 B2，独立目标批准的同卷合成恢复

B第一段已实现单向回收、私有vault/独立宿主批准、真实SIGKILL及只读观察/新批准结算；完整未过滤20261016T184142-5cba9f0d和前端20261016T200328-04a217c3均通过，见[阶段证据](docs/evidence/n029-b-2026-10-16.json)。不要复跑设计或把恢复草稿当成已发布。用户要求本轮连续开发至11点以后（暂按23:00 JST）、暂不使用浏览器；没有新的暂停指令。

先读AGENTS、HANDOFF、PROJECT_SPEC、ARCHITECTURE、PROGRESS、ADR-021/022/023及N-029主计划，核对开发APFS UUID C1755FBB-FCA8-4EA4-BEE2-AA6BF3258B6C和Git。B中文提交/正常推送后，核对仓库外Evidence/n029-b-publication-2026-10-16.json。

## 恢复方向

只接B同一登记owner/library/vault的retained且无活动操作条目；来源恢复批准与目标目录批准分开，后者固定原始相对路径及物理父目录身份。目标必须已存在、同库同设备，名称冲突/大小写/规范化冲突拒绝，不创建祖先、不覆盖。0..16MiB单常规单链接，固定双父FD/完整stamp/SHA，仅一次RENAME_EXCL。

在原entry追加restore operation并CAS revision；prepared/cancelled restore仍retained，completed restore才released。保留历史和费用，slot永不循环使用；到期不自动清扫。缺post的armed无论sourceOnly或candidateMoved均不采纳/续做/取消/释放。已有post且匹配时，新写结算批准及当前有效的独立目标批准只补同步/CAS原ID，不再rename；重启后两种旧批准均失效。

外部Evidence/n029-b2-draft已编译19项新用例（15恢复协调/3实际SIGKILL定义/1CLI探针拒绝），但尚未执行恢复文件或数据库测试。应用前核对n029-b2-draft-manifest.json中的基础SHA，只复制五源/两测试；补B2矩阵/ADR-024，再跑定向及全新未过滤原生/全部CLI，最后前端无监听与需求冻结。B实测355Swift为4259.458秒，恢复新增用例后需基于实测合理调整总运行器时限，不能放宽功能内部边界或删断言。

后续C先固定严格DTO/受众/Schema协商与真实合成管道、共享64MiB可见+回收保留+传输预留，再接回收确认、列表、同库目标恢复及原结果核对。C1只读观察模型草稿在Evidence/n029-c1-draft，20项纯Node定义与实际反例，不是桥接/UI/浏览器。未解决效果不能因窗口/会话退出释放，不自动重连/重交或关闭共享连接。

## 权限和收尾

不使用浏览器/预览；旧52项45 PASS/7 PARTIAL仅历史，详见web/tests/BROWSER_ACCEPTANCE.md。只操作新建TestLab合成实例，不读家庭/NAS正式文件、不sudo、不改系统账户/ACL/服务/网络/公网、不引入新依赖。PostgreSQL18.6-only、Apple Silicon/macOS15+目标；当前机26.5.2不等于15运行证据，Intel以后、SYS-09很后期。

0001–0004已发布、原字节不改；普通portable仍拒绝任何历史或登记vault，DB回退不逆转rename。原111父项97/13/1、895基线子项及SYS-09独立1父7子（合并112/97-14-1/902）保持；29规划及5来源只读。每个独立阶段相关验证/证据/文档齐全后，按长期授权中文commit并正常推送dev/bootstrap，无须重复确认；不合并main、强推或改历史。保留全部实际失败、完整源码/需求冻结、PG关闭及仍未验证范围。

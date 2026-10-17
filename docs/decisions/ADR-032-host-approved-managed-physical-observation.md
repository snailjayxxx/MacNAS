# ADR-032：独立批准的管理范围只读物理观察

日期：2026-10-17。状态：实现完成，完整自动验收通过，提交推送以Git/外部发布收据为准。

C3C2账目只读批准不能证明载荷匹配；C3C3A严格呈现模型现由独立managedObserve宿主批准接线。新purpose无写权限，来源使用独立每API随机密钥及不同HMAC域，固定会话、原始管理员、模式、实例/代次、DB/宿主/Schema、两份登记和fresh grant。它不继承账目、旧未管理观察或执行许可。

观察在真实instance gate和vault flock内读取owner-scoped日志及同范围owned allocation，验证原UUID路径、library/owner/vault/volume、pre/post字节/SHA/身份。现有操作意图摘要基于PostgreSQL jsonb::text；同一次有界只读SQL核验后产生文件内私有构造的读取证据，Native不以Swift紧凑JSON重算。旧迁移与既有算法不改。原操作originScopeSHA包含原写grant，不能与新观察grant比较。

来源context只核对绑定，不散列全范围payload。单项观察不声称全库存clean；在实际锁内散列所选对象，保留读取FD和完整stamp，编码后核对inode/size/mtime/ctime/uid/mode/nlink、相反路径缺失和slot布局，拒绝过时匹配；无文件证据时仍重新分类。写/inspect路径完整audit及32KiB逐块上下文检查保持。会话/批准/模式/登记/锁及DB物理绑定也在返回前复核。unknown明确null；entry released仍保留owned费用，candidateMoved不结算、不认领armed。读取不能调用执行、结算、取消、恢复目标或容量释放。

消息只有managedRecycleObservationContext（空参数）和observeManagedRecycleOperation（scopeID/sourceID/operationID）。CLI须独立--approve-synthetic-managed-recycle-observation；批准不在RPC中。客户端固定来源和借用连接，显式读取、单在途、关闭清空/隔离迟到，无自动批准/重试。网页未加载或提供模型，浏览器已允许按需使用，本切片没有新DOM。

首轮外部9项为7通过/2失败，原因是把PG规范摘要误比成Swift紧凑JSON；修复后10项通过。编码中载荷变化、SIGPIPE及原30秒请求超时的失败，和最终14项/10真实管道/3个编码竞态的详细结果保留外部收据。定向结果不能替代本次新的未过滤完整回归。见[验收矩阵](../plans/N-029-C3C3B-ACCEPTANCE.md)。

## 本次实际验证

新未过滤20261017T151420-cdcf13cd通过485项Swift（13830.623秒，新增14，含8项内嵌Node→Swift测试）、全部CLI及16独立管道，私有PG正常关闭。新无监听前端20261017T191825-5ff00c32通过401Node（新增18客户端）、20语法、17静态策略和9需求负测，另26项下载器安装器检查。完整核心100份、原生输入131份、联合166份当前源码及需求前后冻结一致；本阶段没有复用旧原生套件。

10个真实管理观察管道场景直接核对未批准/账目不可替代、unknown、0/16MiB、满64MiB真实copy、released后owned收费、恢复只读、改变载荷ambiguous和candidateMoved未结算；每次完整16表摘要及payload SHA不变。CLI4种开关/主体组合独立验证。旧回收/恢复各3次、物理容量4次真实SIGKILL在本次完整套件重跑；candidate场景只是注入中断。

外部首轮9项为7通过/2失败，实际PG规范JSON摘要被误比为Swift紧凑JSON，改用同查询PG核验及读取证据后10项通过。编码中载荷改写反例先实际产生1个失败断言。随后4项批次2项通过后遭SIGPIPE13；改用单FD的F_SETNOSIGPIPE保留子进程诊断，单项实际复现2个失败及16MiB观察41.1075秒超过原30秒。仅新managedObserve去掉无关全库存扫描，保留所选文件FD/完整stamp/布局作编码后复核；原32KiB检查、30秒客户端/120秒管道时限及写/inspect审核不变。最终全部14项、10真实管道及3个编码竞态通过，含旧FD同长度改写并精确恢复mtime、名称替换和未知slot子项；全部DB摘要保持。反例收尾脚本漏匹配文案an的失败、源码和修复收据也保留。另一次14项为13通过/1个database错误，PSQL退出非零的原因未确认；单项9场景39请求诊断未重现异常，随后恢复全部原始129源码再运行干净14项，没有加入产品自动重试、吞错或延长时限。所有原始失败与停库保留；外部定向未替代本次新全量。

只限新建TestLab同设备私有合成范围；网页Schema3内存树/fixtures仍独立，没有管理执行/恢复目标RPC、永久清理、DOM或浏览器验收，也不证明生产认证/fencing、macOS15运行、跨Mac/断电/物理池。0001–0006及Migration5/6、原29规划/5来源、111父/97-13-1及补充SYS09很后期保持。浏览器已允许按需使用；阶段中文提交并正常推送dev/bootstrap，不合并main、不强推或改历史。 N-030已独立发布两个明确准入的可移除下载器及离线安装工具；网页包中心仍为fixture。

见[阶段证据](../evidence/n029-c3c3b-2026-10-17.json)。

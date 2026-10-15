# 无监听的原型业务API（P02）

`PrototypePlatformAPI`是Swift业务层；没有HTTP、XPC、网络端口或生产登录系统。`beginFixtureSession`仅为合成用户测试签发进程内会话，不能作为真实身份认证。每次调用按平台配置重新核对用户/角色，读者不能借业务接口写配置、标签或签发套件授权。

## 业务方法

- overview：版本1、逻辑用户/角色、中日语言、数据库schema和恢复模式；不返回秘密引用或系统凭据。
- setLanguages / writeLabel / enqueue：管理员+开发模式校验，受实例共享写锁保护；幂等任务键落在PostgreSQL。
- issueAppGrant / appState / putAppState：不透明随机授权绑定实例、套件、注册epoch、权限和期限。每次重新验证，数据库连接使用该实例该套件的角色，套件不能指定任意schema、数据库或SQL。
- runSample：只运行编译内置白名单中的两个自研可执行文件；普通结果经授权复核后才写入该套件状态表。文件索引还需显式授权实例host-binding/fixtures下的合成目录，返回相对路径。

授权撤销/卸载/重新注册会使旧epoch失效，旧授权不会因重新启用而复活。已经进入受保护数据库调用的操作先结束，撤销随后生效；撤销不是对已提交数据的回滚。运行中受监督的示例会在循环检查到撤权时终止，不发布其结果。

进程运行时有时间预算和输出字节上限，失败不拖垮核心，未引入自动无限重启。输出文件检查存在轮询间隔，不能承诺绝不发生瞬时磁盘写入超量。没有CPU/内存硬限制，也没有OS沙箱。可信示例与启动用户拥有相同OS权限，不能据此开放第三方原生插件。

样例环境只含最小PATH、临时HOME与语言设置，剔除数据库连接配置、会话和导出私钥。数据库role和文件系统进程权限仍是不同边界；清理环境变量不是文件系统隔离。

read_only_recovery和rolled_back_recovery模式在业务层先拒绝写入；恢复数据库的默认事务只读提供独立负测。默认事务只读不是抵御本机管理员/数据库owner的防篡改机制，生产写权限切换仍未实现。

## N-010：Schema 3 的任务与事件

submitLabelJob 接受管理员当前身份，创建属于该用户的标签任务。durableJobs、cancelJob、jobEvents、acknowledgeJobEvents 只操作调用者自己的受众；管理员也不能通过这些接口指定另一个用户。事件页最多100条，确认不能超出已交付范围。poll 会保存交付上界，因此只读恢复不能调用 poll/ack；durableJobs 仍可读取。

submitAppValueJob、appJobs、cancelAppJob、appJobEvents、acknowledgeAppJobEvents 使用现有套件票据，每次核对实例、epoch、权限及期限。套件不能选择另一个受众或核心 SQL；已提交的应用任务只能写自己应用的状态表。应用角色不能直接访问新任务或 outbox 表。已入队的数据任务由可信核心管理，临时 UI 票据失效不自动撤销已接受的工作；取消需要调用对应任务接口。

这些方法要求数据库 Schema 3。历史 enqueue 接口只保留给 Schema 1/2 的第一轮测试；Schema 3 拒绝该旧入口，使用有载荷及作用域的 submit 方法。旧 legacy fixture 任务不由新工作进程领取。

DurableJobQueue 是可信核心执行器，不传给 native 样例。内置工作只有测试标签、应用私有状态、合成文件摘要；没有任务脚本、网络发送、系统授权或真实卷绑定。workOne/CLI work-once 供当前合成测试手动驱动，不安装常驻服务。具体一致性、租约和事件语义见 ADR-004。

# 合成卷与只读资料库API（N-012 / N-013 / N-019）

所有接口均属于无监听PrototypePlatformAPI，并采用既有beginFixtureSession。它们不构成生产认证、真实磁盘授权、Web服务或系统共享。数据库继续PostgreSQL 18，无新数据库Schema或替代引擎。

|方法|作用|授权/边界|
|---|---|---|
|fixtureVolumeStatuses|读取各逻辑库的missing/ambiguous/needsBinding/readyReadOnly等状态|管理员；不返回真实磁盘清单|
|updateFixtureVolumeInventory|注入完整合成观察快照|仅synthetic_development管理员；不枚举或挂载|
|previewFixtureVolumeBinding|创建readOnly/readWrite绑定预览|管理员；绑定会话/修订/显示内容，30秒有效|
|commitFixtureVolumeBinding|消费匹配预览与confirmed值|开发模式管理员；confirmed仅是fixture参数|
|revokeFixtureVolumeBinding|撤销绑定与当前内容批准|开发模式管理员|
|setFixtureLibraryReaders|设置某库的可读逻辑用户集合|开发模式管理员；用户必须存在；授权不随可携包导出|
|authorizeFixtureLibraryContent|打开派生的合成目录并固定句柄|开发模式管理员；没有任意URL参数；不创建目录|
|listFixtureLibrary|非递归元数据列表|每次检查用户、库、卷和内容批准；最多1000项，超限拒绝|
|fixtureLibraryPage|非递归有界目录页|默认50、1至100；8192项/1MiB名称/5秒扫描预算；目录变化要求重读，已有批准仍必需|
|previewFixtureText|有界UTF-8文本|同上；最多65536字节；仅txt/md/json/csv/log；普通数据，不渲染|
|storage demo --source PATH|CLI创建新样例并演练上述流程|有效合成实例、开发模式；只在排除导出的host-binding内创建|

资料库文件条目只含name、relativePath、kind、bytes和modifiedAt，不带宿主绝对目录。文本结果含libraryID、relativePath、text和utf8Bytes。空相对路径仅用于列出库根；文件预览必须是有效相对路径。不存在上传、重命名、删除、跨卷移动、执行或真实文件写入API。

清单以volumeID匹配；mountID和mediaID限制绑定生命周期。显示名变化不导致错绑；缺失或重复身份关闭访问；重新出现要求新批准。文件句柄还固定本次目录inode，防止路径被替换成同名占位目录。文件访问前后重新核对受众与清单修订；正常操作不依赖前端隐藏按钮。

恢复实例没有清单/绑定/内容批准/读者授权，默认不能读外部内容。测试中已批准的同进程实例改为只读模式后仍可读取原批准目录，但不能扩大授权；这不等同于新Mac已重新授权。正式只读恢复向导与系统授权仍待实现。

N-014已把listLibraries/listFiles/previewFile接入固定消息桥接，N-019新增listFilesPage；静态页面继续显式内存演示，没有真实浏览器传输。桥接不接受客户端自报授权、卷身份来源、根目录或角色；新CLI宿主无内容批准。真实卷识别与NAS文件服务需独立验收。

## N-019目录页

fixtureLibraryPage(libraryID:relativePath:pageSize:cursor:session:)返回FixtureDirectoryPage，含libraryID、relativePath、pageSize、entries和nextCursor。默认空relativePath及pageSize=50；原始UTF-8名称排序，每页1至100。cursor只能传回本API/会话发出的随机小写UUID，不接受外部after名称或宿主目录。

DescriptorLibrary每次有界全扫描，最多8192项、名称合计1MiB、单调5秒；只保留最多101份候选元数据和有界碰撞摘要集合。超预算整体拒绝，不跳过页外不安全条目。旧数组仍最多1000、超限拒绝；新页也不是无限规模索引或常数内存/时间算法。

第一页固定目录身份及mtime/ctime等标记，继续页和读取/编码后复查；新增/删除/同名替换/目录替换等检测失败staleState并要求重读。文件原地修改可能不改变父目录标记，后页元数据按读取时返回，不是目录/文件内容快照。路径/权限复查后仍存在竞态，不作为真实盘故障或OS隔离证明。

每API最多64个待用及64个消费墓碑，整条链60秒不续期；绑定会话/实例/数据库/用户/角色/模式、资料库/路径/页大小、卷/介质/挂载身份、批准/清单修订及内容reader身份。范围不符denied，已知过期expired，已消费且保留墓碑replay，未知denied；退出/重启不延续。无关清单修订也保守拒绝。查询/授权/编码失败不消费，成功响应传输丢失可能已消费，需显式重读；不会自动重试。

恢复只读可以使用同进程既有批准读取，但不能扩大授权；新恢复实例仍无清单/批准。令牌/标记不进入可携包，无新SQL表/迁移。完整消息和具名客户端DTO见[桌面契约](DESKTOP_API.md)，取舍与限制见[ADR-013](../decisions/ADR-013-bounded-directory-pages.md)。

## N-020展示边界

新增directory-view.js显式借用已有fixture会话或具名客户端。宿主仍使用本契约原有卷/目录批准及有界读取；网页本身为固定内存样例，每页3项，没有真实批准或磁盘扫描。样例consistency为synthetic-fixed-directory，实际宿主仍为directory-stamped-live-metadata；未知时间/库估计为null，不把样例数组排序当成真实扫描证据。

控制器只保留当前页，错误保留标注的旧内容并要求显式重读；关闭窗口不关闭任务/通知共享提供者。预览限当前页普通文本且再次校验64KiB/UTF-8/上下文，宿主依旧每次独立授权。接口见[桌面契约](DESKTOP_API.md)，生命周期、迟到结果及限制见[ADR-014](../decisions/ADR-014-directory-page-presentation.md)。F01–F08和既有W/T/N均待用户回家实测，没有浏览器业务连接或生产文件访问。

## N-029 C2：私有TestLab回收观察与现有资料库分离

B1/B2的私有登记库及vault不是上述fixtureContent浏览/上传/复制树的自动扩展。C2只新增宿主authorizeFixtureRecycleObservation、revokeFixtureRecycleObservation及observeFixtureRecycleOperation，固定原始主体、会话、实例/代次/DB/宿主和登记；只有observeRecycleOperation进入消息层。它查询已有operation，不创建/移动/取消/结算，窗口与会话退出不释放日志费用。新CLI独立开关默认关闭，读者拒绝；真实合成Node→Swift和CLI已验证，字段/来源/生命周期见[桌面契约](DESKTOP_API.md)及ADR-026。

原生各上传/复制注册表的64MiB预留、持久回收reserved+retained与网页共享64MiB树仍是不同的现有范围。C2不把它们相加后声称完成统一准入；恢复释放的是回收计量，恢复后的可见字节仍须由后续共享容量权威计量。普通portable继续拒绝任何登记vault或日志历史，payload备份/跨Mac接管及生产授权没有因只读桥接完成。

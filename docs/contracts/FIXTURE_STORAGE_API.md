# 合成卷与只读资料库API（N-012 / N-013）

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
|previewFixtureText|有界UTF-8文本|同上；最多65536字节；仅txt/md/json/csv/log；普通数据，不渲染|
|storage demo --source PATH|CLI创建新样例并演练上述流程|有效合成实例、开发模式；只在排除导出的host-binding内创建|

资料库文件条目只含name、relativePath、kind、bytes和modifiedAt，不带宿主绝对目录。文本结果含libraryID、relativePath、text和utf8Bytes。空相对路径仅用于列出库根；文件预览必须是有效相对路径。不存在上传、重命名、删除、跨卷移动、执行或真实文件写入API。

清单以volumeID匹配；mountID和mediaID限制绑定生命周期。显示名变化不导致错绑；缺失或重复身份关闭访问；重新出现要求新批准。文件句柄还固定本次目录inode，防止路径被替换成同名占位目录。文件访问前后重新核对受众与清单修订；正常操作不依赖前端隐藏按钮。

恢复实例没有清单/绑定/内容批准/读者授权，默认不能读外部内容。测试中已批准的同进程实例改为只读模式后仍可读取原批准目录，但不能扩大授权；这不等同于新Mac已重新授权。正式只读恢复向导与系统授权仍待实现。

这些方法没有接入N-011静态页或createBridgeAdapter；页面仍为显式内存演示。未来桥接不得接受客户端自报授权、卷身份来源、根目录或角色。真实卷识别与NAS文件服务需独立验收。

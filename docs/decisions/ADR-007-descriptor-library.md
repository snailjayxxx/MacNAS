# ADR-007：绑定目录句柄的只读文件访问（N-013）

2026-10-15，Asia/Tokyo。只允许显式合成实例内host-binding/fixtures/volumes/<mountID>/<逻辑相对目录>，不存在任意绝对路径接口。不启动HTTP服务，不读取用户NAS或家庭文件。

管理员先完成卷绑定，再显式批准合成目录内容。批准时保持目录文件描述符，并绑定本次卷批准ID；每次读取都验证当前会话、角色/资料库读者权限、逻辑引用和卷状态。读取后再次核对授权与修订。重绑定不能复用旧内容批准；源API重建和迁移恢复均丢弃授权。

DescriptorLibrary从根目录开始逐级以openat、O_DIRECTORY、O_NOFOLLOW、O_CLOEXEC打开目录；后续操作以批准目录句柄为起点，拒绝跳转到其他设备。每次读取前后重新打开批准路径并核对device/inode，目录替换、路径变成链接或挂载占位消失均拒绝，不创建补位目录。目录枚举使用独立打开描述，避免重复列表共享偏移。

只接受目录和单硬链接普通文件；符号链接、硬链接、FIFO及其他特殊文件拒绝。文件使用O_NONBLOCK避免打开FIFO等待；读取前后校验inode、类型、link count、大小、mtime/ctime及当前目录项，检测替换或修改。此为范围约束与变化检测，不是文件系统事务快照，也不能证明真实卸盘/断电行为。旧SafeFS的导出/写入路径未全面改造，其既有竞态限制仍保留。

目录单次最多1000项、名称总量128KiB，超预算报错而非悄悄截断；还没有大型目录分页或全局检索。底层单文件最多1MiB；业务文本预览最多64KiB，只接受UTF-8及txt/md/json/csv/log扩展，返回普通字符串，不执行HTML或脚本。大小写及Unicode规范化碰撞拒绝；不声称适配所有文件系统名称规则。

CLI storage demo仅在有效合成实例中创建新的随机fixture目录和文本，演练授权、只读列表/预览、断开与重新出现。恢复模式在创建任何目录前拒绝。它不安装服务、修改ACL或挂载真实卷。

依据：[Apple open手册](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/open.2.html)、[Apple目录操作手册](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/opendir.3.html)，并核对本机SDK的openat、fstatat和fdopendir声明。只使用macOS15部署目标可编译的现有Darwin接口；实际macOS15运行仍未验证。

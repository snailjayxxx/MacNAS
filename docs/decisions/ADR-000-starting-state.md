# ADR-000：工程起点与开发盘

日期：2026-10-15（Asia/Tokyo）。

初始聊天目录是 SMB 共享中的空目录，不适合作为规划要求的 APFS 开发场地。只读查询确认 MacNAS-Dev 已是 HP SSD S700 500G、USB 外置、普通 APFS、约 499.9GB，非系统盘；空闲约 499.7GB。卷 UUID 和摘要仅保留在本地 Evidence/environment.json。原卷忽略所有权设置保持原样，不作为生产权限验收。

依据当前用户指令创建 `/Volumes/MacNAS-Dev/MacNAS-Workspace/{MacNAS,Build,TestLab,DeploySandbox,Evidence}`。未覆盖旧工程。

用户随后提供正式 GitHub 仓库，读取 origin/main 的 HEAD 为 `e05b3d7e3acbeb447f10c2f5f27a64be332be6f5`；只有 README，无 AGENTS/既有架构或源码。获取该历史并在 `dev/bootstrap` 上继续，没有自动提交或推送。

规划包共 30 文件，其中 CHECKSUMS 列出另外 29 文件；逐个 SHA-256 和大小校验通过。四轮 JSON 及追加原话保持原字节。原包版本字段中部分 schema 标为 v5，原样保留，不擅自修复历史。

只读 diskutil 在沙箱内无法使用 DiskManagement；通过已批准的只读沙箱外调用获得目标卷信息，不属于磁盘修改。

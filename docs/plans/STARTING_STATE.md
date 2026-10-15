# 起始状态与复现入口

- 仓库：`https://github.com/snailjayxxx/MacNAS`；本地分支 `dev/bootstrap`。
- 基线 HEAD：`e05b3d7e3acbeb447f10c2f5f27a64be332be6f5`，初始只有 README。
- 开发机：Mac14,3 / arm64 / macOS 26.5.2；Swift 6.3.3；macOS SDK 26.5。macOS 15 仅为部署目标，真实运行未测。
- 命令：`sw_vers`、`uname -m`、`xcode-select -p`、目标卷与其物理盘的 `diskutil info -plist`、`df`、`swift --version`、`git ls-remote --symref`、`git fetch origin main`、`git status --short --branch`、`git rev-parse HEAD`。
- `Evidence/environment.json` 保存目标卷只读检查结果，未记录序列号；不再保存无关 NAS 挂载详情。
- 从工程根运行 `/usr/bin/python3 scripts/dev.py`：校验开发卷 UUID → 需求与负测 → Swift 构建 → 创建私有 PostgreSQL 合成测试集群 → 单元/集成测试 → CLI 导出恢复演练 → 本地生成图片的 Vision 探针 → 关闭测试集群。
- 每轮独立 `Evidence/runs/<run>/`、`TestLab/<run>/`、`DeploySandbox/<run>/`。失败日志保留，旧轮次不覆盖。

工具和缓存都在开发 SSD；唯一临时目录是 `/private/tmp/macnas-pg-*`，仅存短路径 Unix socket 和测试进程 HOME，在集群停止后清理。没有格式化、系统账户/共享变更、LaunchDaemon 或公网配置。

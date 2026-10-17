# 管理执行预览与一次确认模型

N-029 C3C4A为拟定的纯JavaScript呈现模型，所有用例为MOCK。现有管理观察和账目范围均不能授权执行；当前没有该执行context的宿主批准/来源生成器、消息或客户端适配器。模块不加载到网页或预览白名单，没有新的文件效果或浏览器操作。

## 绑定与数据

expected精确包含scopeID、sourceID、ownerUserID和mode。UUID为标准小写，sourceID为64位小写hex，原始UTF8主体不正规化、1..128字节、无NUL/CR/LF或不成对代理项。mode允许synthetic_development/read_only_recovery/rolled_back_recovery，但后两者在任何时钟或服务回调前拒绝预览与确认。

选中intent精确为kind、allocationID、entryID、declaredBytes、allocationIntentSHA256和sha256。kind仅recycle/restore，声明0..16MiB；recycle的输入entryID明确null，由宿主预览分配，restore固定已知entryID。声明和摘要只是选中数据，不能充当宿主批准或文件witness。

context使用独立八字段形状：executionContextVersion:1、source:"fixture-host"、purpose:"managed-execution"、scopeID、sourceID、userID、role:"administrator"、mode:"synthetic_development"。范围/标记/原始主体/模式固定到expected。旧contextVersion读取形状不能代替；来源仍只是等值标记，实际宿主必须独立批准并使用不同HMAC域。

previewSnapshot只接受previewVersion:1、context、previewID、operationID、entryID、kind、allocationID、declaredBytes、allocationIntentSHA256、operationIntentSHA256、sha256、expiresAfterMilliseconds和confirmationRequired:true。选中字段逐项相等，restore entry固定；短时效整数1..60000毫秒。操作摘要是宿主提供的opaque hex，不在JavaScript重算。未来若进入既有日志，须沿用PG jsonb::text算法及真实锁内数据关系核验。

resultSnapshot只接受resultVersion:1、context、previewID、operationID、entryID、kind、allocationID、operationIntentSHA256和state。所有身份、意图和上下文继承预览，state仅completed/uncertain，均是报告数据。没有容量释放/文件系统验证/执行授权字段，额外字段整体拒绝。

对象必须是自有、可枚举数据属性；额外/缺失/继承/symbol/getter拒绝，不调用输入getter。数据逐层复制和冻结。

## 明确一次确认生命周期

createConfirmationModel接expected、intent、prepare/confirm/now回调和可选onChange；只暴露snapshot、preparePreview、discardPreview、confirmPreview、dispose。创建/关闭不调用时钟或服务。preparePreview一次调用prepare，显式discardPreview只清空本地预览，不撤销宿主或产生效果；每模型最多16次请求，弃用或已过期的preview/operation nonce不能再次出现。

本地有效期从请求开始时钟计算，不能因迟到回复重置；有限非负小数单调时钟受支持，倒退/无效时钟不发送确认。时间判断只用于保守呈现，宿主仍须独立检查真实单调截止时间。

confirmPreview要求精确previewID和显式confirmed:true。确认请求只携带scopeID/sourceID/previewID/confirmed；实际宿主必须按独立写批准及存储的预览意图核验，不能信任这些公开值。模型在派发前消费本地确认，最多调用confirm一次；任何重复确认/后续预览/弃用均拒绝。过期在派发前拒绝。派发后的completed/uncertain报告可在截止后到达；一旦派发，业务拒绝、超时、断线、畸形响应等都保守显示uncertain并要求独立核对，不重试，也不假定无效果。

本地消费不是跨窗口/重载或宿主的exactly-once保证；真实后端还须独立预览所有权、一次性消费、持锁最终复核和持久幂等。读取sourceID、matchingReported、候选分类或用户界面的confirmed:true都不能代替它们；restore目标批准单独处理，不提供永久清理或owned容量释放。

dispose清空当前预览/结果/错误/过期和确认标记，忽略迟到成功/失败及其getter；不能撤销已派发效果，也不关闭借用服务。回调在preparing/confirming阶段同步关闭时，对应服务回调尚未派发；同步或异步回调异常不滞留busy。错误仅显示有限码，不显示原消息或调用code getter。

snapshot中filesystemVerified、executionAuthorized、capacityReleaseAuthorized始终false。当前只有模型和虚构响应，不能据此声称真实写效果、浏览器明确点击、生产认证/fencing或跨Mac证明。

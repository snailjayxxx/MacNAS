# N-005 苹果本机照片能力卡

仅Apple能力和合成测试素材；不读取家庭图库、不上传照片或特征。macOS最低目标15。下表API最低版本已从本机Apple SDK头文件核对，不能替代最低OS实测。

|方向|候选/API最低版本|本轮验证|后续准确性与降级标准|
|---|---|---|---|
|视觉相似|VNGenerateImageFeaturePrintRequest / macOS10.15；revision2为14+|生成合成图片，重复生成特征并记录距离/revision|至少200对标注样本，区分精确重复/相似/不同；报告precision/recall及内存/每张耗时；不同revision不可混算，失败禁用该索引|
|同人分组|VNDetectFaceRectanglesRequest / macOS10.13，只是检测|没有身份表征或聚类实现，NOT_IMPLEMENTED|合成/明确授权数据，至少20人多光线多姿态；pair precision/recall与误合并拆分；检测框不当作身份结果|
|OCR|VNRecognizeTextRequest / macOS10.15；实例supportedRecognitionLanguages接口12+|本地生成中/日/英文文本图，查询支持语言并保存识别输出|按语言分别统计字符错误率，至少100张每语种；小字/旋转/低对比另测；不支持语言明确提示，不切云端|
|自然语言搜图|FoundationModels基础能力需macOS26+，不等于图文联合检索|BLOCKED：没有已验证的Apple-only图文检索链路；未调用模型|至少100条中日文查询与人工相关性，报告Recall@10/nDCG；macOS15明确不可用，标签检索只能叫标签检索|

合成图像冒烟证据在每轮 DeploySandbox/<run>/synthetic-photo-smoke/，包括PNG、ground truth、识别结果、特征revision和距离。它不能代表家庭图库准确率、同人聚类或自然语言检索验收。当前机是macOS26.5.2，macOS15与未来硬件仍待测试。

正式实现还需要关闭/删除索引、资源预算与授权拒绝测试，以及离线流量观测。当前程序无网络请求代码，但尚未完成框架级流量审计，不能凭选用Vision就宣称网络隐私验收完成。

参考：https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest 、 https://developer.apple.com/documentation/vision/vnrecognizetextrequest 、 https://developer.apple.com/documentation/foundationmodels 。

2026-10-15当前机观测：同图feature print距离0（revision2）；同一图片混合三语一次识别遗漏中日文字并误判。改为显式语言与各行ROI后，中、日、英文各一条均精确匹配。两组原始输出都保存；只能证明3条合成样本，不能报告通用准确率。

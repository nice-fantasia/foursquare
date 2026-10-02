# 自动就绪加固执行记录（2026-10-02）

> 基线 `origin/main` / `27d40a1`，分支 `codex/automatic-readiness-next`。按 Android 减动、E 盘环境、规则与 AI、UI、Android 打包、Online、发布检查的顺序执行；不改变玩法、AI 参数、Online 产品范围或发布身份。

## 1. Android 系统减动桥接

- 标准 Flutter integration harness 执行 `android_motion_bridge_test.dart`，退出码 0。
- 真实 Android `disableAnimations`、Flutter `MediaQuery.disableAnimations`、先手提示起始与 750ms 后透明度/缩放保持 1、未提前完成均通过。
- 首次安装遇到设备已有 versionCode 4、测试包 versionCode 1 的降级冲突；Flutter harness 自动卸载旧包后重试。平台行为断言通过，专用 AVD 原有应用数据未保留，因此整体记为 `PARTIAL`。
- 三项系统动画配置和 `android/local.properties` 精确恢复；自有 AVD 已关闭。执行器的关机证据抓取偏早，主代理随后实时确认 ADB 为空。

## 2. E 盘 Android 环境

- 活动 Flutter/Android 构建路径通过：SDK `D:\Develop\Android\Sdk`，AVD `E:\DevData\Android\avd`，Gradle 缓存 `E:\DevCaches\gradle`，Android Studio JBR 21。
- 普通 Debug APK 构建通过；活动 AVD ini/config 解析到 E 盘，C 盘旧 AVD 目录不存在。
- 旧 C 盘引用只存在于快照/旧 AVD 历史元数据，未影响活动配置和构建，本轮未删除快照。
- 当前 PowerShell 进程未显式暴露 Android/Gradle/Java 环境变量；Flutter 配置可正确解析工具链，因此活动构建路径为 `PASS`，Shell 环境完整性为 `PARTIAL`。

## 3. 游戏规则与 AI

- 新增 24 个确定性种子对局、每局最多 120 ply 的不变量覆盖：棋盘网格与棋子列表、合法走子枚举、模拟/正式落子、吃子记录、未吃计数、终局复核以及非法落子不污染历史。
- 新增 2 项引擎测试均通过。
- 两个独立种子共 24 局 AI 样本：中等/简单 8胜0负0和，困难/简单 8胜0负0和，困难/中等 4胜1负3和；全部自然终局，0 搜索超时。有限样本不构成普遍棋力保证。

## 4. UI 多尺寸和无障碍

- 首次新增的 320×568、两倍文字测试复现首页工具区向右溢出 11px。
- 底部工具操作改为居中 `Wrap`，保留原有按钮、语义和交互；窄屏大字、模式语义、1000px 宽屏两列布局测试通过。
- 首页 5 项及相关可见页面/语音布局 20 项通过。

## 5. Android 打包预演

- Debug APK 与 Debug AAB 构建通过；APK 包名 `com.qoder.foursquare`、versionCode 1、minSdk 26、targetSdk 36。
- INTERNET、CHANGE_WIFI_MULTICAST_STATE 存在；RECORD_AUDIO、MODIFY_AUDIO_SETTINGS、ACCESS_FINE_LOCATION 不存在。
- 专用 AVD 上 `adb install -r`、冷启动、目标前台和首屏 XML 通过，未执行 uninstall/clear；只证明覆盖安装未清理，不推导所有存档版本兼容。
- 本机无 bundletool，AAB 仅完成 ZIP 完整性和关键条目检查，不声明 split APK 安装通过。

## 6. Online 本地多客户端

- 新增真实 Socket.IO 多客户端集成测试：12 个客户端形成 6 个独立对局，并发提交各自首步、收到断线通知并恢复到 revision 1。
- 6 个 matchId 保持唯一，双方收到相同权威提交，各房间状态未串扰。
- 原双客户端流程与新增多房间流程 2/2 通过；完整服务端套件增至 126/126。

## 7. 发布前自动检查

- `verify_release_candidate.ps1` 增加 Debug AAB 构建、双产物大小/SHA-256，以及 Git 跟踪签名/私钥文件名检查。
- 文件检查阻止 `.jks`、`.keystore`、`.p12`、`.pfx`、`.pem`、`.key` 和 `key.properties`，不读取环境文件内容。
- 修正当前开发文档中的 AI 基础深度旧值 2/3/4 为实际 2/4/8。
- 首次入口运行发现新增测试的两处尾逗号 lint，修正后以干净工作树执行 `-Strict` 成功：
  - Flutter：868 通过、0 失败、1 项显式跳过；
  - 服务端：126 通过、0 失败；
  - `flutter analyze --no-pub`：No issues found；
  - Dart 格式：201 文件、0 改动；
  - Debug APK：203,888,309 bytes，SHA-256 `1367115523A400FEC615883770FC9AC3A652FED0C796A1D471C4640B9F64F32D`；
  - Debug AAB：77,234,924 bytes，SHA-256 `FA6657B0CB115C09639AD50CEAA03CC4D6EDE5F3A49EE84416860ED50DFC50F1`；
  - Git 跟踪签名/私钥文件：0。

严格验证绑定提交 `ae01463`；本报告与索引是随后增加的文档差异，不改变可执行代码、测试或构建脚本。原始证据位于本机 `build/automatic-readiness-20261002/` 和 `build/verification/20261002-234839/`，不提交 APK、AAB 或原始日志。

## 剩余门禁

- 真机 Profile/Release 性能、更多 Android 系统版本、真实低内存/低存储和长期运行。
- 双真实设备 LAN；真实 PostgreSQL/Redis、TLS、迁移回滚、备份恢复及部署负载。
- 永久 applicationId、正式签名、Google Play 账号与素材、隐私/支持信息。
- Mac/iOS 真机、TestFlight/App Store、平台语音权限和真实音频中断。

这些项目依赖人工设备、正式资料、账号或隔离基础设施，未计入本轮自动通过范围。

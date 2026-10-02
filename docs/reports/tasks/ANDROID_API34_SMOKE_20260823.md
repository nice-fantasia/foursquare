# Android API 34 模拟器冒烟验证记录

> 类型：历史验证快照，不替代 `RELEASE_CHECKLIST.md` 的真机与商店门禁
> 日期：2026-08-23
> 分支：`codex/android-emulator-smoke`
> 基线：`707a56d`

## 1. 验证环境

- Flutter 3.35.6 / Dart 3.9.2。
- Android Studio 2024.3，JBR 21。
- AVD：`Foursquare_API_34_x86_64`。
- 设备：Pixel 7、Android 14 / API 34、Google Play x86_64。
- 加速：WHPX 10.0.26200。
- 应用包名：`com.qoder.foursquare`。
- Launcher Activity：`com.qoder.foursquare/.MainActivity`。

## 2. 自动化组合链路

设备端测试文件：

`integration_test/android_phase1_smoke_test.dart`

覆盖范围：

1. 清理真实 SharedPreferences、Hive 存档、统计和冥想存档。
2. 使用生产 `main()` 完成真实应用组合初始化。
3. 首次启动进入引导并跳过到首页。
4. 首页只展示 Phase 1 的双人、AI、LAN、战绩、规则和设置范围；在线与冥想入口保持隐藏。
5. 打开规则页，验证“对弈规则”和“精确吃子”。
6. 打开战绩与最近对局页，验证空历史体验。
7. 启动本地双人，按棋盘语义动态选择当前方棋子和一个合法目的地。
8. 验证一手移动自动保存、Flutter 合成暂停/恢复事件后仍存在，并可从首页“继续游戏”恢复。
9. 启动简单 AI 对局，验证真实 Game BLoC、棋盘和页面组合可渲染，且正式入口不包含隐藏语音面板。

执行命令：

```powershell
.\scripts\run_android_phase1_smoke.ps1
```

最终结果：1 项设备集成场景通过，退出码 0。

该测试会清理应用的 SharedPreferences 和 Hive 数据。入口脚本通过 ADB 同时校验 `ro.kernel.qemu=1` 和 `ro.boot.qemu.avd_name=Foursquare_API_34_x86_64`，通过后才向测试传入授权值。测试代码在授权值缺失时会在首次清理前失败；测试结束会再次清理本轮生成的引导状态、存档和设置。正式账号设备和保存有人工测试数据的设备不得绕过脚本直接运行测试。

## 3. Android 黑盒生命周期检查

使用普通 Debug APK 和 ADB 独立验证：

- 清数据后首启进入 onboarding。
- 跳过 onboarding 后进入主菜单。
- HOME 后恢复保持同一应用进程。
- 从主菜单返回 Launcher 后再次启动仍进入主菜单。
- force-stop 后启动产生新进程，主菜单状态恢复。
- 竖屏、横屏和恢复自动旋转完成，入口均可滚动到达。
- crash buffer 为空；采样日志未发现应用 FATAL、ANR、Unhandled Exception、FlutterError 或 RenderFlex overflow。
- `ApplicationExitInfo` 唯一退出记录为验证过程主动执行的 `USER REQUESTED / FORCE STOP`。

## 4. 观察项

- 横屏 onboarding 内容可以纵向滚动访问。首屏只显示跳过、插图、分页和下一页，标题与说明需要继续滚动；后续视觉优化可增加滚动提示或压缩首屏间距。
- 横屏主菜单所有 Phase 1 入口都能通过滚动访问。
- 无窗口软件 GPU 冷进程启动的 `am start -W TotalTime` 为 5790ms，日志出现 63、73、86 帧跳帧。该环境不用于正式性能结论，仍需真实 Android 设备上的 Release 包验证。

## 5. 证据边界

- 本记录只覆盖一个 API 34 x86_64 模拟器。
- Debug APK、无窗口软件 GPU 和模拟器性能不能代替正式签名 AAB、Google Play 预发布报告或真机 Release 性能。
- 当前未覆盖 Android 26、Android 35/36、低内存、低存储、锁屏、真实 Wi-Fi/LAN、热点或设备厂商兼容性。
- 在线、语音和冥想入口仍处于隐藏阶段，本轮未开放或验收这些发布门禁。

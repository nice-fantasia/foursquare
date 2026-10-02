# Android 下一批自动化测试记录（2026-09-20）

> 2026-09-21 归档说明：原始报告来自 `android-next-tests` worktree，以下结果绑定 `877d2bc`。原始截图与日志保留在该 worktree 的 `build/android-next-tests/`。报告中的 gfxinfo 帧统计只代表采集到的原生窗口数据，不能代表全部 Flutter 渲染；`PERF-AND-001` 调整为待重新测量的观察项，后续以 Flutter FrameTiming / DevTools 与真机 Profile 为准。最新修复见 [修复记录](REVIEW_FIXES_20260921.md)。

> 类型：合并结果核对与模拟器自动化证据，不替代真机、正式签名 AAB、Google Play 预发布报告或真实 Wi-Fi LAN 门禁

## 1. 候选版本与 MR 结果

- 测试候选提交：`877d2bc90f7fc130ef01a06cef4e2aeb736723d0`。
- 测试分支：`codex/android-next-tests`。
- PR #1 已合并到 `main`，合并提交为 `0ef2f07336a423af4f2107bc81fb22c16544eb1f`。
- PR #2 已合并到 `codex/release-readiness-batch-1`，合并提交为 `308b6309c86f429e0cc71b7918deb2565ceb094b`。
- PR #3 已合并到 `codex/android-emulator-smoke`，合并提交为本轮候选 `877d2bc90f7fc130ef01a06cef4e2aeb736723d0`。
- 核对时 `origin/main` 仍指向 `0ef2f07336a423af4f2107bc81fb22c16544eb1f`，尚未包含 PR #2/#3 的开发内容。

结论：三个 PR 在 GitHub 上均显示已合并，但只有 PR #1 进入主分支。PR #2/#3 属于堆叠分支合并；将候选内容提升到 `main` 仍是独立的人工作业。

## 2. 环境与产物绑定

- Flutter 应用包名：`com.qoder.foursquare`。
- Android：API 34 / x86_64。
- 冒烟 AVD：`Foursquare_API_34_x86_64`，设备 `emulator-5554`。
- 双端客户端 AVD：`Foursquare_API_34_Client_x86_64`，设备 `emulator-5556`。
- 正常 Debug APK SHA-256：`99198CADD3B25A027035C8750155347C59CE47B72E012B887FE80BDED68A807D`。
- Profile APK SHA-256：`46F6714865DD85DCADFB774E86FD0ED82F5E58FB6EEFEBFCB5A84150C4A741F6`。
- Profile 渲染器：NVIDIA GeForce RTX 3060 Laptop GPU，Android Emulator OpenGL ES Translator，OpenGL ES 3.1。
- 证据目录：`build/android-next-tests/`。

客户端 AVD 启动时发生 Android 系统蓝牙服务崩溃。测试期间只对该专用 AVD 临时执行 `pm disable-user --user 0 com.google.android.bluetooth`，避免系统弹窗覆盖目标应用；结束后恢复。

## 3. 执行结果

| ID | 测试项 | 结果 | 关键证据 |
|---|---|---|---|
| AUTO-01 | API 34 Phase 1 组合冒烟 | 通过 | `scripts/run_android_phase1_smoke.ps1`：1 项集成场景通过；覆盖引导、首页范围、规则、空历史、PVP 一手、生命周期、继续游戏、PVE 与隐藏语音入口 |
| AUTO-02 | 普通 Debug APK 双 AVD 独立启动 | 通过 | 两端清数据后均从 Flutter 启动画面进入 onboarding；目标前台包校验通过 |
| AUTO-03 | LAN 主机创建/广播 | 通过 | 主机显示“正在等待玩家加入 / 房间名：我的棋室” |
| AUTO-04 | LAN 客户端发现主机 | 环境阻塞 | 自动发现为空；唯一一次显式搜索等待 15 秒后仍未发现。两个 AVD 的 `eth0` 均为各自 NAT 中的 `10.0.2.15`，不能作为真实同一二层网络的 mDNS 验证 |
| AUTO-05 | Profile 构建与启动 | 通过 | `flutter build apk --profile` 成功，Profile APK 可安装并进入首页 |
| AUTO-06 | Profile 本地 PVP 交互 | 通过 | 自动完成 8 手合法移动；无 FATAL、ANR、Unhandled Exception 或 `E/flutter` |
| AUTO-07 | 本地对局后台计时 | 通过 | 后台壁钟等待 12 秒，倒计时仅减少 4 秒；减少部分来自回前台和 UI 取证，未覆盖完整后台区间 |
| AUTO-08 | 进程终止后的存档恢复 | 通过 | 提交 1 手后 HOME、`force-stop`、冷启动；首页出现“继续游戏”，恢复后移动历史仍为 1 手 |
| AUTO-09 | Profile 帧耗时与内存采样 | 已采样，保留风险 | 数据见第 4 节；模拟器结果不能直接判定真机发布性能 |

## 4. Profile 性能基线

### 4.1 启动

- 清数据后的首次冷启动：`4904 ms`。
- 随后三次进程冷启动：`3118 / 3047 / 2840 ms`，平均约 `3002 ms`。
- 存档恢复测试中的冷启动：`2989 ms`。

当前权威文档未定义启动耗时硬阈值，因此这些数字作为同环境后续回归基线。

### 4.2 帧数据

本地 PVP 8 手样本：

- 总帧数 47；P50 `17 ms`、P90/P95 `18 ms`、P99 `22 ms`。
- legacy jank：2/47（4.26%）。
- FrameTimeline jank：47/47（100%）。
- Missed Vsync、High input latency、Slow UI thread、Slow bitmap uploads 均为 0；Slow issue draw commands 为 35。

交替手势样本：

- 总帧数 24；P50 `17 ms`、P90/P95/P99 `18 ms`。
- legacy jank：0/24；FrameTimeline jank：24/24（100%）。
- Missed Vsync、High input latency、Slow UI thread、Slow bitmap uploads 均为 0；Slow issue draw commands 为 22。

模拟器刷新率为 60 Hz，展示期限约 16.67 ms；大部分帧处于 17–18 ms 边界。新旧 jank 口径给出相反信号，本轮将其保留为性能风险，需在 Android 真机的 Profile/Release 构建上复测后确定是否达标。

### 4.3 内存快照

- 8 手交互后：TOTAL PSS `136896 KB`，TOTAL RSS `222892 KB`。
- 追加手势后：TOTAL PSS `145705 KB`，TOTAL RSS `232164 KB`。

这里只有两个单点快照，不能据此判断内存泄漏；后续需要长局、反复进退页面和系统内存压力下的趋势测试。

## 5. 问题与观察

| ID | 级别 | 内容 | 处理 |
|---|---|---|---|
| BUILD-AND-001 | P1 发布门禁 | 干净 worktree 中不存在 `assets/images/`，但 `pubspec.yaml` 声明了该目录。Debug/Profile 构建均输出 `Error: unable to find directory entry in pubspec.yaml: .../assets/images/`，进程仍以 0 退出并生成 APK | 本轮只记录；发布候选前应补齐受版本控制的目录/资源或删除失效声明，并增加构建日志门禁 |
| ENV-AND-001 | 环境 | Google Play API 34 客户端 AVD 的 `com.google.android.bluetooth` 原生服务崩溃并弹出系统错误框 | 测试期间临时禁用该系统包；不归类为 foursquare 产品缺陷 |
| ENV-AND-002 | 环境 | 两个本机 AVD 使用相互隔离的 emulator NAT，mDNS 房间发现无法建立可信双端链路 | LAN 发现、加入、移动、计时、断线和重连仍需两台真机或可控同一二层网络执行 |
| OBS-AND-002 | P2 交互观察 | 棋盘语义把当前方棋子标记为“可选棋子”，其中可能存在选中后没有合法目的地的被围棋子；自动化不能把“可选”解释为“必有合法步” | 本轮未改产品代码；后续可访问性评审决定是否需要“无合法移动”反馈或更精确语义 |
| PERF-AND-001 | P1 复核项 | Profile 模拟器的 FrameTimeline jank 为 100%，同时 legacy jank 为 0–4.26%、P50 为 17 ms 且无 Missed Vsync | 保留原始双口径；在至少一台 60 Hz Android 真机上以 Release/Profile 包复测启动、连续走棋和页面滚动 |

## 6. 证据索引

- Phase 1 冒烟：`build/android-next-tests/20260920-api34-smoke/`
- 双端 LAN：`build/android-next-tests/20260920-dual-lan/`
- Profile：`build/android-next-tests/20260920-profile/`
- 主要原始文件：`gfxinfo-framestats.txt`、`gfxinfo-scroll-framestats.txt`、`meminfo.txt`、`meminfo-after-scroll.txt`、`lifecycle-timer-confirmation.txt`、`process-death-restored.xml/png`、双端 `lan-state-final.xml/png`。

## 7. 结论与剩余门禁

- 候选提交 `877d2bc` 的 API 34 主流程、普通 APK 启动、Profile PVP、后台暂停和进程恢复均通过。
- LAN 主机端创建状态通过；双端发现因模拟器网络拓扑阻塞，尚未形成产品通过或失败结论。
- 本轮确认一个发布构建卫生问题，并保留一个真机性能复核项和一个可访问性交互观察。
- 本轮没有修改产品代码，也没有将任何分支提升到 `main`。

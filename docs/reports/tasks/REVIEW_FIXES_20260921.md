# AI 与 Android 审查修复记录

> 修复于 2026-09-21 启动，2026-10-02 完成验证收尾。分支 `codex/review-ai-android-fixes`；开发基线 `99c6668`。本记录区分代码验证、模拟器功能验证与尚待执行的真机发布门禁。

## 1. 修复结果

| 审查项 | 修复 | 验证 |
|---|---|---|
| AI 缓存错误 | 只缓存搜索原始窗口内的精确值；只复用同深度、同评分执色、同未吃计数的结果 | 确定性反例先失败；修复后与独立全宽搜索的冷/热缓存评分及走法一致 |
| AI 阻塞界面 | 普通 PVE 与隐藏冥想组合使用 `BackgroundAI` / Flutter `compute`，原生平台在后台 isolate 计算 | 调用线程的输入事件先于搜索完成；Android 三档 PVE 完成实际玩家与 AI 交互 |
| 迟到 AI 结果 | GameBloc 以搜索代次、对局标识、棋盘、历史长度和暂停状态验证结果；通过既有权威移动 handler 直接提交 | 重开、重复搜索、暂停/恢复、回合超时和关闭后的迟到结果测试通过 |
| LAN 搜索状态 | 停止搜索显式回到 initial 并清空列表；底层发现错误重新抛出，进入本地化 failure 状态 | 真实 service 错误分支与“停止→再次搜索”的失败回归通过 |
| 评估方向偏差 | 威胁评分复用 `GameEngine.getCaptureOpportunities` | 黑白两侧、四种旋转与镜像均保持评分一致 |
| 搜索终局一致性 | AI 接收未吃计数；50 ply 判定统一由 GameEngine 执行；返回实际完成深度和是否超时 | 49/50 ply、吃子归零、终局无移动、中途超时采用上一完整迭代测试通过 |
| 资源构建警告 | 删除没有资源引用且目录不存在的 `assets/images/` 声明 | 全项目 analyze 无问题；APK 构建成功 |
| Android 测试缺口 | 三档 PVE 各完成玩家落子、AI 回应、保存与继续游戏；采集 Flutter FrameTiming | 专用 API 34 smoke 通过，72 个 Flutter 帧样本归档 |

`AIPlayer.selectMove` 增加默认值为 0 的可选 `noCapturePlyCount`；测试替身与生产调用同步更新。`AIMoveResult` 新增 `completedDepth`、`timedOut`，默认值兼容既有构造。棋局、存档与协议格式保持现有版本。

## 2. Android 测试自身问题

增强测试过程中发现并处理了两处测试执行问题：

1. 暂停 live binding 后继续等待下一帧，可能因为帧调度已停而挂起。改为短暂 `runAsync` 等待，恢复后再 pump；保留阶段日志。
2. FrameTiming 回调在正文结束和 tearDown 各移除一次，导致清理断言失败。保留唯一的 tearDown 清理；最终完整测试退出码为 0。

旧报告中 AND-18 的“停止正常”不足以证明搜索状态已结束，已附历史结论更正。LAN 状态修复的失败回归和代码检查通过；双设备 mDNS、真实网络及断线重连继续保留为独立设备门禁。

## 3. 最终验证（2026-10-02）

- Dart 格式：197 文件，0 改动。
- `flutter analyze --no-pub`：No issues found。
- 全量 Flutter：814 通过、1 项按设计跳过、0 失败。显式启用型在线真实服务测试保持默认跳过。
- Node 服务测试：125 通过、0 失败。使用原工作区已有依赖；服务端源文件与本候选一致，未安装依赖。
- Android API 34 集成 smoke：1 个完整场景通过，覆盖 PVP 暂停恢复及三档 PVE 实际玩家/AI交互、棋盘/执色/难度/历史/未吃计数/存档与恢复。
- APK SHA-256：`395a315deb10d5aeb462097fe94decd3d784284184618720901880c2536a7639`。
- Flutter FrameTiming：72 个样本，build/raster 数组各 72 项。构建为 Debug，smoke 关闭动画；这些数据用于确认采样链路，不作为真机 Release 性能通过证据。
- 独立设备执行代理记录、主代理核对：`build/review-fixes-20261002/android-summary.md`；主代理检查测试退出码、三档阶段、JSON 样本数量、AVD 身份、APK 哈希与最终进程关闭记录。

证据目录：`build/review-fixes-20261002/`；早期失败与修复过程保留在 `build/review-fixes-20260921/`。原始截图、日志、APK 和数据不提交到源码仓库。

## 4. 三档棋力样本

`dart run scripts/benchmark_ai.dart 4` 提供固定种子、黑白交换、初始与中盘开局的三个配对，并按普通 PVE 的方式每回合新建 AI。

2026-09-21 的 12 局样本：

| 配对 | 较高难度胜/负/和 |
|---|---|
| 中等 vs 简单 | 4 / 0 / 0 |
| 困难 vs 简单 | 4 / 0 / 0 |
| 困难 vs 中等 | 2 / 2 / 0 |

全部落子合法，按权威规则自然终局，样本没有搜索超时。有限样本证明简单档与更高难度有差异；困难相对中等的普遍优势仍需更大、更丰富的局面集和人工体验验证。

## 5. C 盘迁移到 E 盘影响检查（2026-10-02）

| 配置 | 实际值 | 结论 |
|---|---|---|
| AVD 主入口与用户环境 | `E:\DevData\Android\avd` | 两个 AVD 的入口 .ini 均指向 E 盘 |
| SDK / ADB / 系统镜像 | `D:\Develop\Android\Sdk` | 工具与 API 34 镜像存在；项目 sdk.dir 指向同一路径 |
| Gradle 实际用户目录 | `E:\DevCaches\gradle` | 通过离线 init-script 检查确认，构建成功 |
| Flutter / 构建 JDK | Flutter 3.35.6；Android Studio JBR 21.0.5 | Flutter doctor Android 工具链通过，实际 Gradle 使用 JBR 21 |
| 当前主 AVD 硬件路径 | 缓存、用户数据、加密分区均指向 E | 启动时生成的硬件配置正确 |
| 迁移前 Quick Boot 快照 | `snapshots/default_boot/hardware.ini` 仍含旧 C 路径 | 首次启动建议 Cold Boot；快照未删除或手工编辑 |
| 未启动客户端临时硬件配置 | 旧 hardware-qemu.ini 含 C 路径 | 属于生成文件，下次启动重新生成；本轮未做双端 LAN 验收 |

专项以 `-no-snapshot-load -no-snapshot-save` 冷启动目标 AVD，约 25 秒启动完成，设备身份保持一致，未发现快照不兼容/fallback。随后关闭本轮 emulator/qemu 进程。迁移不影响已验证的本地构建、AVD 冷启动和应用 smoke；旧 Quick Boot 快照属于剩余配置观察。

项目 `android/gradle.properties` 中遗留的 `gradle.user.home=D:\Develop\.gradle` 没有改变此次实际用户目录；现场 Gradle 输出仍为 E 盘。PATH 的 `java` 仍首先解析到旧 JDK 8，但 Flutter 已明确选用 Android Studio JBR 21，此次构建不受影响。全局 `NO_PROXY=_PROXY` 是既有回环代理问题，测试命令在当前进程补充回环地址，未修改系统代理。

## 6. 后续门禁

- 真机 Profile/Release：连续走棋、困难 AI、动效、页面滚动、低内存和长局的 UI/raster 帧及内存趋势。
- 双 Android 设备同一 Wi-Fi/热点：发现、加入、同步、双吃、30 秒重连、超时及复局。
- 正式签名、永久包名、商店材料、Google Play 测试渠道等发布资料继续按既有清单集中补齐。
- 本分支提供可审核改动；主分支合并由项目方审核后操作。

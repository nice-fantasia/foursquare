# 四子游戏（Four Square Chess）

一个基于 Flutter 的 4×4 移动吃子策略游戏。

> 当前状态：Phase 1 功能底座已完成，并提供不安装依赖的发布候选统一验证入口；Phase 2 的 iOS 工程与中英日界面工程切片已完成 Windows 代码、契约及 Android 回归验证，仍待 macOS/Xcode、真机和商店门禁。Phase 3 已完成未接入生产导航的权威在线客户端、本地 Node Socket.IO 双客户端真实传输测试、匿名身份保护、持久化终局 outbox 和生产容器静态契约；两台完整 Flutter 客户端或真机联调、真实 PostgreSQL、staging 和运维发布门禁仍未完成。Android/iOS 均尚未达到正式发布门禁。仓库中的历史完成报告和旧版本号不代表当前可发布状态。
> 当前范围与顺序以[产品路线图](docs/PRODUCT_ROADMAP.md)为准，规则以[四方棋规则与对局协议](docs/GAME_RULES.md)为准，文档有效性见[文档状态索引](docs/DOCUMENT_STATUS.md)。

## 项目概述

棋盘为 4×4 交点棋盘，墨方与玉方各有 4 枚棋子。玩家每次将一枚棋子移动到上下左右相邻的空位，并通过精确的四格排列触发横向或纵向吃子。完整吃子模式、50 ply 和棋、超时以及终局优先级见权威规则文档。

### Phase 1 目标范围

- Android 8.0（API 26）及以上，target API 36。
- 本地双人对战和三档难度 AI。
- 正式 LAN 对战，包括主机权威状态、60 秒回合、30 秒断线重连和全量同步。
- 单槽自动存档、首页继续游戏、统计及最近 20 局完整回放。
- 交互式教程、规则页面和无障碍基础能力。
- “现代东方棋艺”作为一期默认且唯一主题，并预留完整主题包架构。
- 音效、背景音乐、震动和减少动态效果设置。
- 中文界面；不含广告和应用内购买。

Phase 1 功能底座已经进入当前代码，但正式身份、签名、商店资料和真机发布验收仍未完成。上线前必须通过[发布门禁清单](docs/RELEASE_CHECKLIST.md)和[测试策略](docs/TEST_STRATEGY.md)。

### 后续正式阶段

- Phase 2：iOS 13 及以上完整对齐 Phase 1，并在 Android/iOS 同步完成中英日界面本地化。
- Phase 3：可靠在线对战，并首次引入彼此隔离的 staging 应用、服务器和数据库。
- Phase 4：普通对局语音能力和中文无屏冥想模式。

在线对战、语音控制和冥想模式不属于 Phase 1，不应出现在 Phase 1 的正式入口或商店功能承诺中。

## 技术栈

### 核心框架
- **Flutter** 3.35.6 stable - 当前构建验证版本
- **Dart** 3.9.2 - 当前构建验证版本

### 状态管理
- **flutter_bloc** ^8.1.3 - BLoC模式状态管理
- **equatable** ^2.0.5 - 值对象相等性比较

### 数据持久化
- **hive** ^2.2.3 - 轻量级NoSQL数据库
- **hive_flutter** ^1.1.0 - Hive Flutter集成
- **shared_preferences** ^2.2.2 - 简单键值存储

### 音频系统
- **audioplayers** ^5.2.1 - 音效播放

### UI增强
- **flutter_animate** ^4.3.0 - 动画效果
- **fl_chart** ^0.66.0 - 图表绘制

## 快速开始

### 环境要求

- Flutter SDK 3.35.6 stable（升级后必须重新执行完整验证）
- Dart SDK `>=3.0.0 <4.0.0`
- Android Studio / VS Code
- Android 8.0（API 26）及以上设备或模拟器
- iOS 构建与真机验证需要 macOS、Xcode 和 iOS 13 及以上设备或模拟器

仓库已包含 Phase 2 iOS 工程，最低系统版本为 iOS 13；Windows 只能验证工程契约，不能替代 Xcode、CocoaPods、模拟器、签名和归档验证。

### 安装步骤

1. **克隆项目**
   ```bash
   git clone https://github.com/nice-copacabana/foursquare.git
   cd foursquare
   ```

2. **安装依赖**
   ```bash
   flutter pub get
   ```

3. **运行项目**

   ```bash
   # Phase 1 日常开发环境
   flutter run --dart-define=ENV=development
   ```

   Phase 1/2 只定义 development 和 production。完整 staging 属于 Phase 3 集成与发布门禁，待外部基础设施信息集中补齐后建立，并与 production 的应用、服务器、数据库和诊断环境隔离。

### 构建发布版本

```bash
# 本地静态检查与测试
flutter analyze
flutter test

# Google Play 正式交付格式；需要正式签名环境变量
flutter build appbundle --release --dart-define=ENV=production
```

Windows 上已有依赖和工具链时，可运行 `./scripts/verify_release_candidate.ps1` 一次完成格式检查、静态分析、Flutter/Node 测试和 Debug APK 构建；脚本使用缓存依赖，不执行安装或升级，报告写入 `build/verification/`。Android 模拟器 smoke 只在显式传入脚本开关时执行。

release 构建不会回退使用 debug key。正式签名、永久包名、应用名称、隐私政策、Sentry 和商店素材未齐备时不得发布，详见[发布门禁清单](docs/RELEASE_CHECKLIST.md)。

## 游戏规则

以下仅为摘要；实现、测试、UI 和网络协议都必须以[四方棋规则与对局协议](docs/GAME_RULES.md)为准。

- 棋盘为 4×4 交点棋盘，黑白双方各 4 枚棋子。
- 每次只能把当前方的一枚棋子移动到上下左右相邻的空位，不能斜走、跳子或移动到已占用位置。
- 首局先手在本地双人、AI 和 LAN 中均随机决定；同一组对局复局时交替先手。
- 吃子只检查移动棋子所在的完整横行和纵列。以己方为 `1`、对方为 `0`、空位为 `E`，合法排列为 `1-1-0-E`、`E-1-1-0` 及其反向。
- 刚移动的棋子必须参与相邻的两个己方棋子；被动存在或由对方移动暴露出的结构不触发吃子。
- 同一次落子可以横向、纵向各吃一枚，最多吃 2 枚。
- 每方每回合 60 秒，超时方立即判负。
- 对方剩余棋子数小于等于 1 时获胜；连续 50 ply 没有吃子则和棋；轮到一方时无合法移动，该方判负。

## 项目结构

```
foursquare/
├── lib/
│   ├── ai/                 # AI系统
│   │   ├── ai_player.dart
│   │   ├── minimax_ai.dart
│   │   └── evaluation.dart
│   ├── bloc/               # 状态管理
│   │   ├── game_bloc.dart
│   │   ├── game_event.dart
│   │   └── game_state.dart
│   ├── engine/             # 游戏引擎
│   │   ├── game_engine.dart
│   │   ├── move_validator.dart
│   │   └── capture_detector.dart
│   ├── models/             # 数据模型
│   │   ├── board_state.dart
│   │   ├── position.dart
│   │   ├── piece_type.dart
│   │   ├── move.dart
│   │   ├── game_result.dart
│   │   └── game_save.dart
│   ├── services/           # 服务层
│   │   ├── audio_service.dart
│   │   └── storage_service.dart
│   ├── ui/                 # UI层
│   │   ├── screens/        # 页面
│   │   │   ├── home_page.dart
│   │   │   ├── game_page.dart
│   │   │   ├── statistics_page.dart
│   │   │   ├── rules_page.dart
│   │   │   └── settings_page.dart
│   │   └── widgets/        # 组件
│   │       ├── board_widget.dart
│   │       ├── animated_board_widget.dart
│   │       ├── board_painter.dart
│   │       ├── game_info_panel.dart
│   │       └── game_over_dialog.dart
│   └── main.dart           # 入口文件
├── test/                   # 单元测试
├── assets/                 # 资源文件
│   ├── images/
│   └── sounds/
├── docs/                   # 文档
├── pubspec.yaml
└── README.md
```

## 功能特性

### 当前代码状态

仓库已经完成 Phase 1 的本地双人、AI、LAN、存储、统计、回放、规则、教程、现代东方主题和基础无障碍实现。发布候选脚本会在不安装依赖的前提下统一执行格式、静态分析、Flutter 与服务端测试及 Debug APK 构建，并生成版本、提交、耗时、数量和哈希报告；真实设备、正式签名和商店门禁仍需人工执行。Phase 2 的 iOS 13 工程与中英日界面已完成 Windows 可执行的代码、契约和 Android 回归验证，仍待 macOS/Xcode、真机和商店外部门禁。Phase 3 当前具备匿名身份、版本化协议、服务端权威规则、指令幂等、60 秒超时、30 秒断线恢复、主动快照同步，以及不泄露设备/对局标识的中英日在线页面；本地真实 Socket.IO 测试已验证匹配、权威落子、断线、同身份恢复和快照刷新，其中包含两个具体 Flutter `OnlineGameTransport` 实例直连 Node 生产入口的显式启用型端到端测试。终局记录已固定完整权威快照，并通过 PostgreSQL 同库 outbox、内容哈希幂等、租约恢复、有界并发和指数抖动 worker 提供进程重启后的恢复基础；生产配置同时具备 fail-closed 数据库/CORS/可信代理输入、健康检查、输入与连接限流、总时限关机和独立 migration 容器契约。在线页面尚未接入生产导航，两台完整 Flutter 应用或真机的联调、真实 PostgreSQL migration/多 worker/慢租约、staging、TLS、备份恢复、负载和运维门禁尚未完成，因此仍不能视为可用或可发布功能。Phase 4 语音与冥想仍是隐藏的开发中功能；当前纯核心已包含默认不启动 TTS、日志与状态字符串脱敏、严格中文坐标/动作解析、可替换权限/识别/播报端口、支持中断恢复与播报失败重播的单次监听控制器、普通对局的类型化 GameEvent 适配器，以及维护开场、时钟、执色、AI、历史、未吃计数和终局的权威冥想 session 与 intent handler。普通 PVE 已增加不被 Home 使用的隐藏语音构造，只在权威状态给出真实玩家执色、轮到该玩家且用户确认用途说明后创建 session；位置、完整移动和取消选择只进入既有 GameBloc。完整移动会等待 GameBloc 提交匹配的权威走法后播报移动、完整吃子数或终局结果，未提交的命令不会误报成功；AI 状态不会截断播报，失败或后台中断的结果可手动重播，新局会丢弃上一局待播内容，且不会自动重开麦克风。PVP 与未定义的普通控制动作继续关闭。假语音端口已以查询、重复、选子取消、暂停恢复、退出取消和 AI 失败重试驱动 15 ply 自然终局的完整无屏对局；独立的版本化冥想存档已覆盖严格解码、历史重放校验、后台剩余时间冻结、旧修订防覆盖和独立 Hive 适配器。运行时已将每次权威修订串联到自动保存，并实现 AI 前耐久化屏障、恢复单飞和终局“保存→幂等归档→按对局删除”；`StorageService` 已统一管理冥想 Box 和重置生命周期，隐藏页面已接入中英日用途说明、显式启用、开场播报后启动时钟、单次聆听、生命周期暂停恢复、后台超时刷新与两段式弃局确认。隐藏生产组合页会在挂载后异步创建或恢复运行时，成功后才构造懒加载平台语音 Adapter，并为加载、无存档和脱敏失败提供三语状态与重试；它仍未接入 Home 或正式导航。基于锁定依赖的权限、单次识别和 completion 驱动播报 Adapter 已覆盖拒权、错误归一、迟到回调、并发、取消和终止回调超时；平台权限声明、设置跳转、真机音频与最终语音引擎隐私核验仍未完成。“隐藏页面自动化通过”不等于“达到正式发布质量”。

当前不能作出的发布承诺包括：

- 不能把 Windows 上的 iOS 工程契约测试视为 Xcode 构建、真机 LAN 或 TestFlight 已通过。
- 不能宣称在线后端、在线客户端、普通语音或冥想模式可用于 Phase 1/2。
- 不能宣称当前已有多套可发布主题；Phase 1 正式界面只提供现代东方棋艺主题。
- 不能宣称正式包名、Bundle ID、签名、商店身份或发布素材已经齐备。
- 不能引用未经当前 commit 实测的覆盖率、帧率、响应时间或测试通过率。

当前实际完成度应以代码、对应测试和[发布门禁清单](docs/RELEASE_CHECKLIST.md)逐项判断，不使用主观百分比。

## 开发文档

### 架构设计

项目采用BLoC架构模式，清晰分离UI层和业务逻辑层：

```
UI层 (Widgets)
    ↓ Events
BLoC层 (GameBloc)
    ↓ Business Logic
Engine层 (GameEngine)
    ↓ Data
Model层 (Models)
```

### 文档导航

#### 当前权威文档

- [文档状态索引](docs/DOCUMENT_STATUS.md)：区分当前权威文档、历史快照和未来方案。
- [产品路线图](docs/PRODUCT_ROADMAP.md)：四阶段范围、平台和环境边界。
- [四方棋规则与对局协议](docs/GAME_RULES.md)：规则、模式差异、终局顺序以及 LAN/在线权威协议不变量。
- [测试策略与验收矩阵](docs/TEST_STRATEGY.md)：测试分层、TDD 切片和发布证据。
- [发布门禁清单](docs/RELEASE_CHECKLIST.md)：Android、iOS、在线和语音阶段的发布条件。
- [隐私数据地图](docs/PRIVACY_DATA_MAP.md)：本地、LAN、诊断、在线和语音数据边界。
- [视觉设计系统](docs/VISUAL_DESIGN_SYSTEM.md)：现代东方棋艺与主题包架构。
- [待确认事项](docs/PENDING_CONFIRMATIONS.md)：集中记录正式发布前由项目方后补的外部输入与暂缓事项。
- [发布后增长、运营、容量与保护规划](docs/POST_LAUNCH_OPERATIONS_PLAN.md)：应用商店推广、聚合数据优化、服务器扩容、支持、安全与知识产权保护框架。

#### 历史与参考材料

- [变更日志](CHANGELOG.md)保存旧版本记录，但其中的历史测试和性能数字不能作为当前证据。
- `docs/reports/`、旧实施计划和旧阶段总结均保留为历史快照。
- `docs/guides/` 可提供操作参考，但涉及平台或商店政策时必须按发布清单重新核验官方要求。

### 核心模块

#### GameEngine (游戏引擎)
- 负责游戏核心逻辑执行
- 移动验证、吃子检测、胜负判定
- 提供AI模拟接口

#### GameBloc (状态管理)
- 处理所有游戏事件
- 管理游戏状态转换
- 协调各个服务

#### AI系统
- `AIPlayer`: AI接口定义
- `MinimaxAI`: Minimax算法实现
- `BoardEvaluator`: 局面评估

#### 数据持久化
- `StorageService`: 统一存储接口
- `GameStatistics`: 统计数据模型
- `GameSave`: 游戏存档模型

### 代码规范

- 遵循 Dart/Flutter 代码规范和仓库 `analysis_options.yaml`。
- UI、BLoC、规则引擎、模型和服务按职责分层。
- Dart 客户端规则只允许存在一个可执行真源；AI、回放和客户端网络层不得复制规则实现。在线服务端保留独立权威实现，并通过跨语言契约场景保证一致。
- 功能完成必须同时提供与风险相匹配的测试证据。

## 测试

### 运行测试

```bash
# 运行所有测试
flutter test

# 运行指定测试文件
flutter test test/bloc/game_bloc_test.dart

# 生成代码覆盖率报告
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
```

### 测试覆盖

- 现有测试覆盖模型、规则引擎、BLoC、服务和部分 Widget。
- Phase 2 仍需在 macOS/iOS 真机完成构建、生命周期、双端 LAN、旋转/尺寸、三语布局和发布包验收。
- 当前不公布未经同一 commit 实测的覆盖率或通过率；验收范围见[测试策略](docs/TEST_STRATEGY.md)。

## 性能优化

代码中使用 CustomPainter、RepaintBoundary 和 Alpha-Beta 剪枝等手段；是否达到目标帧率、响应时间和功耗要求，必须以最终 UI 和正式构建的设备测试为准。

## 贡献指南

欢迎贡献代码!请遵循以下步骤:

1. Fork 本项目
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 未来规划

正式路线固定为 Android → iOS 与三语界面 → 可靠在线 → 语音与冥想。更多主题通过 Phase 1 建立的主题包架构后续扩展；国内 Android 应用商店在 Google Play 版本稳定后再规划。未进入[产品路线图](docs/PRODUCT_ROADMAP.md)的社交、排行、账号、聊天、小程序和穿戴设备方案不属于当前承诺。

## 版本历史

`pubspec.yaml` 当前仍使用开发版本 `0.1.0`。仓库尚未形成满足本路线图门禁的 Google Play 正式版本；旧版本记录保留在 [CHANGELOG.md](CHANGELOG.md)，但不等同于商店发布证明。

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 致谢

- Flutter团队提供的优秀跨平台框架
- BLoC库提供的状态管理方案
- 所有开源贡献者

## 联系方式

- 项目仓库：[nice-copacabana/foursquare](https://github.com/nice-copacabana/foursquare)
- 问题反馈：[GitHub Issues](https://github.com/nice-copacabana/foursquare/issues)
- 正式支持邮箱将在发布门禁前补充。

---

使用 Flutter、BLoC 和确定性规则引擎构建。

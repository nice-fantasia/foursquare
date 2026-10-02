# 语音控制与冥想模式设计

## 1. 目标与范围

Phase 4 分两步交付：

1. 普通对局的可选中文语音控制与播报。
2. 基于同一权威规则链的中文无屏冥想对局。

当前已完成隐藏的普通语音纯核心和权威冥想 session，并用假端口跑通 15 ply 自然终局的无屏整局；运行时已串联自动保存、恢复和终局归档，现代东方隐藏页面已通过可替换端口接入用途说明、开场、单次聆听和触屏控制。隐藏生产组合页会在挂载后异步创建或恢复运行时，成功后才构造基于当前锁定插件版本的候选生产 Adapter；该 Adapter 已实现懒加载、单次识别、稳定错误映射、completion 驱动播报和迟到回调隔离。这些仍是本地自动化证据，尚未达到用户可用或商店可发布状态。首期不承诺英文、日文、手表或手环适配，也不在外部数据处理核验与平台声明完成前开放麦克风入口。

## 2. 不变量

- 权限请求必须发生在用途说明之后，并由用户显式操作触发。
- 默认不初始化 ASR/TTS，不自动开麦，不连续监听。
- 任意时刻麦克风与 TTS 不得重叠。
- 原始识别文本不进入游戏状态、日志、遥测、存档或网络。
- 语音只产生类型化意图，不能裁决合法移动、超时、吃子或终局。
- 普通对局的触屏和语音最终都经过 `GameBloc -> MoveValidator -> GameEngine`；冥想对局经过 `MeditationIntentHandler -> MeditationSessionController -> MoveValidator/GameEngine`。
- 普通对局的 AI 授权移动只能由现有 AI 事件链产生，语音永远不能设置 `isAIMove: true`；冥想 AI 只通过注入的 `AIPlayer` 产生候选步，并由同一 session controller 提交。
- 4×4 棋盘的歧义中心不自动映射；不完整、否定或多候选指令不执行。

## 3. 已实现的普通语音核心

```text
voice_ports.dart
  ├─ MicrophonePermissionPort
  ├─ VoiceRecognitionPort
  └─ VoiceSynthesisPort

voice_interaction_controller.dart
  └─ 权限、初始化、单次监听、播报互斥、打断、恢复、销毁

voice_game_intent.dart
  └─ VoicePositionIntent / VoiceMoveIntent / VoiceActionIntent

voice_game_intent_dispatcher.dart
  └─ 类型化意图 -> 普通 GameEvent

game_bloc.dart
  └─ ActivateBoardPositionEvent -> 选中/重选/取消/权威移动
```

`VoiceInteractionController` 的状态不保存识别文本，只保存阶段和稳定失败枚举。异步操作使用代次隔离；播报抢占监听、页面销毁或音频中断后，旧回调不能提交意图或恢复旧状态。权威指令已经提交但 TTS 失败时，仅在内存缓存生成后的待播回复并允许重播；其 `toString()` 不暴露正文，也不会重新解释或执行原指令。

`PlatformVoiceAdapters` 构造本身无平台副作用：权限只在明确 check/request 时访问 `Permission.microphone`，STT/TTS 实例只在 controller 进入 initialize 后创建。STT 使用 `zh-CN`、confirmation、partial result 和 cancel-on-error，缺失置信度按插件语义归一；停止采用 cancel，所有错误仅映射为稳定枚举。TTS 的 `speak()` 只由 start 后的 completion 回调成功结算，cancel/error 均失败并保留 controller 的重播路径；停止等待明确终止回调，超时后熔断该端口，避免旧回调污染下一次播报。

## 4. 普通对局当前实现与后续设计

普通对局已完成第一段隐藏 PVE 装配：`GamePage.voice` 只注入惰性 session factory，Home 的 PVP/PVE/继续游戏仍使用不带语音能力的默认构造。页面只有在真实 `GamePlaying` 已提供 `humanPlayer`、当前确为该玩家回合且用户点击用途说明后的启用按钮时，才创建候选生产 Adapter 和 controller。当前页面负责：

- 展示用途说明和明确的启用按钮。
- 展示 `disabled / ready / listening / processing / speaking / failed` 等非敏感状态。
- 把类型化意图交给 `VoiceGameIntentDispatcher`。
- 在后台、AI 回合和终局时打断监听；回到玩家回合只恢复为 ready，不自动开麦。
- 在页面销毁时释放 controller。

该切片只提交位置、完整移动和取消选择事件。位置和取消选择保持静默；完整移动在派发前订阅 GameBloc 状态，只在 move count、起止位置和移动执色均匹配的权威提交出现后播报成功、完整吃子数或终局结果，超时、拒绝、后台或不匹配状态均不会误报成功。结果 TTS 的保护期覆盖真实 completion，AI 状态不会截断播报；失败或后台中断的已授权结果可以重播且不会重新派发命令，新 `matchId` 会清除上一局待播结果。普通对局的暂停、恢复、退出和查询等尚未定义完成结果的语音动作保持安全无操作。本地 PVP 在提供明确受控执色 UX 前继续不显示语音面板，不能从当前方或先手方猜测“己方”；PVE 只使用权威状态中的 `humanPlayer`。

## 5. 冥想模式重建设计

旧 `MeditationModeBloc`、事件/状态和不可达页面原型已移除；这些原型曾直接协调识别/TTS、未完整保留权威对局字段，暂停/恢复和超时也不完整。后续只在新的权威 session 上推进。

冥想模式当前围绕一份完整权威 session 重建：

```text
MeditationSession
  ├─ BoardState
  ├─ currentPlayer / humanPlayer / firstPlayer
  ├─ moveHistory / noCapturePlyCount
  ├─ TurnClock
  ├─ selectedPosition
  └─ result / lifecycle

VoiceInteractionController
  -> MeditationIntentHandler
  -> MeditationSessionController
  -> GameEngine / MoveValidator / TurnClock
  -> committed MeditationSession
  -> MeditationSessionCommitter
  -> versioned save / idempotent archive / conditional delete
  -> MeditationPrompt
```

核心要求：

- AI、时钟和语音端口全部可注入。
- 每次播报只描述已经提交的权威状态。
- 暂停冻结离线时钟；恢复只回到可监听状态，不自动开麦。
- 查询棋盘、重复播报、取消、退出等控制动作与移动意图分离。
- 双吃、50 ply 和棋、无路可走、棋子数终局、60 秒超时与普通引擎完全一致。
- 退出前确认并按产品定义保存或明确放弃，不丢失对局身份和历史。

当前核心已经实现上述 session、统一引擎提交、开场完成后启动时钟、AI 先手与失败重试、查询/暂停/恢复/退出确认，并由假端口驱动 15 ply 自然终局的无屏整局。独立版本化存档已实现严格解码、剩余时间冻结、权威恢复校验和 Hive 适配；`MeditationSessionRuntime` 已实现每次权威修订的自动保存、绝对时限驱动、AI 前耐久化屏障、恢复单飞、销毁后迟到结果隔离，以及终局先保存、再幂等归档、最后按 `matchId` 删除的收口顺序。`StorageService` 已统一管理冥想 Box，隐藏页面已接入中英日用途说明、开场 TTS 完成后启动时钟、单次聆听、暂停恢复和两段式弃局确认。候选生产语音 Adapter 已由隐藏组合页接入真实运行时加载边界；该入口仍未进入 Home 或正式导航，仍需平台权限与设置跳转、真机验收和外部数据处理核验。

## 6. 无屏验收脚本

使用假权限、假识别、可控 TTS completion、假 AI 和假时钟完成自动化整局：

1. 用途说明后授权并播报开局、执色、初始棋盘和行棋方式。
2. 单坐标选择和完整“从哪到哪”移动都能进入同一权威规则链。
3. 非法、模糊、否定和低置信度输入不改变棋盘。
4. AI 移动完成后准确播报来源、目标、全部吃子和当前棋盘。
5. 覆盖查询、重复、取消、暂停、恢复和退出。
6. 覆盖双吃、终局、超时、音频中断和页面销毁。
7. 全流程不读取屏幕也能完成，且任何日志/状态中都没有识别原文。

## 7. 发布前外部依赖

- 最终 ASR/TTS 引擎及 Android/iOS 支持范围。
- 在线或离线处理边界、数据处理区域、保留期限和第三方条款。
- 平台权限用途文案、隐私政策 URL 和商店数据安全声明。
- Android/iOS 真机、来电、蓝牙、后台、音频焦点和网络降级验证。

这些依赖阻塞候选 Adapter 的最终选型确认、隐私声明、平台权限和真机发布，不阻塞纯 Dart 核心、权威 session、Adapter 契约自动化和假端口整局验证。

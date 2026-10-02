/// Game Replay Page - 游戏回放页面
///
/// 显示游戏回放界面，包括：
/// - 棋盘显示（只读）
/// - 回放控制按钮
/// - 步骤导航
/// - 移动历史列表
library;

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/move.dart';
import '../../models/piece_type.dart';
import '../../services/game_replay_service.dart';
import '../widgets/themed_board_widget.dart';
import '../widgets/board_position_label.dart';

class GameReplayPage extends StatefulWidget {
  /// 移动历史
  final List<Move> moveHistory;

  /// 游戏模式标题
  final String? gameTitle;
  final PieceType startingPlayer;

  const GameReplayPage({
    super.key,
    required this.moveHistory,
    this.gameTitle,
    this.startingPlayer = PieceType.black,
  });

  @override
  State<GameReplayPage> createState() => _GameReplayPageState();
}

class _GameReplayPageState extends State<GameReplayPage> {
  late final GameReplayService _replayService;
  late ReplayState _replayState;

  @override
  void initState() {
    super.initState();
    _replayService = GameReplayService();
    _replayState = _replayService.startReplay(
      widget.moveHistory,
      startingPlayer: widget.startingPlayer,
    );
  }

  @override
  void dispose() {
    _replayService.exitReplay();
    super.dispose();
  }

  void _updateState(ReplayState newState) {
    setState(() {
      _replayState = newState;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.gameTitle ?? l10n.replayTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showReplayInfo,
            tooltip: l10n.replayHelp,
          ),
        ],
      ),
      body: Column(
        children: [
          // 步骤信息
          _buildStepInfo(),

          // 棋盘显示
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ThemedBoardWidget(
                    boardState: _replayState.boardState,
                    selectedPiece: null,
                    validMoves: const [],
                    lastMoveFrom: _replayState.currentMove?.from,
                    lastMoveTo: _replayState.currentMove?.to,
                    capturedPiecePositions:
                        _replayState.currentMove?.capturedPieces ?? const [],
                    onPositionTapped: (_) {}, // 禁用交互
                  ),
                ),
              ),
            ),
          ),

          // 当前移动信息
          if (_replayState.currentMove != null) _buildCurrentMoveInfo(),

          // 回放控制按钮
          _buildControls(),

          // 移动历史列表
          _buildMoveHistory(),
        ],
      ),
    );
  }

  Widget _buildStepInfo() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.history, size: 20),
          const SizedBox(width: 8),
          Text(
            _replayState.isAtStart
                ? l10n.replayInitial
                : l10n.replayProgress(
                    _replayState.currentStep + 1,
                    _replayState.totalSteps,
                  ),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentMoveInfo() {
    final move = _replayState.currentMove!;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            move.hasCapture ? Icons.close : Icons.arrow_forward,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _moveDescription(move, l10n),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 进度条
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: (_replayState.currentStep + 1).toDouble(),
              min: 0,
              max: _replayState.totalSteps.toDouble(),
              divisions:
                  _replayState.totalSteps > 0 ? _replayState.totalSteps : 1,
              label: _replayState.isAtStart
                  ? l10n.replayInitial
                  : l10n.replayStepLabel(_replayState.currentStep + 1),
              onChanged: (value) {
                _updateState(_replayService.goToStep(value.toInt() - 1));
              },
            ),
          ),
          const SizedBox(height: 8),

          // 控制按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.first_page),
                onPressed: _replayState.canGoBackward
                    ? () => _updateState(_replayService.goToStart())
                    : null,
                tooltip: l10n.replayFirst,
              ),
              IconButton(
                icon: const Icon(Icons.navigate_before),
                onPressed: _replayState.canGoBackward
                    ? () => _updateState(_replayService.goBackward())
                    : null,
                tooltip: l10n.replayPrevious,
              ),
              IconButton(
                icon: const Icon(Icons.navigate_next),
                onPressed: _replayState.canGoForward
                    ? () => _updateState(_replayService.goForward())
                    : null,
                tooltip: l10n.replayNext,
              ),
              IconButton(
                icon: const Icon(Icons.last_page),
                onPressed: _replayState.canGoForward
                    ? () => _updateState(_replayService.goToEnd())
                    : null,
                tooltip: l10n.replayLast,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMoveHistory() {
    if (widget.moveHistory.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor,
          ),
        ),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: widget.moveHistory.length,
        itemBuilder: (context, index) {
          final move = widget.moveHistory[index];
          final isCurrentStep = index == _replayState.currentStep;

          return Card(
            color: isCurrentStep
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            elevation: isCurrentStep ? 2 : 0,
            child: ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                child: Text('${index + 1}'),
              ),
              title: Text(
                _moveDescription(move, AppLocalizations.of(context)!),
                style: TextStyle(
                  fontWeight: isCurrentStep ? FontWeight.bold : null,
                ),
              ),
              trailing:
                  move.hasCapture ? const Icon(Icons.close, size: 20) : null,
              onTap: () {
                _updateState(_replayService.goToStep(index));
              },
            ),
          );
        },
      ),
    );
  }

  void _showReplayInfo() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.replayHelp),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.replayControlsHeading),
              const SizedBox(height: 8),
              Text('• ${l10n.replayHelpSlider}'),
              Text('• ${l10n.replayHelpButtons}'),
              Text('• ${l10n.replayHelpHistory}'),
              const SizedBox(height: 16),
              Text(l10n.replayFeaturesHeading),
              const SizedBox(height: 8),
              Text('• ${l10n.replayHelpReadonly}'),
              Text('• ${l10n.replayHelpHighlight}'),
              Text('• ${l10n.replayHelpCapture}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.gotIt),
          ),
        ],
      ),
    );
  }

  String _moveDescription(Move move, AppLocalizations l10n) {
    final from = formatBoardPositionLabel(l10n, move.from);
    final to = formatBoardPositionLabel(l10n, move.to);
    if (move.captureCount > 0) {
      return l10n.moveDescriptionCapture(
        from,
        to,
        move.captureCount,
      );
    }
    return l10n.moveDescription(from, to);
  }
}

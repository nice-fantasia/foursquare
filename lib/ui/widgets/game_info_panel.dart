/// Game Info Panel - 游戏信息面板
///
/// 职责：
/// - 显示当前玩家
/// - 显示双方棋子数量
/// - 显示移动历史
/// - 提供撤销按钮
library;

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/piece_type.dart';
import '../../models/move.dart';
import 'board_position_label.dart';

/// 游戏信息面板
class GameInfoPanel extends StatelessWidget {
  final PieceType currentPlayer;
  final int blackPieceCount;
  final int whitePieceCount;
  final List<Move> moveHistory;
  final bool canUndo;
  final bool canRedo;
  final bool flipBoard;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onRestart;
  final bool isAIThinking;
  final double aiThinkingProgress;
  final String aiThinkingStatus;
  final Duration turnRemaining;

  const GameInfoPanel({
    super.key,
    required this.currentPlayer,
    required this.blackPieceCount,
    required this.whitePieceCount,
    required this.moveHistory,
    required this.canUndo,
    required this.canRedo,
    this.flipBoard = false,
    this.onUndo,
    this.onRedo,
    this.onRestart,
    this.isAIThinking = false,
    this.aiThinkingProgress = 0.0,
    this.aiThinkingStatus = '',
    this.turnRemaining = Duration.zero,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).dividerColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 当前玩家指示器
          _CurrentPlayerIndicator(
            currentPlayer: currentPlayer,
            isAIThinking: isAIThinking,
            turnRemaining: turnRemaining,
          ),
          const SizedBox(height: 16),

          // AI思考指示器
          if (isAIThinking)
            _AIThinkingIndicator(
              progress: aiThinkingProgress,
              status: aiThinkingStatus,
            ),
          if (isAIThinking) const SizedBox(height: 16),

          // 棋子数量统计
          _PieceCountSection(
            blackCount: blackPieceCount,
            whiteCount: whitePieceCount,
          ),
          const SizedBox(height: 16),

          // 移动历史
          _MoveHistorySection(
            moveHistory: moveHistory,
            flipBoard: flipBoard,
          ),
          const SizedBox(height: 16),

          // 操作按钮
          _ActionButtons(
            canUndo: canUndo,
            canRedo: canRedo,
            onUndo: onUndo,
            onRedo: onRedo,
            onRestart: onRestart,
          ),
        ],
      ),
    );
  }
}

/// 当前玩家指示器
class _CurrentPlayerIndicator extends StatelessWidget {
  final PieceType currentPlayer;
  final bool isAIThinking;
  final Duration turnRemaining;

  const _CurrentPlayerIndicator({
    required this.currentPlayer,
    required this.isAIThinking,
    required this.turnRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final seconds = turnRemaining.inSeconds.clamp(0, 60);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: currentPlayer == PieceType.black
                ? Colors.grey.shade800
                : Colors.white,
            border: Border.all(
              color: Colors.grey.shade400,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: (currentPlayer == PieceType.black
                        ? Colors.amber
                        : Colors.blue)
                    .withValues(alpha: 0.5),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                currentPlayer == PieceType.black
                    ? l10n.blackTurn
                    : l10n.whiteTurn,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (isAIThinking)
                Text(
                  l10n.aiThinking,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
        ),
        Semantics(
          label: l10n.turnSecondsRemaining(seconds),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: seconds <= 10
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              l10n.secondsCount(seconds),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 棋子数量统计区域
class _PieceCountSection extends StatelessWidget {
  final int blackCount;
  final int whiteCount;

  const _PieceCountSection({
    required this.blackCount,
    required this.whiteCount,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _PieceCounter(
          label: l10n.blackSide,
          count: blackCount,
          color: Colors.grey.shade800,
        ),
        Container(
          width: 1,
          height: 40,
          color: Colors.grey.shade300,
        ),
        _PieceCounter(
          label: l10n.whiteSide,
          count: whiteCount,
          color: Colors.white,
          borderColor: Colors.grey.shade400,
        ),
      ],
    );
  }
}

/// 单个棋子计数器
class _PieceCounter extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final Color? borderColor;

  const _PieceCounter({
    required this.label,
    required this.count,
    required this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: borderColor != null
                ? Border.all(color: borderColor!, width: 2)
                : null,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade600,
          ),
        ),
        Text(
          '$count',
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

/// 移动历史区域
class _MoveHistorySection extends StatelessWidget {
  final List<Move> moveHistory;
  final bool flipBoard;

  const _MoveHistorySection({
    required this.moveHistory,
    required this.flipBoard,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.history, size: 16, color: Colors.grey),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                l10n.moveHistoryCount(moveHistory.length),
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 80,
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: moveHistory.isEmpty
              ? Center(
                  child: Text(
                    l10n.noMoveHistory,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: moveHistory.length,
                  itemBuilder: (context, index) {
                    final move = moveHistory[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Text(
                            '${index + 1}.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: move.player == PieceType.black
                                  ? Colors.grey.shade800
                                  : Colors.white,
                              border: Border.all(
                                color: Colors.grey.shade400,
                                width: 1,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${formatBoardPositionLabel(l10n, move.from, flipBoard: flipBoard)}'
                              ' → '
                              '${formatBoardPositionLabel(l10n, move.to, flipBoard: flipBoard)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          if (move.captureCount > 0)
                            Row(
                              children: [
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.close,
                                  size: 12,
                                  color: Colors.red,
                                ),
                                if (move.captureCount > 1)
                                  Text(
                                    '${move.captureCount}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// AI思考指示器
class _AIThinkingIndicator extends StatelessWidget {
  final double progress;
  final String status;

  const _AIThinkingIndicator({
    required this.progress,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.blue.shade200,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Colors.blue.shade600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.aiThinking,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.blue.shade800,
                ),
              ),
              const Spacer(),
              Text(
                '${(progress * 100).toInt()}%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.blue.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.blue.shade400,
              ),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 操作按钮区域
class _ActionButtons extends StatelessWidget {
  final bool canUndo;
  final bool canRedo;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onRestart;

  const _ActionButtons({
    required this.canUndo,
    required this.canRedo,
    this.onUndo,
    this.onRedo,
    this.onRestart,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        // 撤销和重做按钮（暂时禁用，避免动画问题）
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canUndo ? onUndo : null,
                icon: const Icon(Icons.undo, size: 18),
                label: Text(l10n.undo),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canRedo ? onRedo : null,
                icon: const Icon(Icons.redo, size: 18),
                label: Text(l10n.redo),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 重新开始按钮
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: onRestart,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(l10n.restart),
          ),
        ),
      ],
    );
  }
}

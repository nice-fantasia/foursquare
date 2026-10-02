/// Game Over Dialog - 游戏结束对话框
///
/// 职责：
/// - 显示游戏结束信息
/// - 显示胜负结果和原因
/// - 提供重新开始和返回选项
library;

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/piece_type.dart';
import '../../models/game_result.dart';

/// 游戏结束对话框
class GameOverDialog extends StatelessWidget {
  final PieceType? winner;
  final GameResult gameResult;
  final VoidCallback onRestart;
  final VoidCallback onExit;
  final VoidCallback? onReplay; // 新增：查看回放

  const GameOverDialog({
    super.key,
    required this.winner,
    required this.gameResult,
    required this.onRestart,
    required this.onExit,
    this.onReplay, // 新增：查看回放
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      elevation: 8,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _getGradientColors(),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题图标
            Icon(
              _getResultIcon(),
              size: 64,
              color: Colors.white,
            ),
            const SizedBox(height: 16),

            // 结果标题
            Text(
              _getResultTitle(l10n, winner, gameResult),
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),

            // 结果详情
            Text(
              _getResultReason(l10n, winner, gameResult),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 24),

            // 按钮组
            Column(
              children: [
                // 第一行：重新开始 和 退出
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // 退出按钮
                    _DialogButton(
                      icon: Icons.close,
                      label: l10n.exit,
                      onPressed: onExit,
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                    ),

                    // 重新开始按钮
                    _DialogButton(
                      icon: Icons.refresh,
                      label: l10n.playAgain,
                      onPressed: onRestart,
                      backgroundColor: Colors.white.withValues(alpha: 0.3),
                    ),
                  ],
                ),

                // 第二行：查看回放（如果可用）
                if (onReplay != null) const SizedBox(height: 12),
                if (onReplay != null)
                  SizedBox(
                    width: double.infinity,
                    child: _DialogButton(
                      icon: Icons.play_circle_outline,
                      label: l10n.viewReplay,
                      onPressed: onReplay!,
                      backgroundColor: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 获取渐变色
  List<Color> _getGradientColors() {
    switch (gameResult.status) {
      case GameStatus.blackWin:
        return [Colors.amber.shade700, Colors.orange.shade800];
      case GameStatus.whiteWin:
        return [Colors.blue.shade600, Colors.indigo.shade700];
      case GameStatus.draw:
        return [Colors.grey.shade600, Colors.grey.shade800];
      default:
        return [Colors.grey.shade600, Colors.grey.shade800];
    }
  }

  /// 获取结果图标
  IconData _getResultIcon() {
    if (winner != null) return Icons.emoji_events;
    switch (gameResult.status) {
      case GameStatus.blackWin:
      case GameStatus.whiteWin:
        return Icons.emoji_events;
      case GameStatus.draw:
        return Icons.handshake;
      default:
        return Icons.info;
    }
  }

  /// 获取结果标题
  static String _getResultTitle(
    AppLocalizations l10n,
    PieceType? winner,
    GameResult gameResult,
  ) {
    final resolvedWinner = winner ?? gameResult.winner;
    if (resolvedWinner != null) {
      return resolvedWinner == PieceType.black
          ? l10n.blackWins
          : l10n.whiteWins;
    }
    switch (gameResult.status) {
      case GameStatus.blackWin:
        return l10n.blackWins;
      case GameStatus.whiteWin:
        return l10n.whiteWins;
      case GameStatus.draw:
        return l10n.draw;
      default:
        return l10n.gameOver;
    }
  }

  static String _getResultReason(
    AppLocalizations l10n,
    PieceType? winner,
    GameResult gameResult,
  ) {
    final resolvedWinner = winner ?? gameResult.winner;
    final blackWon = resolvedWinner == PieceType.black;
    switch (gameResult.endReason) {
      case GameEndReason.pieceCount:
        return blackWon
            ? l10n.endReasonPieceCountBlack
            : l10n.endReasonPieceCountWhite;
      case GameEndReason.noLegalMoves:
        return blackWon
            ? l10n.endReasonNoLegalMovesBlack
            : l10n.endReasonNoLegalMovesWhite;
      case GameEndReason.noCaptureLimit:
        return l10n.endReasonNoCaptureLimit;
      case GameEndReason.timeout:
        return blackWon
            ? l10n.endReasonTimeoutBlack
            : l10n.endReasonTimeoutWhite;
      case GameEndReason.disconnect:
        return blackWon
            ? l10n.endReasonDisconnectBlack
            : l10n.endReasonDisconnectWhite;
      case GameEndReason.abandoned:
        return blackWon
            ? l10n.endReasonAbandonedBlack
            : l10n.endReasonAbandonedWhite;
    }
  }
}

/// Compact result that keeps the final board visible in the game layout.
class GameResultSummary extends StatelessWidget {
  const GameResultSummary({
    super.key,
    required this.gameResult,
    required this.onRestart,
    required this.onExit,
    this.onReplay,
  });

  final GameResult gameResult;
  final VoidCallback onRestart;
  final VoidCallback onExit;
  final VoidCallback? onReplay;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                GameOverDialog._getResultTitle(
                  l10n,
                  gameResult.winner,
                  gameResult,
                ),
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              GameOverDialog._getResultReason(
                l10n,
                gameResult.winner,
                gameResult,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(onPressed: onRestart, child: Text(l10n.playAgain)),
                if (onReplay != null)
                  OutlinedButton(
                    onPressed: onReplay,
                    child: Text(l10n.viewReplay),
                  ),
                TextButton(onPressed: onExit, child: Text(l10n.exit)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 对话框按钮组件
class _DialogButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color backgroundColor;

  const _DialogButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 显示游戏结束对话框的辅助函数
Future<void> showGameOverDialog(
  BuildContext context, {
  required PieceType? winner,
  required GameResult gameResult,
  required VoidCallback onRestart,
  required VoidCallback onExit,
  VoidCallback? onReplay, // 新增：查看回放
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => GameOverDialog(
      winner: winner,
      gameResult: gameResult,
      onRestart: onRestart,
      onExit: onExit,
      onReplay: onReplay, // 传递回放回调
    ),
  );
}

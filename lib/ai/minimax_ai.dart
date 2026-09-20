/// Minimax AI - Minimax算法实现（优化版）
///
/// 职责：
/// - 实现Minimax搜索算法
/// - Alpha-Beta剪枝优化
/// - 置换表缓存优化
/// - 移动排序启发式
/// - 动态深度调整
/// - 迭代加深搜索
/// - 提供不同难度的AI
library;

import 'dart:math';
import '../models/board_state.dart';
import '../models/piece_type.dart';
import '../models/position.dart';
import '../engine/game_engine.dart';
import 'ai_player.dart';
import 'evaluation.dart';

/// 置换表条目
class _TranspositionEntry {
  final int score;
  final int depth;

  _TranspositionEntry(this.score, this.depth);
}

class _SearchTimeout implements Exception {
  const _SearchTimeout();
}

/// Minimax AI实现（优化版）
class MinimaxAI extends AIPlayer {
  final GameEngine _engine = GameEngine();
  final int _baseDepth;
  final Random _random;

  // 置换表（缓存已评估的局面）
  final Map<String, _TranspositionEntry> _transpositionTable = {};
  static const int _maxTranspositionTableSize = 10000;

  // 历史启发式（记录好的移动）
  final Map<String, int> _historyTable = {};
  int _nodesEvaluated = 0;
  Stopwatch? _searchStopwatch;
  int _timeLimitMilliseconds = 0;

  // AI思考进度回调
  Function(double progress, String status)? _progressCallback;

  MinimaxAI(super.difficulty, {Random? random})
      : _baseDepth = _getDepthForDifficulty(difficulty),
        _random = random ?? Random();

  /// 设置进度回调
  void setProgressCallback(Function(double progress, String status)? callback) {
    _progressCallback = callback;
  }

  static int _getDepthForDifficulty(AIDifficulty difficulty) {
    switch (difficulty) {
      case AIDifficulty.easy:
        return 2;
      case AIDifficulty.medium:
        return 4; // 从med3层提升到4层
      case AIDifficulty.hard:
        return 6;
    }
  }

  /// 获取难度对应的时间限制（毫秒）
  static int _getTimeLimitForDifficulty(AIDifficulty difficulty) {
    switch (difficulty) {
      case AIDifficulty.easy:
        return 100;
      case AIDifficulty.medium:
        return 500;
      case AIDifficulty.hard:
        return 1800;
    }
  }

  @override
  String get name => 'Minimax AI (优化版)';

  @override
  String get description => 'AI使用优化的Minimax算法：置换表、移动排序、动态深度、迭代加深';

  /// 动态调整搜索深度
  int _getDynamicDepth(BoardState board) {
    // 统计棋盘上的棋子总数
    int totalPieces = 0;
    for (int x = 0; x < 4; x++) {
      for (int y = 0; y < 4; y++) {
        final piece = board.getPiece(Position(x, y));
        if (piece != PieceType.empty) {
          totalPieces++;
        }
      }
    }

    // 根据棋子数量调整深度（优化后）
    if (totalPieces >= 6) {
      return _baseDepth; // 开局，使用基础深度
    } else if (totalPieces >= 4) {
      return _baseDepth + 1; // 中局，增加1层
    } else {
      return _baseDepth + 2; // 残局，增加2层以精确计算
    }
  }

  /// 生成棋盘哈希值（用于置换表）
  String _getBoardHash(BoardState board, PieceType aiPlayer) {
    final buffer = StringBuffer();
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        final piece = board.getPiece(Position(x, y));
        buffer.write(
          piece == PieceType.black
              ? 'B'
              : piece == PieceType.white
                  ? 'W'
                  : 'E',
        );
      }
    }
    buffer.write(board.currentPlayer == PieceType.black ? 'B' : 'W');
    buffer.write(aiPlayer == PieceType.black ? 'B' : 'W');
    return buffer.toString();
  }

  /// 移动排序启发式
  List<_MoveOption> _sortMoves(
    List<_MoveOption> moves,
    BoardState board,
    PieceType player,
  ) {
    // 为每个移动计算优先级分数
    final scoredMoves = <_ScoredMove>[];

    for (final move in moves) {
      int priority = 0;

      // 1. 检查是否可以吃子（最高优先级）
      final nextBoard = _engine.simulateMove(board, move.from, move.to);
      if (nextBoard != null) {
        final capturedCount = board.getPieceCount(player.getOpponent()) -
            nextBoard.getPieceCount(player.getOpponent());
        priority += capturedCount * 1000;
        final gameResult = _engine.checkGameOver(nextBoard);
        if (gameResult?.winner == player) {
          priority += 100000;
        }
      }

      // 2. 检查历史启发式
      final historyKey =
          '${move.from.x},${move.from.y}-${move.to.x},${move.to.y}';
      priority += _historyTable[historyKey] ?? 0;

      // 3. 中心位置优先
      final centerDistance = (move.to.x - 1.5).abs() + (move.to.y - 1.5).abs();
      priority += (4 - centerDistance * 10).toInt();

      scoredMoves.add(_ScoredMove(move, priority));
    }

    // 按优先级降序排序
    scoredMoves.sort((a, b) => b.priority.compareTo(a.priority));
    return scoredMoves.map((sm) => sm.move).toList();
  }

  @override
  Future<AIMoveResult?> selectMove(BoardState board) async {
    final stopwatch = Stopwatch()..start();
    _nodesEvaluated = 0;

    // 清理置换表（避免内存过大）
    if (_transpositionTable.length > _maxTranspositionTableSize) {
      _transpositionTable.clear();
    }

    final possibleMoves = _engine.getPossibleMoves(board, board.currentPlayer);
    if (possibleMoves.isEmpty) return null;

    // 转换为移动列表
    final moveList = <_MoveOption>[];
    for (final entry in possibleMoves.entries) {
      for (final to in entry.value) {
        moveList.add(_MoveOption(from: entry.key, to: to));
      }
    }

    if (moveList.isEmpty) return null;

    // 动态调整深度
    final maxDepth = _getDynamicDepth(board);
    final timeLimit = _getTimeLimitForDifficulty(difficulty);
    _searchStopwatch = stopwatch;
    _timeLimitMilliseconds = timeLimit;

    // 对移动进行排序
    final sortedMoves = _sortMoves(moveList, board, board.currentPlayer);

    Position? bestFrom = sortedMoves.first.from;
    Position? bestTo = sortedMoves.first.to;
    int bestScore = -9999999;
    var completedScores = <_ScoredMove>[];

    // 迭代加深搜索（从深度1开始，逐步增加）
    for (int depth = 1; depth <= maxDepth; depth++) {
      // 检查是否超时
      if (stopwatch.elapsedMilliseconds >= timeLimit) {
        break;
      }

      // 报告进度
      _progressCallback?.call(
        depth / maxDepth,
        '搜索深度 $depth/$maxDepth',
      );

      Position? iterationBestFrom;
      Position? iterationBestTo;
      int iterationBestScore = -9999999;
      final iterationScores = <_ScoredMove>[];

      try {
        for (final move in sortedMoves) {
          _checkDeadline();
          final nextBoard = _engine.simulateMove(board, move.from, move.to);
          if (nextBoard == null) continue;

          final score = _minimax(
            nextBoard,
            depth - 1,
            -9999999,
            9999999,
            false,
            board.currentPlayer,
          );
          iterationScores.add(_ScoredMove(move, score));

          if (score > iterationBestScore) {
            iterationBestScore = score;
            iterationBestFrom = move.from;
            iterationBestTo = move.to;

            // 更新历史表
            final historyKey =
                '${move.from.x},${move.from.y}-${move.to.x},${move.to.y}';
            _historyTable[historyKey] =
                (_historyTable[historyKey] ?? 0) + depth;
          }
        }
      } on _SearchTimeout {
        break;
      }

      if (iterationBestFrom != null && iterationBestTo != null) {
        bestScore = iterationBestScore;
        bestFrom = iterationBestFrom;
        bestTo = iterationBestTo;
        completedScores = iterationScores;
      }
    }

    if (bestFrom == null || bestTo == null) return null;

    if (difficulty == AIDifficulty.easy && completedScores.length > 1) {
      completedScores.sort((a, b) => b.priority.compareTo(a.priority));
      final winningMoves = completedScores
          .where((candidate) => candidate.priority >= 10000)
          .toList(growable: false);
      final nonLosingMoves = completedScores
          .where((candidate) => candidate.priority > -10000)
          .toList(growable: false);
      final rankedPool = winningMoves.isNotEmpty
          ? winningMoves
          : nonLosingMoves.isNotEmpty
              ? nonLosingMoves
              : completedScores;
      final candidates = rankedPool.take(min(3, rankedPool.length)).toList();
      final selected = candidates[_random.nextInt(candidates.length)];
      bestFrom = selected.move.from;
      bestTo = selected.move.to;
      bestScore = selected.priority;
    }

    // 完成进度
    _progressCallback?.call(1.0, '完成，评估了 $_nodesEvaluated 个节点');

    return AIMoveResult(
      from: bestFrom,
      to: bestTo,
      score: bestScore,
      nodesEvaluated: _nodesEvaluated,
      thinkingTime: stopwatch.elapsed,
    );
  }

  int _minimax(
    BoardState board,
    int depth,
    int alpha,
    int beta,
    bool isMaximizing,
    PieceType aiPlayer,
  ) {
    _checkDeadline();
    _nodesEvaluated++;

    // 检查置换表
    final boardHash = _getBoardHash(board, aiPlayer);
    final cached = _transpositionTable[boardHash];
    if (cached != null && cached.depth >= depth) {
      return cached.score;
    }

    // 检查游戏结束
    final gameResult = _engine.checkGameOver(board);
    if (gameResult != null) {
      final score = gameResult.winner == aiPlayer
          ? 10000 // AI获胜
          : gameResult.winner == aiPlayer.getOpponent()
              ? -10000 // AI失败
              : 0; // 平局

      // 存入置换表
      _transpositionTable[boardHash] = _TranspositionEntry(
        score,
        depth,
      );
      return score;
    }

    // 达到深度限制
    if (depth == 0) {
      final score = BoardEvaluator.evaluate(board, aiPlayer);
      _transpositionTable[boardHash] = _TranspositionEntry(
        score,
        0,
      );
      return score;
    }

    final possibleMoves = _engine.getPossibleMoves(board, board.currentPlayer);
    if (possibleMoves.isEmpty) {
      final score = BoardEvaluator.evaluate(board, aiPlayer);
      _transpositionTable[boardHash] = _TranspositionEntry(
        score,
        depth,
      );
      return score;
    }

    // 转换为移动列表
    final moveList = <_MoveOption>[];
    for (final entry in possibleMoves.entries) {
      for (final to in entry.value) {
        moveList.add(_MoveOption(from: entry.key, to: to));
      }
    }

    // 移动排序
    final sortedMoves = _sortMoves(moveList, board, board.currentPlayer);

    int finalScore;
    var searchWasCutOff = false;
    if (isMaximizing) {
      int maxScore = -9999999;
      for (final move in sortedMoves) {
        final nextBoard = _engine.simulateMove(board, move.from, move.to);
        if (nextBoard == null) continue;

        final score = _minimax(
          nextBoard,
          depth - 1,
          alpha,
          beta,
          false,
          aiPlayer,
        );
        maxScore = max(maxScore, score);
        alpha = max(alpha, score);
        if (beta <= alpha) {
          searchWasCutOff = true;
          break;
        }
      }
      finalScore = maxScore;
    } else {
      int minScore = 9999999;
      for (final move in sortedMoves) {
        final nextBoard = _engine.simulateMove(board, move.from, move.to);
        if (nextBoard == null) continue;

        final score = _minimax(
          nextBoard,
          depth - 1,
          alpha,
          beta,
          true,
          aiPlayer,
        );
        minScore = min(minScore, score);
        beta = min(beta, score);
        if (beta <= alpha) {
          searchWasCutOff = true;
          break;
        }
      }
      finalScore = minScore;
    }

    // 存入置换表
    if (!searchWasCutOff) {
      _transpositionTable[boardHash] = _TranspositionEntry(
        finalScore,
        depth,
      );
    }

    return finalScore;
  }

  void _checkDeadline() {
    final stopwatch = _searchStopwatch;
    if (stopwatch != null &&
        stopwatch.elapsedMilliseconds >= _timeLimitMilliseconds) {
      throw const _SearchTimeout();
    }
  }
}

/// 移动选项内部类
class _MoveOption {
  final Position from;
  final Position to;

  _MoveOption({required this.from, required this.to});
}

/// 带分数的移动（用于排序）
class _ScoredMove {
  final _MoveOption move;
  final int priority;

  _ScoredMove(this.move, this.priority);
}

/// Minimax AI测试
///
/// 测试内容：
/// - AI基础功能
/// - AI性能测试
/// - AI优化效果验证
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/minimax_ai.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/evaluation.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';

/// 创建一个空棋盘（所有位置都为empty）
BoardState createEmptyBoard({PieceType currentPlayer = PieceType.black}) {
  var board = BoardState.initial();
  // 清空所有棋子
  for (int y = 0; y < 4; y++) {
    for (int x = 0; x < 4; x++) {
      board = board.setPiece(Position(x, y), PieceType.empty);
    }
  }
  return board.copyWith(currentPlayer: currentPlayer);
}

void main() {
  group('BoardEvaluator', () {
    test('同一局面对双方的评分应该互为相反数', () {
      final board = BoardState.initial();

      final blackScore = BoardEvaluator.evaluate(board, PieceType.black);
      final whiteScore = BoardEvaluator.evaluate(board, PieceType.white);

      expect(blackScore, -whiteScore);
    });
  });

  group('MinimaxAI 基础功能', () {
    test('应该创建正确难度的AI', () {
      final easyAI = MinimaxAI(AIDifficulty.easy);
      expect(easyAI.difficulty, equals(AIDifficulty.easy));

      final mediumAI = MinimaxAI(AIDifficulty.medium);
      expect(mediumAI.difficulty, equals(AIDifficulty.medium));

      final hardAI = MinimaxAI(AIDifficulty.hard);
      expect(hardAI.difficulty, equals(AIDifficulty.hard));
    });

    test('name和description应该正确', () {
      final ai = MinimaxAI(AIDifficulty.medium);
      expect(ai.name, isNotEmpty);
      expect(ai.description, isNotEmpty);
      expect(ai.description, contains('Minimax'));
    });
  });

  group('MinimaxAI 移动选择', () {
    test('简单难度应该在合理候选中产生可重复的变化', () async {
      final board = BoardState.initial().switchPlayer();
      final firstChoice = await MinimaxAI(
        AIDifficulty.easy,
        random: _CandidateRandom(pickLast: false),
      ).selectMove(board);
      final lastChoice = await MinimaxAI(
        AIDifficulty.easy,
        random: _CandidateRandom(pickLast: true),
      ).selectMove(board);

      expect(firstChoice, isNotNull);
      expect(lastChoice, isNotNull);
      expect(
        (firstChoice!.from, firstChoice.to),
        isNot((lastChoice!.from, lastChoice.to)),
      );
    });

    test('初始棋盘应该能选择合法移动', () async {
      final ai = MinimaxAI(AIDifficulty.easy);
      final board = BoardState.initial().switchPlayer(); // 切换到白方

      final result = await ai.selectMove(board);

      expect(result, isNotNull);
      expect(result!.from, isNotNull);
      expect(result.to, isNotNull);
      expect(result.score, isNotNull);
      expect(result.nodesEvaluated, greaterThan(0));
    });

    test('无合法移动时应该返回null', () async {
      final ai = MinimaxAI(AIDifficulty.easy);

      // Both sides have at least two pieces, but white has no legal move.
      final board = createEmptyBoard(currentPlayer: PieceType.white)
          .setPiece(const Position(0, 0), PieceType.white)
          .setPiece(const Position(1, 0), PieceType.white)
          .setPiece(const Position(2, 0), PieceType.black)
          .setPiece(const Position(0, 1), PieceType.black)
          .setPiece(const Position(1, 1), PieceType.black);

      final result = await ai.selectMove(board);

      expect(result, isNull);
    });

    test('应该优先选择吃子移动', () async {
      final ai = MinimaxAI(AIDifficulty.medium);

      final board = createEmptyBoard(currentPlayer: PieceType.white)
          .setPiece(const Position(0, 0), PieceType.white)
          .setPiece(const Position(1, 1), PieceType.white)
          .setPiece(const Position(0, 3), PieceType.white)
          .setPiece(const Position(2, 0), PieceType.black)
          .setPiece(const Position(3, 3), PieceType.black);

      final result = await ai.selectMove(board);

      expect(result, isNotNull);
      expect(
        GameEngine().executeMove(board, result!.from, result.to).capturedPieces,
        isNotEmpty,
      );
    });
  });

  group('MinimaxAI 进度回调', () {
    test('应该正确调用进度回调', () async {
      final ai = MinimaxAI(AIDifficulty.medium);
      final board = BoardState.initial().switchPlayer();

      final progressUpdates = <double>[];
      final statusUpdates = <String>[];

      ai.setProgressCallback((progress, status) {
        progressUpdates.add(progress);
        statusUpdates.add(status);
      });

      await ai.selectMove(board);

      // 应该有多次进度更新
      expect(progressUpdates, isNotEmpty);
      expect(statusUpdates, isNotEmpty);

      // 进度应该是递增的（大致）
      expect(progressUpdates.first, lessThanOrEqualTo(progressUpdates.last));

      // 最后一次进度应该是1.0
      expect(progressUpdates.last, equals(1.0));

      // 状态应该包含搜索深度信息
      expect(statusUpdates.any((s) => s.contains('搜索深度')), isTrue);
      expect(statusUpdates.last, contains('完成'));
    });

    test('清除回调后不应该调用', () async {
      final ai = MinimaxAI(AIDifficulty.easy);
      final board = BoardState.initial().switchPlayer();

      var callCount = 0;
      ai.setProgressCallback((progress, status) {
        callCount++;
      });

      await ai.selectMove(board);
      final firstCallCount = callCount;

      expect(firstCallCount, greaterThan(0));

      // 清除回调
      ai.setProgressCallback(null);
      callCount = 0;

      await ai.selectMove(board);
      expect(callCount, equals(0));
    });

    test('简单难度选择合理候选后也报告完成进度', () async {
      final ai = MinimaxAI(
        AIDifficulty.easy,
        random: _AlwaysRandomBranch(),
      );
      final progressUpdates = <double>[];
      final statusUpdates = <String>[];
      ai.setProgressCallback((progress, status) {
        progressUpdates.add(progress);
        statusUpdates.add(status);
      });

      final result = await ai.selectMove(BoardState.initial().switchPlayer());

      expect(result?.nodesEvaluated, greaterThan(1));
      expect(progressUpdates.last, 1.0);
      expect(statusUpdates.any((status) => status.contains('搜索深度')), isTrue);
      expect(statusUpdates.last, contains('完成'));
    });
  });

  group('MinimaxAI 性能测试', () {
    test('三档难度应该使用清晰分离的搜索深度', () async {
      final reachedDepths = <AIDifficulty, int>{};
      for (final difficulty in AIDifficulty.values) {
        final ai = MinimaxAI(
          difficulty,
          random: _NeverRandomBranch(),
          elapsed: () => Duration.zero,
        );
        final result = await ai.selectMove(BoardState.initial().switchPlayer());
        reachedDepths[difficulty] = result!.completedDepth;
      }

      expect(
        reachedDepths,
        {
          AIDifficulty.easy: 2,
          AIDifficulty.medium: 4,
          AIDifficulty.hard: 8,
        },
      );
    });

    test('简单难度应该在100ms内完成', () async {
      final ai = MinimaxAI(AIDifficulty.easy);
      final board = BoardState.initial().switchPlayer();

      final stopwatch = Stopwatch()..start();
      await ai.selectMove(board);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    test('中等难度应该在500ms内完成', () async {
      final ai = MinimaxAI(AIDifficulty.medium);
      final board = BoardState.initial().switchPlayer();

      final stopwatch = Stopwatch()..start();
      await ai.selectMove(board);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });

    test('困难难度应该在2000ms内完成', () async {
      final ai = MinimaxAI(AIDifficulty.hard);
      final board = BoardState.initial().switchPlayer();

      final stopwatch = Stopwatch()..start();
      await ai.selectMove(board);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    });

    test('nodesEvaluated应该随难度增加', () async {
      final easyAI = MinimaxAI(AIDifficulty.easy);
      final mediumAI = MinimaxAI(AIDifficulty.medium);
      final hardAI = MinimaxAI(AIDifficulty.hard);
      final board = BoardState.initial().switchPlayer();

      final easyResult = await easyAI.selectMove(board);
      final mediumResult = await mediumAI.selectMove(board);
      final hardResult = await hardAI.selectMove(board);

      expect(
        easyResult!.nodesEvaluated,
        lessThan(mediumResult!.nodesEvaluated),
      );
      expect(mediumResult.nodesEvaluated, lessThan(hardResult!.nodesEvaluated));
    });

    test('nodesEvaluated应该包含递归搜索节点', () async {
      final result = await MinimaxAI(AIDifficulty.hard)
          .selectMove(BoardState.initial().switchPlayer());

      expect(result, isNotNull);
      expect(result!.nodesEvaluated, greaterThan(24));
    });
  });

  group('MinimaxAI 战术能力', () {
    test('困难难度识别七手内的强制获胜路线', () async {
      var board = createEmptyBoard(currentPlayer: PieceType.white);
      for (final position in const [Position(1, 0), Position(1, 2)]) {
        board = board.setPiece(position, PieceType.black);
      }
      for (final position in const [
        Position(1, 3),
        Position(0, 2),
        Position(2, 2),
        Position(2, 3),
      ]) {
        board = board.setPiece(position, PieceType.white);
      }
      final move =
          (await MinimaxAI(AIDifficulty.hard, elapsed: () => Duration.zero)
              .selectMove(board, noCapturePlyCount: 1))!;
      final next = GameEngine().simulateMove(board, move.from, move.to)!;
      expect(_canForceWin(next, PieceType.white, 6), isTrue);
      expect(move.score, greaterThanOrEqualTo(10000));
    });

    test('困难难度优先选择更短的强制获胜路线', () async {
      var board = createEmptyBoard(currentPlayer: PieceType.black);
      for (final position in const [
        Position(3, 0),
        Position(2, 3),
        Position(1, 3),
        Position(1, 0),
      ]) {
        board = board.setPiece(position, PieceType.black);
      }
      for (final position in const [Position(3, 3), Position(2, 1)]) {
        board = board.setPiece(position, PieceType.white);
      }
      final move = (await MinimaxAI(AIDifficulty.hard).selectMove(board))!;
      final next = GameEngine().simulateMove(board, move.from, move.to)!;
      expect(
        _canForceWin(next, PieceType.black, 2),
        isTrue,
        reason: 'Choose a win within three plies, rather than delaying to five',
      );
    });

    test('中等难度应该执行立即获胜的吃子移动', () async {
      final ai = MinimaxAI(AIDifficulty.medium);
      final board = createEmptyBoard(currentPlayer: PieceType.white)
          .setPiece(const Position(0, 0), PieceType.white)
          .setPiece(const Position(1, 1), PieceType.white)
          .setPiece(const Position(0, 3), PieceType.white)
          .setPiece(const Position(2, 0), PieceType.black)
          .setPiece(const Position(3, 3), PieceType.black);

      final move = await ai.selectMove(board);

      expect(move, isNotNull);
      final result = GameEngine().executeMove(board, move!.from, move.to);
      expect(result.gameOver, isTrue);
      expect(result.gameResult?.winner, PieceType.white);
    });

    test('中等难度应该避开让对手下一手获胜的移动', () async {
      final ai = MinimaxAI(AIDifficulty.medium);
      final board = createEmptyBoard(currentPlayer: PieceType.white)
          .setPiece(const Position(1, 0), PieceType.black)
          .setPiece(const Position(2, 0), PieceType.black)
          .setPiece(const Position(0, 1), PieceType.black)
          .setPiece(const Position(3, 1), PieceType.black)
          .setPiece(const Position(2, 2), PieceType.white)
          .setPiece(const Position(1, 3), PieceType.white);

      final move = await ai.selectMove(board);

      expect(move, isNotNull);
      final result = GameEngine().executeMove(board, move!.from, move.to);
      expect(result.success, isTrue);
      expect(_hasImmediateWinningMove(result.newBoard!), isFalse);
    });

    test('简单难度有安全走法时不应该直接送出下一手败局', () async {
      final ai = MinimaxAI(
        AIDifficulty.easy,
        random: _CandidateRandom(pickLast: true),
      );
      final board = createEmptyBoard(currentPlayer: PieceType.black)
          .setPiece(const Position(0, 1), PieceType.black)
          .setPiece(const Position(3, 1), PieceType.black)
          .setPiece(const Position(2, 1), PieceType.white)
          .setPiece(const Position(0, 2), PieceType.white)
          .setPiece(const Position(1, 2), PieceType.white)
          .setPiece(const Position(2, 2), PieceType.white);

      final move = await ai.selectMove(board);

      expect(move, isNotNull);
      final result = GameEngine().executeMove(board, move!.from, move.to);
      expect(_hasImmediateWinningMove(result.newBoard!), isFalse);
    });

    test('困难难度应该看到中等难度搜索范围之外的强制获胜路线', () async {
      final board = createEmptyBoard(currentPlayer: PieceType.black)
          .setPiece(const Position(0, 0), PieceType.black)
          .setPiece(const Position(2, 0), PieceType.black)
          .setPiece(const Position(1, 1), PieceType.black)
          .setPiece(const Position(1, 2), PieceType.black)
          .setPiece(const Position(0, 1), PieceType.white)
          .setPiece(const Position(1, 3), PieceType.white)
          .setPiece(const Position(2, 3), PieceType.white);

      final mediumMove = await MinimaxAI(AIDifficulty.medium).selectMove(board);
      final hardMove = await MinimaxAI(AIDifficulty.hard).selectMove(board);

      expect(mediumMove, isNotNull);
      expect(hardMove, isNotNull);
      final mediumBoard = GameEngine()
          .executeMove(board, mediumMove!.from, mediumMove.to)
          .newBoard!;
      final hardBoard = GameEngine()
          .executeMove(board, hardMove!.from, hardMove.to)
          .newBoard!;
      expect(_canForceWin(hardBoard, PieceType.black, 5), isTrue);
      expect(_canForceWin(mediumBoard, PieceType.black, 5), isFalse);
    });

    test('新吃子规则局面中应返回当前方的合法移动', () async {
      final ai = MinimaxAI(AIDifficulty.medium);

      // 创建一个白方即将获胜的棋盘
      // B . . .
      // B . . .
      // B . . .
      // . W W W (白方下一步可以形成4连)
      final board = createEmptyBoard(currentPlayer: PieceType.white)
          .setPiece(const Position(0, 0), PieceType.black)
          .setPiece(const Position(0, 1), PieceType.black)
          .setPiece(const Position(0, 2), PieceType.black)
          .setPiece(const Position(1, 3), PieceType.white)
          .setPiece(const Position(2, 3), PieceType.white)
          .setPiece(const Position(3, 3), PieceType.white);

      final result = await ai.selectMove(board);

      expect(result, isNotNull);
      expect(board.getPiece(result!.from), PieceType.white);
      expect(
        GameEngine().getPossibleMoves(board, PieceType.white)[result.from],
        contains(result.to),
      );
    });

    test('仅剩一子的终局不再返回移动', () async {
      final ai = MinimaxAI(AIDifficulty.medium);

      final board = createEmptyBoard(currentPlayer: PieceType.white)
          .setPiece(const Position(0, 0), PieceType.black)
          .setPiece(const Position(1, 0), PieceType.black)
          .setPiece(const Position(2, 0), PieceType.black)
          .setPiece(const Position(3, 3), PieceType.white);

      final result = await ai.selectMove(board);

      expect(result, isNull);
    });
  });

  group('MinimaxAI 优化效果', () {
    test('置换表应该减少重复计算', () async {
      final ai = MinimaxAI(AIDifficulty.medium);
      final board = BoardState.initial().switchPlayer();

      // 第一次搜索
      final result1 = await ai.selectMove(board);
      expect(result1, isNotNull);

      // 第二次搜索相同棋盘（置换表应该有缓存）
      final result2 = await ai.selectMove(board);
      final nodes2 = result2!.nodesEvaluated;

      expect(nodes2, lessThanOrEqualTo(result1!.nodesEvaluated));
      expect((result2.from, result2.to), (result1.from, result1.to));
    });

    test('迭代加深应该逐步增加深度', () async {
      final ai = MinimaxAI(AIDifficulty.medium);
      final board = BoardState.initial().switchPlayer();

      final depths = <int>[];
      ai.setProgressCallback((progress, status) {
        // 从状态中提取深度信息
        if (status.contains('搜索深度')) {
          final match = RegExp(r'(\d+)/(\d+)').firstMatch(status);
          if (match != null) {
            depths.add(int.parse(match.group(1)!));
          }
        }
      });

      await ai.selectMove(board);

      // 深度应该是递增的：1, 2, 3, ...
      expect(depths, isNotEmpty);
      for (int i = 0; i < depths.length - 1; i++) {
        expect(depths[i], lessThanOrEqualTo(depths[i + 1]));
      }
    });
  });
}

final class _AlwaysRandomBranch implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}

final class _NeverRandomBranch implements Random {
  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 1;

  @override
  int nextInt(int max) => max - 1;
}

final class _CandidateRandom implements Random {
  _CandidateRandom({required this.pickLast});

  final bool pickLast;

  @override
  bool nextBool() => pickLast;

  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => pickLast ? max - 1 : 0;
}

bool _hasImmediateWinningMove(BoardState board) {
  final engine = GameEngine();
  final possibleMoves = engine.getPossibleMoves(board, board.currentPlayer);
  for (final entry in possibleMoves.entries) {
    for (final to in entry.value) {
      final result = GameEngine().executeMove(board, entry.key, to);
      if (result.gameOver && result.gameResult?.winner == board.currentPlayer) {
        return true;
      }
    }
  }
  return false;
}

bool _canForceWin(BoardState board, PieceType player, int remainingDepth) {
  final engine = GameEngine();
  final result = engine.checkGameOver(board);
  if (result != null) {
    return result.winner == player;
  }
  if (remainingDepth == 0) {
    return false;
  }

  final childResults = <bool>[];
  final possibleMoves = engine.getPossibleMoves(board, board.currentPlayer);
  for (final entry in possibleMoves.entries) {
    for (final to in entry.value) {
      final next = engine.simulateMove(board, entry.key, to)!;
      childResults.add(_canForceWin(next, player, remainingDepth - 1));
    }
  }
  if (board.currentPlayer == player) {
    return childResults.any((canWin) => canWin);
  }
  return childResults.isNotEmpty && childResults.every((canWin) => canWin);
}

import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/evaluation.dart';
import 'package:foursquare/ai/minimax_ai.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';

BoardState boardFromRows(String rows, PieceType player) {
  var board = BoardState.initial(currentPlayer: player);
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      board = board.setPiece(Position(x, y), PieceType.empty);
    }
  }
  final lines = rows.split('/');
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      board = board.setPiece(
        Position(x, y),
        PieceType.values['.BW'.indexOf(lines[y][x])],
      );
    }
  }
  return board;
}

void main() {
  test('an interrupted iteration preserves the last completed depth', () async {
    var expire = false;
    var checksAtThirdDepth = 0;
    var inThirdDepth = false;
    final ai = MinimaxAI(
      AIDifficulty.hard,
      elapsed: () {
        if (inThirdDepth && ++checksAtThirdDepth > 4) expire = true;
        return expire ? const Duration(seconds: 2) : Duration.zero;
      },
    );
    ai.setProgressCallback((_, status) {
      if (status.startsWith('搜索深度 3/')) inThirdDepth = true;
    });
    final board = BoardState.initial();
    final result = (await ai.selectMove(board))!;
    expect(result.timedOut, isTrue);
    expect(result.completedDepth, 2);
    expect(result.score, referenceScore(board, board.currentPlayer, 2));
    expect(
      referenceScore(
        GameEngine().simulateMove(board, result.from, result.to)!,
        board.currentPlayer,
        1,
      ),
      result.score,
    );
  });

  test('no-capture limit is part of the search and cache state', () async {
    final ai = MinimaxAI(AIDifficulty.medium, elapsed: () => Duration.zero);
    final board = BoardState.initial();
    await ai.selectMove(board);
    final move = (await ai.selectMove(board, noCapturePlyCount: 49))!;
    final commit = GameEngine()
        .executeMove(board, move.from, move.to, noCapturePlyCount: 49);
    expect(commit.gameOver, isTrue);
    expect(commit.gameResult?.winner, isNull);
    expect(move.score, 0);
    expect(await ai.selectMove(board, noCapturePlyCount: 50), isNull);
  });

  test('a winning capture resets the 49-ply counter before the draw limit',
      () async {
    final board = boardFromRows('W.B./.W../..../W..B', PieceType.white);
    final move = (await MinimaxAI(AIDifficulty.medium).selectMove(
      board,
      noCapturePlyCount: 49,
    ))!;
    final result = GameEngine()
        .executeMove(board, move.from, move.to, noCapturePlyCount: 49);
    expect(result.gameResult?.winner, PieceType.white);
    expect(result.noCapturePlyCount, 0);
    expect(move.score, 10000);
  });
  test('evaluation is invariant under rotation and reflection', () {
    final board = boardFromRows('B.BB/.B../WW.W/.W..', PieceType.white);
    for (final player in [PieceType.black, PieceType.white]) {
      final expected = BoardEvaluator.evaluate(board, player);
      for (var rotation = 0; rotation < 4; rotation++) {
        for (final mirror in [false, true]) {
          var transformed = boardFromRows('..../..../..../....', player);
          for (var y = 0; y < 4; y++) {
            for (var x = 0; x < 4; x++) {
              var tx = mirror ? 3 - x : x;
              var ty = y;
              for (var turn = 0; turn < rotation; turn++) {
                final oldX = tx;
                tx = 3 - ty;
                ty = oldX;
              }
              transformed = transformed.setPiece(
                Position(tx, ty),
                board.getPiece(Position(x, y)),
              );
            }
          }
          expect(BoardEvaluator.evaluate(transformed, player), expected);
        }
      }
    }
  });
  test('cached search agrees with full-width reference search', () async {
    final board = boardFromRows('..BB/..../BW../.W.W', PieceType.white);
    final ai = MinimaxAI(AIDifficulty.hard);
    final expected = referenceScore(board, PieceType.white, 6);
    for (var attempt = 0; attempt < 2; attempt++) {
      final move = (await ai.selectMove(board))!;
      expect(move.score, expected);
      final next = GameEngine().simulateMove(board, move.from, move.to)!;
      expect(referenceScore(next, PieceType.white, 5), expected);
    }
  });
}

final _referenceCache = <String, int>{};
int referenceScore(BoardState board, PieceType player, int depth) {
  final key = '${board.grid}:${board.currentPlayer}:$player:$depth';
  final cached = _referenceCache[key];
  if (cached != null) return cached;
  final engine = GameEngine();
  final terminal = engine.checkGameOver(board);
  if (terminal != null) return terminal.winner == player ? 10000 : -10000;
  if (depth == 0) return BoardEvaluator.evaluate(board, player);
  final scores = <int>[
    for (final entry
        in engine.getPossibleMoves(board, board.currentPlayer).entries)
      for (final to in entry.value)
        referenceScore(
          engine.simulateMove(board, entry.key, to)!,
          player,
          depth - 1,
        ),
  ];
  final score =
      board.currentPlayer == player ? scores.reduce(max) : scores.reduce(min);
  _referenceCache[key] = score;
  return score;
}

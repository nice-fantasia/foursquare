import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/minimax_ai.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';

void main() {
  test(
    '困难难度在固定种子的交替执色对局中应战胜简单难度',
    () async {
      for (var game = 0; game < 4; game++) {
        final hardColor = game.isEven ? PieceType.black : PieceType.white;
        final winner = await _playGame(game, hardColor);

        expect(winner, hardColor, reason: 'game=$game, hard=$hardColor');
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<PieceType?> _playGame(int game, PieceType hardColor) async {
  final engine = GameEngine()..startNewGame();
  final black = MinimaxAI(
    hardColor == PieceType.black ? AIDifficulty.hard : AIDifficulty.easy,
    random: Random(1000 + game * 2),
  );
  final white = MinimaxAI(
    hardColor == PieceType.white ? AIDifficulty.hard : AIDifficulty.easy,
    random: Random(1001 + game * 2),
  );
  var board = BoardState.initial();
  var noCapturePlyCount = 0;

  for (var ply = 0; ply < 100; ply++) {
    final ai = board.currentPlayer == PieceType.black ? black : white;
    final move = await ai.selectMove(board);
    if (move == null) {
      return engine.checkGameOver(board)?.winner;
    }
    final result = engine.executeMove(
      board,
      move.from,
      move.to,
      noCapturePlyCount: noCapturePlyCount,
    );
    expect(result.success, isTrue, reason: 'game=$game, ply=$ply');
    board = result.newBoard!;
    noCapturePlyCount = result.noCapturePlyCount;
    if (result.gameOver) {
      return result.gameResult?.winner;
    }
  }
  fail('Self-play exceeded 100 plies: game=$game');
}

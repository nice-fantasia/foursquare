import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/minimax_ai.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';

void main() {
  for (final attacker in [PieceType.black, PieceType.white]) {
    for (var rotation = 0; rotation < 4; rotation++) {
      for (final mirrored in [false, true]) {
        test(
            'hard preserves seven-ply tactics: ${attacker.name}, rotation $rotation, mirror $mirrored',
            () async {
          var board = BoardState.initial(currentPlayer: attacker);
          for (var y = 0; y < 4; y++) {
            for (var x = 0; x < 4; x++) {
              board = board.setPiece(Position(x, y), PieceType.empty);
            }
          }
          for (final p in const [Position(1, 0), Position(1, 2)]) {
            board = board.setPiece(
              _transform(p, rotation, mirrored),
              attacker.getOpponent(),
            );
          }
          for (final p in const [
            Position(1, 3),
            Position(0, 2),
            Position(2, 2),
            Position(2, 3),
          ]) {
            board = board.setPiece(_transform(p, rotation, mirrored), attacker);
          }
          final move =
              (await MinimaxAI(AIDifficulty.hard, elapsed: () => Duration.zero)
                  .selectMove(board, noCapturePlyCount: 1))!;
          final next = GameEngine().simulateMove(board, move.from, move.to)!;
          expect(_forceWin(next, attacker, 6, {}), isTrue);
          expect(move.score, greaterThanOrEqualTo(10000));
          expect(move.timedOut, isFalse);
        });
      }
    }
  }
}

Position _transform(Position p, int turns, bool mirrored) {
  var x = mirrored ? 3 - p.x : p.x;
  var y = p.y;
  for (var turn = 0; turn < turns; turn++) {
    final oldX = x;
    x = 3 - y;
    y = oldX;
  }
  return Position(x, y);
}

// Full-width win/loss oracle. With initial counter 1 and at most seven plies,
// the 50-ply draw boundary cannot be reached in this fixture.
bool _forceWin(
  BoardState board,
  PieceType player,
  int remaining,
  Map<String, bool> cache,
) {
  final key = '${board.grid}:${board.currentPlayer}:$player:$remaining';
  final cached = cache[key];
  if (cached != null) return cached;
  final engine = GameEngine();
  final terminal = engine.checkGameOver(board);
  if (terminal != null) return terminal.winner == player;
  if (remaining == 0) return false;
  for (final entry
      in engine.getPossibleMoves(board, board.currentPlayer).entries) {
    for (final to in entry.value) {
      final won = _forceWin(
        engine.simulateMove(board, entry.key, to)!,
        player,
        remaining - 1,
        cache,
      );
      if (board.currentPlayer == player && won) return cache[key] = true;
      if (board.currentPlayer != player && !won) return cache[key] = false;
    }
  }
  return cache[key] = board.currentPlayer != player;
}

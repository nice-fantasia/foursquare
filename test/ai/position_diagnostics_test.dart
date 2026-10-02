import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import '../../scripts/ai_position_diagnostics.dart';

void main() {
  test('two legal four-ply cycles are diagnosed without ending the game', () {
    final diagnostics = PositionRepetitionDiagnostics();
    final engine = GameEngine()..startNewGame();
    var board = BoardState.initial();
    var count = 0;
    diagnostics.observe(board);
    for (var cycle = 0; cycle < 2; cycle++) {
      for (final move in const [
        (Position(0, 0), Position(0, 1)),
        (Position(0, 3), Position(0, 2)),
        (Position(0, 1), Position(0, 0)),
        (Position(0, 2), Position(0, 3)),
      ]) {
        final result = engine.executeMove(
          board,
          move.$1,
          move.$2,
          noCapturePlyCount: count,
        );
        expect(result.success, isTrue);
        expect(result.gameOver, isFalse);
        board = result.newBoard!;
        count = result.noCapturePlyCount;
        diagnostics.observe(board);
      }
    }
    expect(board.grid, BoardState.initial().grid);
    expect(board.currentPlayer, PieceType.black);
    expect(
      board.blackPieces,
      unorderedEquals(BoardState.initial().blackPieces),
    );
    expect(
      board.whitePieces,
      unorderedEquals(BoardState.initial().whitePieces),
    );
    expect(count, 8);
    expect(diagnostics.revisits, 5);
    expect(diagnostics.maxVisits, 3);
    expect(diagnostics.shortestCycle, 4);
  });

  test('identical grids with different players are different positions', () {
    final diagnostics = PositionRepetitionDiagnostics();
    diagnostics.observe(BoardState.initial());
    diagnostics.observe(BoardState.initial(currentPlayer: PieceType.white));
    expect(diagnostics.revisits, 0);
    expect(diagnostics.maxVisits, 1);
    expect(diagnostics.shortestCycle, isNull);
  });
}

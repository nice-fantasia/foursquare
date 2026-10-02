import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/engine/move_validator.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';

void main() {
  test('seeded legal games preserve board and engine invariants', () {
    for (var game = 0; game < 24; game++) {
      final random = Random(20261002 + game);
      final engine = GameEngine()..startNewGame();
      final validator = MoveValidator();
      var board = BoardState.initial(
        currentPlayer: game.isEven ? PieceType.black : PieceType.white,
      );
      var noCapturePlyCount = 0;

      _expectConsistentBoard(board, reason: 'game=$game initial');
      for (var ply = 0; ply < 120; ply++) {
        final possibleMoves = engine.getPossibleMoves(
          board,
          board.currentPlayer,
        );
        if (possibleMoves.isEmpty) {
          expect(
            engine.checkGameOver(
              board,
              noCapturePlyCount: noCapturePlyCount,
            ),
            isNotNull,
            reason: 'game=$game ply=$ply',
          );
          break;
        }

        for (final entry in possibleMoves.entries) {
          for (final destination in entry.value) {
            expect(
              validator.isValidMove(board, entry.key, destination),
              isTrue,
              reason: 'game=$game ply=$ply ${entry.key}->$destination',
            );
          }
        }

        final sources = possibleMoves.keys.toList(growable: false);
        final from = sources[random.nextInt(sources.length)];
        final destinations = possibleMoves[from]!;
        final to = destinations[random.nextInt(destinations.length)];
        final simulated = engine.simulateMove(board, from, to);
        final previousNoCapturePlyCount = noCapturePlyCount;
        final result = engine.executeMove(
          board,
          from,
          to,
          noCapturePlyCount: noCapturePlyCount,
        );

        expect(result.success, isTrue, reason: 'game=$game ply=$ply');
        expect(result.newBoard, isNotNull, reason: 'game=$game ply=$ply');
        expect(simulated, isNotNull, reason: 'game=$game ply=$ply');
        final next = result.newBoard!;
        _expectConsistentBoard(next, reason: 'game=$game ply=$ply');
        _expectSamePosition(
          simulated!,
          next,
          reason: 'game=$game ply=$ply',
        );

        final expectedNoCapturePlyCount =
            result.capturedPieces.isEmpty ? previousNoCapturePlyCount + 1 : 0;
        expect(
          result.noCapturePlyCount,
          expectedNoCapturePlyCount,
          reason: 'game=$game ply=$ply',
        );
        expect(
          result.move!.capturedPieces,
          result.capturedPieces,
          reason: 'game=$game ply=$ply',
        );

        board = next;
        noCapturePlyCount = result.noCapturePlyCount;
        if (result.gameOver) {
          expect(
            engine.checkGameOver(
              board,
              noCapturePlyCount: noCapturePlyCount,
            ),
            isNotNull,
            reason: 'game=$game ply=$ply',
          );
          break;
        }
        expect(
          simulated.currentPlayer,
          next.currentPlayer,
          reason: 'game=$game ply=$ply',
        );
      }
    }
  });

  test('rejected moves preserve the board and move history', () {
    final engine = GameEngine()..startNewGame();
    final board = BoardState.initial();

    final result = engine.executeMove(
      board,
      const Position(0, 0),
      const Position(1, 0),
    );

    expect(result.success, isFalse);
    expect(result.newBoard, isNull);
    expect(engine.moveHistory, isEmpty);
    expect(board, BoardState.initial());
  });
}

void _expectConsistentBoard(BoardState board, {required String reason}) {
  final blackFromGrid = <Position>{};
  final whiteFromGrid = <Position>{};
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final position = Position(x, y);
      switch (board.getPiece(position)) {
        case PieceType.black:
          blackFromGrid.add(position);
          break;
        case PieceType.white:
          whiteFromGrid.add(position);
          break;
        case PieceType.empty:
          break;
      }
    }
  }

  expect(board.blackPieces.toSet(), blackFromGrid, reason: reason);
  expect(board.whitePieces.toSet(), whiteFromGrid, reason: reason);
  expect(board.blackPieces.length, blackFromGrid.length, reason: reason);
  expect(board.whitePieces.length, whiteFromGrid.length, reason: reason);
  expect(
    board.getPieceCount(PieceType.empty) +
        board.blackPieces.length +
        board.whitePieces.length,
    16,
    reason: reason,
  );
}

void _expectSamePosition(
  BoardState simulated,
  BoardState executed, {
  required String reason,
}) {
  expect(simulated.grid, executed.grid, reason: reason);
  expect(
    simulated.blackPieces.toSet(),
    executed.blackPieces.toSet(),
    reason: reason,
  );
  expect(
    simulated.whitePieces.toSet(),
    executed.whitePieces.toSet(),
    reason: reason,
  );
}

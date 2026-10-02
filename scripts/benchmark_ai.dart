import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/minimax_ai.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';

/// Reproducible strength sample, not a statistical release gate.
/// Run: dart run scripts/benchmark_ai.dart [games-per-pair, even, 2..20]
Future<void> main(List<String> arguments) async {
  final games = arguments.isEmpty ? 4 : int.parse(arguments.single);
  if (games < 2 || games > 20 || games.isOdd) {
    throw ArgumentError('games-per-pair must be even and between 2 and 20');
  }
  for (final pair in [
    (AIDifficulty.medium, AIDifficulty.easy),
    (AIDifficulty.hard, AIDifficulty.easy),
    (AIDifficulty.hard, AIDifficulty.medium),
  ]) {
    for (var game = 0; game < games; game++) {
      final stronger = game.isEven ? PieceType.black : PieceType.white;
      final seed = 20260921 + game ~/ 2;
      final opening = Random(seed);
      final engine = GameEngine()..startNewGame();
      var board = BoardState.initial();
      var count = 0;
      final openingPlies = (game ~/ 2 % 3) * 2;
      for (var ply = 0; ply < openingPlies; ply++) {
        final moves = <({Position from, Position to})>[
          for (final e
              in engine.getPossibleMoves(board, board.currentPlayer).entries)
            for (final to in e.value) (from: e.key, to: to),
        ];
        final move = moves[opening.nextInt(moves.length)];
        final result = engine.executeMove(
          board,
          move.from,
          move.to,
          noCapturePlyCount: count,
        );
        if (result.gameOver) throw StateError('Unexpected terminal opening');
        board = result.newBoard!;
        count = result.noCapturePlyCount;
      }
      var timedOutSearches = 0;
      var maxSearchMicros = 0;
      for (var ply = 0; ply < 400; ply++) {
        final difficulty = board.currentPlayer == stronger ? pair.$1 : pair.$2;
        // Match the production caller: each turn gets a fresh AI instance.
        final ai = MinimaxAI(difficulty, random: Random(seed + ply));
        final move = await ai.selectMove(board, noCapturePlyCount: count);
        if (move == null) throw StateError('No move in non-terminal game');
        if (move.timedOut) timedOutSearches++;
        maxSearchMicros =
            max(maxSearchMicros, move.thinkingTime.inMicroseconds);
        final result = engine.executeMove(
          board,
          move.from,
          move.to,
          noCapturePlyCount: count,
        );
        if (!result.success) throw StateError('AI returned an illegal move');
        board = result.newBoard!;
        count = result.noCapturePlyCount;
        if (result.gameOver) {
          stdout.writeln(
            jsonEncode({
              'stronger': pair.$1.name,
              'opponent': pair.$2.name,
              'strongerColor': stronger.name,
              'seed': seed,
              'openingPlies': openingPlies,
              'plies': ply + 1,
              'result': result.gameResult!.winner == null
                  ? 'draw'
                  : result.gameResult!.winner == stronger
                      ? 'win'
                      : 'loss',
              'timedOutSearches': timedOutSearches,
              'maxSearchMicros': maxSearchMicros,
            }),
          );
          break;
        }
        if (ply == 399) throw StateError('Game exceeded bound');
      }
    }
  }
}

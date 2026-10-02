import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/board_state.dart';
import 'ai_player.dart';
import 'minimax_ai.dart';

/// Runs each production search off the UI isolate on native platforms.
/// Flutter compute falls back to the event loop on web.
class BackgroundAI extends AIPlayer {
  BackgroundAI(super.difficulty, {Random? random})
      : _random = random ?? Random();

  final Random _random;

  @override
  String get name => 'Background Minimax AI';

  @override
  String get description => 'Bounded Minimax search on a background isolate';

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) =>
      compute(
        _search,
        (
          board: board,
          difficulty: difficulty,
          noCapturePlyCount: noCapturePlyCount,
          seed: _random.nextInt(1 << 31)
        ),
        debugLabel: 'foursquare-ai-${difficulty.name}',
      );
}

typedef _SearchRequest = ({
  BoardState board,
  AIDifficulty difficulty,
  int noCapturePlyCount,
  int seed
});

Future<AIMoveResult?> _search(_SearchRequest request) =>
    MinimaxAI(request.difficulty, random: Random(request.seed)).selectMove(
      request.board,
      noCapturePlyCount: request.noCapturePlyCount,
    );

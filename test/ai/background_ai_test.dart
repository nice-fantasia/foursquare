import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/background_ai.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';

void main() {
  test('native AI search allows caller event loop to process input', () async {
    final inputEvent = Completer<String>();
    Timer.run(() => inputEvent.complete('input'));
    final board = BoardState.initial();
    final future = BackgroundAI(AIDifficulty.hard).selectMove(board);
    final firstCompletion = await Future.any([
      future.then((_) => 'search'),
      inputEvent.future,
    ]);
    expect(firstCompletion, 'input');
    final move = await future;
    expect(move, isNotNull);
    expect(
      GameEngine().executeMove(board, move!.from, move.to).success,
      isTrue,
    );
  });

  test('background search receives no-capture count and returns metadata',
      () async {
    final result = await BackgroundAI(AIDifficulty.easy).selectMove(
      BoardState.initial(),
      noCapturePlyCount: 49,
    );
    expect(result?.score, 0);
    expect(result?.completedDepth, greaterThan(0));
    expect(
      await BackgroundAI(AIDifficulty.easy).selectMove(
        BoardState.initial(),
        noCapturePlyCount: 50,
      ),
      isNull,
    );
  });
}

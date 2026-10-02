import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/voice_game_intent.dart';
import 'package:foursquare/meditation/meditation_intent_handler.dart';
import 'package:foursquare/meditation/meditation_session.dart';
import 'package:foursquare/meditation/meditation_session_controller.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_result.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/services/turn_clock.dart';

void main() {
  late DateTime now;
  late MeditationSessionController controller;
  late MeditationIntentHandler handler;

  setUp(() {
    now = DateTime.utc(2026, 8, 1, 12);
    controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    controller.completeOpening();
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: _QueueAI([
        const AIMoveResult(
          from: Position(0, 3),
          to: Position(0, 2),
          score: 1,
        ),
      ]),
    );
  });

  test('opening prompt describes authoritative colors and first player', () {
    final unopened = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    final unopenedHandler = MeditationIntentHandler(
      controller: unopened,
      aiPlayer: _QueueAI(const []),
    );

    final prompt = unopenedHandler.openingPrompt();

    expect(prompt.text, contains('您执黑方'));
    expect(prompt.text, contains('黑方先手'));
    expect(prompt.text, isNot(contains('轮到您行棋')));
    expect(unopened.session.phase, MeditationSessionPhase.opening);
    expect(prompt.toString(), isNot(contains(prompt.text)));
  });

  test('start advances an AI first game before asking the human', () async {
    controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.white,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: _QueueAI([
        const AIMoveResult(
          from: Position(0, 0),
          to: Position(0, 1),
          score: 1,
        ),
      ]),
    );

    handler.openingPrompt();
    final response = await handler.start();

    expect(controller.session.moveHistory, hasLength(1));
    expect(controller.session.phase, MeditationSessionPhase.humanTurn);
    expect(response.prompt.text, contains('对手从横一竖一移动到横一竖二'));
    expect(response.prompt.text, contains('轮到您行棋'));
    expect(
      controller.session.turnClock!.remainingAt(now),
      const Duration(seconds: 60),
    );
  });

  test('position intent selects a piece and announces legal targets', () async {
    final response = await handler.handle(
      const VoicePositionIntent(Position(0, 0)),
    );

    expect(response.action!.outcome, MeditationActionOutcome.selected);
    expect(response.prompt.text, contains('已选中横一竖一'));
    expect(response.prompt.text, contains('横一竖二'));
    expect(controller.session.selectedPosition, const Position(0, 0));
  });

  test('human and AI moves complete one authoritative spoken turn', () async {
    await handler.handle(const VoicePositionIntent(Position(0, 0)));

    final response = await handler.handle(
      const VoicePositionIntent(Position(0, 1)),
    );

    expect(controller.session.moveHistory, hasLength(2));
    expect(controller.session.phase, MeditationSessionPhase.humanTurn);
    expect(response.prompt.text, contains('您从横一竖一移动到横一竖二'));
    expect(response.prompt.text, contains('对手从横一竖四移动到横一竖三'));
    expect(response.prompt.text, contains('轮到您行棋'));
  });

  test('repeat returns the previous prompt without changing the session',
      () async {
    final first = await handler.handle(
      const VoicePositionIntent(Position(0, 0)),
    );
    final revision = controller.session.revision;

    final repeated = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.repeat),
    );

    expect(repeated.prompt, first.prompt);
    expect(controller.session.revision, revision);
  });

  test('pause and resume are typed lifecycle actions', () async {
    final paused = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.pause),
    );
    expect(paused.action!.outcome, MeditationActionOutcome.paused);
    expect(paused.prompt.text, contains('已暂停'));

    now = now.add(const Duration(minutes: 3));
    final resumed = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.resume),
    );
    expect(resumed.action!.outcome, MeditationActionOutcome.resumed);
    expect(resumed.prompt.text, contains('已继续'));
  });

  test('exit requests confirmation and does not silently abandon', () async {
    final response = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.exit),
    );

    expect(response.exitConfirmationRequested, isTrue);
    expect(response.prompt.text, contains('确认退出'));
    expect(controller.session.gameResult, isNull);
    expect(controller.session.revision, 1);
  });

  test('exit confirmation abandons while cancellation continues', () async {
    await handler.handle(const VoiceActionIntent(VoiceGameAction.exit));
    final cancelled = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.cancelExit),
    );
    expect(cancelled.prompt.text, contains('继续对局'));
    expect(controller.session.gameResult, isNull);

    await handler.handle(const VoiceActionIntent(VoiceGameAction.exit));
    final confirmed = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.confirmExit),
    );
    expect(confirmed.action!.outcome, MeditationActionOutcome.completed);
    expect(controller.session.gameResult!.status, GameStatus.abandoned);
  });

  test('AI failure can be retried without replaying the human move', () async {
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: _QueueAI([
        null,
        const AIMoveResult(
          from: Position(0, 3),
          to: Position(0, 2),
          score: 1,
        ),
      ]),
    );
    final first = await handler.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(0, 1),
      ),
    );
    expect(first.prompt.text, contains('稍后说重试'));
    expect(controller.session.moveHistory, hasLength(1));

    final retried = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.retry),
    );

    expect(controller.session.moveHistory, hasLength(2));
    expect(retried.prompt.text, contains('对手从横一竖四移动到横一竖三'));
    expect(retried.prompt.text, contains('轮到您行棋'));
  });

  test('opening settles an expired restored turn before narration', () async {
    final restored = MeditationSession(
      matchId: 'expired',
      startedAt: now.subtract(const Duration(minutes: 2)),
      boardState: BoardState.initial(),
      firstPlayer: PieceType.black,
      humanPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.easy,
      turnClock: TurnClock.started(
        now.subtract(const Duration(seconds: 60)),
      ),
    );
    controller = MeditationSessionController.restore(restored, now: () => now);
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: _QueueAI(const []),
    );

    final response = await handler.start();

    expect(controller.session.gameResult!.status, GameStatus.timeout);
    expect(response.prompt.text, contains('超时'));
    expect(response.prompt.text, isNot(contains('轮到您行棋')));
  });

  test('start reports restored paused and completed phases accurately',
      () async {
    controller.pause();
    var restoredHandler = MeditationIntentHandler(
      controller: MeditationSessionController.restore(
        controller.session,
        now: () => now,
      ),
      aiPlayer: _QueueAI(const []),
    );

    final paused = await restoredHandler.start();
    expect(paused.prompt.text, contains('暂停'));
    expect(paused.prompt.text, isNot(contains('轮到您行棋')));

    controller.resume();
    controller.abandon();
    restoredHandler = MeditationIntentHandler(
      controller: MeditationSessionController.restore(
        controller.session,
        now: () => now,
      ),
      aiPlayer: _QueueAI(const []),
    );
    final completed = await restoredHandler.start();
    expect(completed.prompt.text, contains('弃局结束'));
    expect(completed.prompt.text, isNot(contains('轮到您行棋')));
  });

  test('available move query distinguishes paused and completed sessions',
      () async {
    await handler.handle(const VoiceActionIntent(VoiceGameAction.pause));
    final paused = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.availableMoves),
    );
    expect(paused.prompt.text, contains('已暂停'));

    await handler.handle(const VoiceActionIntent(VoiceGameAction.resume));
    await handler.handle(const VoiceActionIntent(VoiceGameAction.exit));
    await handler.handle(
      const VoiceActionIntent(VoiceGameAction.confirmExit),
    );
    final completed = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.availableMoves),
    );
    expect(completed.prompt.text, contains('已经结束'));
  });

  test('board queries read authority state without changing revision',
      () async {
    final revision = controller.session.revision;

    final myPieces = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.myPieces),
    );
    final opponentPieces = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.opponentPieces),
    );
    final pieceCount = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.pieceCount),
    );
    final availableMoves = await handler.handle(
      const VoiceActionIntent(VoiceGameAction.availableMoves),
    );

    expect(myPieces.prompt.text, contains('横一竖一'));
    expect(opponentPieces.prompt.text, contains('横一竖四'));
    expect(pieceCount.prompt.text, contains('您还有4枚'));
    expect(pieceCount.prompt.text, contains('对手还有4枚'));
    expect(availableMoves.prompt.text, contains('横一竖一可以移动到横一竖二'));
    expect(controller.session.revision, revision);
  });

  test('illegal move feedback is based on a rejected authority action',
      () async {
    final board = controller.session.boardState;

    final response = await handler.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(3, 3),
      ),
    );

    expect(response.action!.outcome, MeditationActionOutcome.rejected);
    expect(response.prompt.text, contains('不能这样移动'));
    expect(controller.session.boardState, board);
    expect(controller.session.moveHistory, isEmpty);
  });

  test('human AI turn is persisted before AI and again after AI commits',
      () async {
    final committedPhases = <MeditationSessionPhase>[];
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: _QueueAI([
        const AIMoveResult(
          from: Position(0, 3),
          to: Position(0, 2),
          score: 1,
        ),
      ]),
      onSessionChanged: (session) async {
        committedPhases.add(session.phase);
      },
    );

    await handler.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(0, 1),
      ),
    );

    expect(
      committedPhases,
      [MeditationSessionPhase.aiTurn, MeditationSessionPhase.humanTurn],
    );
  });

  test('restored AI turn is persisted and advanced exactly once', () async {
    controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );
    final ai = _CountingAI(
      const AIMoveResult(
        from: Position(0, 3),
        to: Position(0, 2),
        score: 1,
      ),
    );
    final committedPhases = <MeditationSessionPhase>[];
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: ai,
      onSessionChanged: (session) async {
        committedPhases.add(session.phase);
      },
    );

    await handler.start();
    await handler.start();

    expect(ai.calls, 1);
    expect(controller.session.moveHistory, hasLength(2));
    expect(
      committedPhases,
      [MeditationSessionPhase.aiTurn, MeditationSessionPhase.humanTurn],
    );
  });

  test('AI does not start before the human move durability barrier', () async {
    final saveGate = Completer<void>();
    final ai = _CountingAI(
      const AIMoveResult(
        from: Position(0, 3),
        to: Position(0, 2),
        score: 1,
      ),
    );
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: ai,
      onSessionChanged: (session) {
        return session.phase == MeditationSessionPhase.aiTurn
            ? saveGate.future
            : Future<void>.value();
      },
    );

    final response = handler.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(0, 1),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(ai.calls, 0);
    expect(controller.session.phase, MeditationSessionPhase.aiTurn);

    saveGate.complete();
    await response;
    expect(ai.calls, 1);
    expect(controller.session.phase, MeditationSessionPhase.humanTurn);
  });

  test('concurrent restored starts share one AI flight', () async {
    controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );
    final ai = _DelayedCountingAI();
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: ai,
      onSessionChanged: (_) async {},
    );

    final first = handler.start();
    final second = handler.start();
    await Future<void>.delayed(Duration.zero);
    expect(ai.calls, 1);

    ai.complete(
      const AIMoveResult(
        from: Position(0, 3),
        to: Position(0, 2),
        score: 1,
      ),
    );
    await Future.wait([first, second]);

    expect(ai.calls, 1);
    expect(controller.session.moveHistory, hasLength(2));
  });

  test('start retries a failed post-AI durability commit', () async {
    var failHumanTurnSave = true;
    final committedRevisions = <int>[];
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: _QueueAI([
        const AIMoveResult(
          from: Position(0, 3),
          to: Position(0, 2),
          score: 1,
        ),
      ]),
      onSessionChanged: (session) async {
        if (session.phase == MeditationSessionPhase.humanTurn &&
            session.moveHistory.length == 2 &&
            failHumanTurnSave) {
          failHumanTurnSave = false;
          throw StateError('temporary save failure');
        }
        committedRevisions.add(session.revision);
      },
    );

    await expectLater(
      handler.handle(
        const VoiceMoveIntent(
          from: Position(0, 0),
          to: Position(0, 1),
        ),
      ),
      throwsStateError,
    );
    final failedRevision = controller.session.revision;

    await handler.start();

    expect(committedRevisions, contains(failedRevision));
    expect(controller.session.moveHistory, hasLength(2));
  });

  test('pause and resume during AI thinking starts a new revision flight',
      () async {
    controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );
    final ai = _DelayedCountingAI();
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: ai,
      onSessionChanged: (_) async {},
    );

    final initialAiTurn = handler.start();
    await Future<void>.delayed(Duration.zero);
    expect(ai.calls, 1);

    await handler.handle(
      const VoiceActionIntent(VoiceGameAction.pause),
    );
    final resumedAiTurn = handler.handle(
      const VoiceActionIntent(VoiceGameAction.resume),
    );
    await Future<void>.delayed(Duration.zero);
    expect(ai.calls, 2);

    ai.complete(
      const AIMoveResult(
        from: Position(0, 3),
        to: Position(0, 2),
        score: 1,
      ),
    );
    await Future.wait([initialAiTurn, resumedAiTurn]);

    expect(controller.session.phase, MeditationSessionPhase.humanTurn);
    expect(controller.session.moveHistory, hasLength(2));
  });

  test('different authority revisions persist in commit order', () async {
    final firstSaveGate = Completer<void>();
    final startedRevisions = <int>[];
    final completedRevisions = <int>[];
    handler = MeditationIntentHandler(
      controller: controller,
      aiPlayer: _QueueAI(const []),
      onSessionChanged: (session) async {
        startedRevisions.add(session.revision);
        if (startedRevisions.length == 1) {
          await firstSaveGate.future;
        }
        completedRevisions.add(session.revision);
      },
    );

    final move = handler.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(0, 1),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final pause = handler.handle(
      const VoiceActionIntent(VoiceGameAction.pause),
    );
    await Future<void>.delayed(Duration.zero);

    expect(startedRevisions, [2]);
    firstSaveGate.complete();
    await Future.wait([move, pause]);

    expect(startedRevisions, [2, 3]);
    expect(completedRevisions, [2, 3]);
    expect(controller.session.phase, MeditationSessionPhase.paused);
  });
}

class _QueueAI extends AIPlayer {
  final List<AIMoveResult?> _moves;

  _QueueAI(this._moves) : super(AIDifficulty.easy);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) async {
    return _moves.isEmpty ? null : _moves.removeAt(0);
  }

  @override
  String get name => 'Queue AI';

  @override
  String get description => 'Scripted test AI';
}

final class _CountingAI extends AIPlayer {
  final AIMoveResult result;
  int calls = 0;

  _CountingAI(this.result) : super(AIDifficulty.easy);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) async {
    calls += 1;
    return result;
  }

  @override
  String get name => 'Counting AI';

  @override
  String get description => 'Counts restored AI scheduling';
}

final class _DelayedCountingAI extends AIPlayer {
  final Completer<AIMoveResult?> _result = Completer<AIMoveResult?>();
  int calls = 0;

  _DelayedCountingAI() : super(AIDifficulty.easy);

  void complete(AIMoveResult? result) => _result.complete(result);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) {
    calls += 1;
    return _result.future;
  }

  @override
  String get name => 'Delayed counting AI';

  @override
  String get description => 'Controls one shared AI flight';
}

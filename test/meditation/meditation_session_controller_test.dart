import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
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

  setUp(() {
    now = DateTime.utc(2026, 8, 1, 12);
    controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.medium,
      now: () => now,
    );
    controller.completeOpening();
  });

  test('new game waits for opening completion before starting the clock', () {
    final unopened = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.medium,
      now: () => now,
    );
    final session = unopened.session;

    expect(session.matchId, 'meditation-1785585600000000');
    expect(session.startedAt, now);
    expect(session.firstPlayer, PieceType.black);
    expect(session.humanPlayer, PieceType.black);
    expect(session.aiDifficulty, AIDifficulty.medium);
    expect(session.boardState, BoardState.initial());
    expect(session.moveHistory, isEmpty);
    expect(session.noCapturePlyCount, 0);
    expect(session.turnClock, isNull);
    expect(session.phase, MeditationSessionPhase.opening);

    now = now.add(const Duration(minutes: 5));
    expect(
      unopened
          .submitHumanMove(
            const Position(0, 0),
            const Position(0, 1),
          )
          .rejection,
      MeditationRejection.openingNotCompleted,
    );

    final started = unopened.completeOpening();
    expect(started.outcome, MeditationActionOutcome.started);
    expect(unopened.session.phase, MeditationSessionPhase.humanTurn);
    expect(
      unopened.session.turnClock!.remainingAt(now),
      const Duration(seconds: 60),
    );
  });

  test('single-position input selects, reselects and deselects', () {
    final selected = controller.activateHumanPosition(const Position(0, 0));
    expect(selected.outcome, MeditationActionOutcome.selected);
    expect(controller.session.selectedPosition, const Position(0, 0));
    expect(controller.session.validMoves, contains(const Position(0, 1)));

    final reselected = controller.activateHumanPosition(const Position(1, 0));
    expect(reselected.outcome, MeditationActionOutcome.selected);
    expect(controller.session.selectedPosition, const Position(1, 0));

    final deselected = controller.activateHumanPosition(const Position(1, 0));
    expect(deselected.outcome, MeditationActionOutcome.deselected);
    expect(controller.session.selectedPosition, isNull);
    expect(controller.session.validMoves, isEmpty);
  });

  test('human move commits through the game engine and preserves history', () {
    final action = controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );

    expect(action.outcome, MeditationActionOutcome.moved);
    expect(controller.session.boardState.currentPlayer, PieceType.white);
    expect(controller.session.moveHistory, hasLength(1));
    expect(controller.session.moveHistory.single.player, PieceType.black);
    expect(controller.session.noCapturePlyCount, 1);
    expect(controller.session.selectedPosition, isNull);
    expect(controller.session.phase, MeditationSessionPhase.aiTurn);
    expect(
      controller.session.turnClock!.remainingAt(now),
      const Duration(seconds: 60),
    );
  });

  test('the wrong actor cannot move the authoritative session', () {
    final aiDuringHumanTurn = controller.submitAiMove(
      const Position(0, 3),
      const Position(0, 2),
    );
    expect(aiDuringHumanTurn.rejection, MeditationRejection.notAiTurn);

    controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );
    final humanDuringAiTurn = controller.submitHumanMove(
      const Position(1, 0),
      const Position(1, 1),
    );
    expect(humanDuringAiTurn.rejection, MeditationRejection.notHumanTurn);
    expect(controller.session.moveHistory, hasLength(1));
  });

  test('AI move uses the same engine and returns the turn to the human', () {
    controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );

    final action = controller.submitAiMove(
      const Position(0, 3),
      const Position(0, 2),
    );

    expect(action.outcome, MeditationActionOutcome.moved);
    expect(controller.session.moveHistory, hasLength(2));
    expect(controller.session.moveHistory.last.player, PieceType.white);
    expect(controller.session.phase, MeditationSessionPhase.humanTurn);
  });

  test('pause and resume preserve the exact remaining turn time', () {
    now = now.add(const Duration(seconds: 17));
    final paused = controller.pause();

    expect(paused.outcome, MeditationActionOutcome.paused);
    expect(controller.session.phase, MeditationSessionPhase.paused);
    expect(
      controller.session.turnClock!.remainingAt(now),
      const Duration(seconds: 43),
    );

    now = now.add(const Duration(minutes: 5));
    final resumed = controller.resume();
    expect(resumed.outcome, MeditationActionOutcome.resumed);
    expect(controller.session.phase, MeditationSessionPhase.humanTurn);
    expect(
      controller.session.turnClock!.remainingAt(now),
      const Duration(seconds: 43),
    );
  });

  test('deadline wins over a queued move and leaves the board unchanged', () {
    final initialBoard = controller.session.boardState;
    now = now.add(const Duration(seconds: 60));

    final action = controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );

    expect(action.outcome, MeditationActionOutcome.completed);
    expect(controller.session.phase, MeditationSessionPhase.completed);
    expect(controller.session.gameResult!.status, GameStatus.timeout);
    expect(controller.session.gameResult!.winner, PieceType.white);
    expect(controller.session.boardState, initialBoard);
    expect(controller.session.moveHistory, isEmpty);
  });

  test('seeded no-capture count reaches the same 50-ply draw rule', () {
    final restored = MeditationSession(
      matchId: 'restored-meditation',
      startedAt: now.subtract(const Duration(minutes: 2)),
      boardState: BoardState.initial(),
      firstPlayer: PieceType.black,
      humanPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.easy,
      noCapturePlyCount: 49,
      turnClock: TurnClock.started(now),
    );
    controller = MeditationSessionController.fromSnapshotForTesting(
      restored,
      now: () => now,
    );

    final action = controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );

    expect(action.outcome, MeditationActionOutcome.completed);
    expect(controller.session.gameResult!.status, GameStatus.draw);
    expect(
      controller.session.gameResult!.endReason,
      GameEndReason.noCaptureLimit,
    );
    expect(controller.session.noCapturePlyCount, 50);
    expect(controller.session.moveHistory, hasLength(1));
  });

  test('double capture and no-capture reset stay authoritative', () {
    final doubleCaptureBoard = BoardState.initial()
        .setPiece(const Position(0, 1), PieceType.black)
        .setPiece(const Position(1, 1), PieceType.empty)
        .setPiece(const Position(2, 1), PieceType.black)
        .setPiece(const Position(3, 1), PieceType.white)
        .setPiece(const Position(1, 2), PieceType.white)
        .setPiece(const Position(1, 3), PieceType.empty);
    controller = MeditationSessionController.fromSnapshotForTesting(
      MeditationSession(
        matchId: 'double-capture',
        startedAt: now,
        boardState: doubleCaptureBoard,
        firstPlayer: PieceType.black,
        humanPlayer: PieceType.black,
        aiDifficulty: AIDifficulty.medium,
        noCapturePlyCount: 12,
        turnClock: TurnClock.started(now),
      ),
      now: () => now,
    );

    final action = controller.submitHumanMove(
      const Position(0, 1),
      const Position(1, 1),
    );

    expect(action.outcome, MeditationActionOutcome.moved);
    expect(
      action.committedMove!.capturedPieces,
      const [Position(3, 1), Position(1, 2)],
    );
    expect(controller.session.noCapturePlyCount, 0);
  });

  test('abandoning produces a typed terminal result', () {
    now = now.add(const Duration(seconds: 9));

    final action = controller.abandon();

    expect(action.outcome, MeditationActionOutcome.completed);
    expect(controller.session.gameResult!.status, GameStatus.abandoned);
    expect(controller.session.gameResult!.endReason, GameEndReason.abandoned);
    expect(controller.session.gameResult!.winner, PieceType.white);
    expect(controller.session.gameResult!.duration, const Duration(seconds: 9));
  });

  test('deadline wins over abandonment', () {
    now = now.add(const Duration(seconds: 60));

    final action = controller.abandon();

    expect(action.outcome, MeditationActionOutcome.completed);
    expect(controller.session.gameResult!.status, GameStatus.timeout);
    expect(controller.session.gameResult!.winner, PieceType.white);
  });

  test('restore rejects history that does not rebuild the supplied board', () {
    controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );
    final inconsistent = MeditationSession(
      matchId: 'inconsistent-restore',
      startedAt: now,
      boardState: BoardState.initial(currentPlayer: PieceType.white),
      firstPlayer: PieceType.black,
      humanPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.easy,
      moveHistory: controller.session.moveHistory,
      noCapturePlyCount: 1,
      turnClock: TurnClock.started(now),
    );

    expect(
      () => MeditationSessionController.restore(inconsistent),
      throwsStateError,
    );
  });

  test('restore rejects a changed board with empty history', () {
    final changedBoard = BoardState.initial().movePiece(
      const Position(0, 0),
      const Position(0, 1),
    );
    final inconsistent = MeditationSession(
      matchId: 'empty-history-changed-board',
      startedAt: now,
      boardState: changedBoard,
      firstPlayer: PieceType.black,
      humanPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.easy,
      turnClock: TurnClock.started(now),
    );

    expect(
      () => MeditationSessionController.restore(inconsistent),
      throwsStateError,
    );
  });

  test('restore rejects a terminal result that the board cannot support', () {
    final inconsistent = MeditationSession(
      matchId: 'fake-terminal',
      startedAt: now,
      boardState: BoardState.initial(),
      firstPlayer: PieceType.black,
      humanPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.easy,
      turnClock: null,
      gameResult: GameResult.blackWin(
        reason: '伪造终局',
        moveCount: 0,
        duration: Duration.zero,
      ),
    );

    expect(
      () => MeditationSessionController.restore(inconsistent),
      throwsStateError,
    );
  });

  test('restore rejects impossible or contradictory timeout metadata', () {
    MeditationSession timeoutSession(GameResult result) => MeditationSession(
          matchId: 'fake-timeout',
          startedAt: now.subtract(const Duration(minutes: 1)),
          boardState: BoardState.initial(),
          firstPlayer: PieceType.black,
          humanPlayer: PieceType.black,
          aiDifficulty: AIDifficulty.easy,
          turnClock: null,
          gameResult: result,
        );

    expect(
      () => MeditationSessionController.restore(
        timeoutSession(
          const GameResult(
            status: GameStatus.timeout,
            winner: PieceType.white,
            reason: '黑方超时',
            endReason: GameEndReason.timeout,
            moveCount: 0,
            duration: Duration.zero,
          ),
        ),
      ),
      throwsStateError,
    );
    expect(
      () => MeditationSessionController.restore(
        timeoutSession(
          const GameResult(
            status: GameStatus.timeout,
            winner: PieceType.white,
            reason: '白方超时',
            endReason: GameEndReason.timeout,
            moveCount: 0,
            duration: Duration(seconds: 60),
          ),
        ),
      ),
      throwsStateError,
    );
  });

  test('resuming a paused zero clock completes timeout immediately', () {
    final zeroClock = TurnClock.started(
      now.subtract(const Duration(seconds: 60)),
    ).pause(now);
    controller = MeditationSessionController.restore(
      MeditationSession(
        matchId: 'paused-zero',
        startedAt: now.subtract(const Duration(minutes: 1)),
        boardState: BoardState.initial(),
        firstPlayer: PieceType.black,
        humanPlayer: PieceType.black,
        aiDifficulty: AIDifficulty.easy,
        turnClock: zeroClock,
      ),
      now: () => now,
    );

    final resumed = controller.resume();

    expect(resumed.outcome, MeditationActionOutcome.completed);
    expect(controller.session.gameResult!.status, GameStatus.timeout);
  });

  test('injected AI can play black first without hardcoded colors', () async {
    final ai = _FakeAI(AIDifficulty.easy)
      ..complete(
        const AIMoveResult(
          from: Position(0, 0),
          to: Position(0, 1),
          score: 1,
        ),
      );
    controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.white,
      firstPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.easy,
      now: () => now,
    );
    controller.completeOpening();

    final action = await controller.playAiTurn(ai);

    expect(action.outcome, MeditationActionOutcome.moved);
    expect(action.committedMove!.player, PieceType.black);
    expect(controller.session.phase, MeditationSessionPhase.humanTurn);
  });

  test('late AI result cannot commit after the session is paused', () async {
    controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.white,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    controller.completeOpening();
    final ai = _FakeAI(AIDifficulty.medium);

    final pending = controller.playAiTurn(ai);
    controller.pause();
    ai.complete(
      const AIMoveResult(
        from: Position(0, 0),
        to: Position(0, 1),
        score: 1,
      ),
    );
    final action = await pending;

    expect(action.outcome, MeditationActionOutcome.rejected);
    expect(action.rejection, MeditationRejection.staleRevision);
    expect(controller.session.moveHistory, isEmpty);
    expect(controller.session.phase, MeditationSessionPhase.paused);
  });

  test('deadline reached while AI thinks becomes timeout, not a late move',
      () async {
    controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.white,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    controller.completeOpening();
    final ai = _FakeAI(AIDifficulty.medium);

    final pending = controller.playAiTurn(ai);
    now = now.add(const Duration(seconds: 60));
    ai.complete(
      const AIMoveResult(
        from: Position(0, 0),
        to: Position(0, 1),
        score: 1,
      ),
    );
    final action = await pending;

    expect(action.outcome, MeditationActionOutcome.completed);
    expect(controller.session.gameResult!.status, GameStatus.timeout);
    expect(controller.session.gameResult!.winner, PieceType.white);
    expect(controller.session.moveHistory, isEmpty);
  });
}

class _FakeAI extends AIPlayer {
  final Completer<AIMoveResult?> _result = Completer<AIMoveResult?>();

  _FakeAI(super.difficulty);

  void complete(AIMoveResult? result) {
    _result.complete(result);
  }

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) =>
      _result.future;

  @override
  String get name => 'Fake AI';

  @override
  String get description => 'Test AI';
}

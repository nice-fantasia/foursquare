import '../ai/ai_player.dart';
import '../engine/game_engine.dart';
import '../engine/move_validator.dart';
import '../models/board_state.dart';
import '../models/game_result.dart';
import '../models/move.dart';
import '../models/piece_type.dart';
import '../models/position.dart';
import '../services/turn_clock.dart';
import 'meditation_session.dart';

enum MeditationActionOutcome {
  unchanged,
  started,
  selected,
  deselected,
  moved,
  paused,
  resumed,
  completed,
  rejected,
}

enum MeditationRejection {
  openingNotCompleted,
  openingAlreadyCompleted,
  invalidPosition,
  noOwnPiece,
  illegalMove,
  notHumanTurn,
  notAiTurn,
  paused,
  notPaused,
  finished,
  staleRevision,
  aiUnavailable,
}

final class MeditationActionResult {
  final MeditationActionOutcome outcome;
  final MeditationSession session;
  final MeditationRejection? rejection;
  final Move? committedMove;

  const MeditationActionResult({
    required this.outcome,
    required this.session,
    this.rejection,
    this.committedMove,
  });
}

/// Synchronous rule authority for a single meditation game.
///
/// Speech, prompts, UI, persistence and AI scheduling stay outside this class.
final class MeditationSessionController {
  final GameEngine _gameEngine;
  final MoveValidator _moveValidator;
  final DateTime Function() _now;
  MeditationSession _session;

  MeditationSessionController._({
    required MeditationSession session,
    required GameEngine gameEngine,
    required MoveValidator moveValidator,
    required DateTime Function() now,
  })  : _session = session,
        _gameEngine = gameEngine,
        _moveValidator = moveValidator,
        _now = now;

  factory MeditationSessionController.newGame({
    required PieceType humanPlayer,
    required PieceType firstPlayer,
    AIDifficulty aiDifficulty = AIDifficulty.medium,
    DateTime Function()? now,
    GameEngine? gameEngine,
    MoveValidator? moveValidator,
  }) {
    final clock = now ?? DateTime.now;
    final startedAt = clock().toUtc();
    final engine = gameEngine ?? GameEngine();
    engine.startNewGame(startedAt: startedAt);
    final session = MeditationSession(
      matchId: 'meditation-${startedAt.microsecondsSinceEpoch}',
      startedAt: startedAt,
      boardState: BoardState.initial(currentPlayer: firstPlayer),
      firstPlayer: firstPlayer,
      humanPlayer: humanPlayer,
      aiDifficulty: aiDifficulty,
      turnClock: null,
    );
    return MeditationSessionController._(
      session: session,
      gameEngine: engine,
      moveValidator: moveValidator ?? MoveValidator(),
      now: clock,
    );
  }

  factory MeditationSessionController.restore(
    MeditationSession session, {
    DateTime Function()? now,
    GameEngine? gameEngine,
    MoveValidator? moveValidator,
  }) {
    final engine = gameEngine ?? GameEngine();
    _validateRestoredSession(session);
    engine.restoreGame(session.moveHistory, startedAt: session.startedAt);
    final controller = MeditationSessionController._(
      session: session,
      gameEngine: engine,
      moveValidator: moveValidator ?? MoveValidator(),
      now: now ?? DateTime.now,
    );
    controller.tick();
    return controller;
  }

  /// Creates a controller around a synthetic rule scenario used by tests.
  /// Production persistence must always use [restore].
  factory MeditationSessionController.fromSnapshotForTesting(
    MeditationSession session, {
    DateTime Function()? now,
    GameEngine? gameEngine,
    MoveValidator? moveValidator,
  }) {
    final engine = gameEngine ?? GameEngine();
    engine.restoreGame(session.moveHistory, startedAt: session.startedAt);
    return MeditationSessionController._(
      session: session,
      gameEngine: engine,
      moveValidator: moveValidator ?? MoveValidator(),
      now: now ?? DateTime.now,
    );
  }

  MeditationSession get session => _session;

  MeditationActionResult completeOpening() {
    if (_session.gameResult != null) {
      return _rejected(MeditationRejection.finished);
    }
    if (_session.phase != MeditationSessionPhase.opening) {
      return _rejected(MeditationRejection.openingAlreadyCompleted);
    }
    final now = _now();
    _session = _session.copyWith(
      turnClock: TurnClock.started(now),
      revision: _session.revision + 1,
    );
    return _result(MeditationActionOutcome.started);
  }

  Map<Position, List<Position>> availableHumanMoves() {
    if (_session.gameResult != null ||
        _session.phase != MeditationSessionPhase.humanTurn) {
      return const {};
    }
    final moves = <Position, List<Position>>{};
    for (final position
        in _session.boardState.getAllPieces(_session.humanPlayer)) {
      final targets = _moveValidator.getValidMoves(
        _session.boardState,
        position,
      );
      if (targets.isNotEmpty) {
        moves[position] = List.unmodifiable(targets);
      }
    }
    return Map<Position, List<Position>>.unmodifiable(moves);
  }

  MeditationActionResult activateHumanPosition(Position position) {
    final now = _now();
    final guard = _guardMove(forHuman: true, at: now);
    if (guard != null) {
      return guard;
    }
    if (!position.isValid()) {
      return _rejected(MeditationRejection.invalidPosition);
    }

    final selected = _session.selectedPosition;
    final piece = _session.boardState.getPiece(position);
    if (selected == null) {
      if (piece != _session.humanPlayer) {
        return _rejected(MeditationRejection.noOwnPiece);
      }
      return _select(position);
    }

    if (selected == position) {
      _session = _session.copyWith(
        clearSelection: true,
        revision: _session.revision + 1,
      );
      return _result(MeditationActionOutcome.deselected);
    }
    if (piece == _session.humanPlayer) {
      return _select(position);
    }
    return _commitMove(selected, position, at: now);
  }

  MeditationActionResult submitHumanMove(Position from, Position to) {
    final now = _now();
    final guard = _guardMove(forHuman: true, at: now);
    if (guard != null) {
      return guard;
    }
    return _commitMove(from, to, at: now);
  }

  MeditationActionResult submitAiMove(Position from, Position to) {
    final now = _now();
    final guard = _guardMove(forHuman: false, at: now);
    if (guard != null) {
      return guard;
    }
    return _commitMove(from, to, at: now);
  }

  MeditationActionResult cancelSelection() {
    final now = _now();
    final guard = _guardMove(forHuman: true, at: now);
    if (guard != null) {
      return guard;
    }
    if (_session.selectedPosition == null) {
      return _result(MeditationActionOutcome.unchanged);
    }
    _session = _session.copyWith(
      clearSelection: true,
      revision: _session.revision + 1,
    );
    return _result(MeditationActionOutcome.deselected);
  }

  Future<MeditationActionResult> playAiTurn(AIPlayer aiPlayer) async {
    final guard = _guardMove(forHuman: false, at: _now());
    if (guard != null) {
      return guard;
    }

    final expectedRevision = _session.revision;
    final AIMoveResult? move;
    try {
      move = await aiPlayer.selectMove(
        _session.boardState,
        noCapturePlyCount: _session.noCapturePlyCount,
      );
    } catch (_) {
      if (_session.revision != expectedRevision) {
        return _rejected(MeditationRejection.staleRevision);
      }
      final completedAt = _now();
      final timedOut = _completeTimeoutIfNeeded(completedAt);
      if (timedOut != null) {
        return timedOut;
      }
      return _rejected(MeditationRejection.aiUnavailable);
    }

    if (_session.revision != expectedRevision) {
      return _rejected(MeditationRejection.staleRevision);
    }
    final completedAt = _now();
    final timedOut = _completeTimeoutIfNeeded(completedAt);
    if (timedOut != null) {
      return timedOut;
    }
    if (move == null) {
      return _rejected(MeditationRejection.aiUnavailable);
    }
    return _commitMove(move.from, move.to, at: completedAt);
  }

  MeditationActionResult pause() {
    final now = _now();
    if (_session.gameResult != null) {
      return _rejected(MeditationRejection.finished);
    }
    final turnClock = _session.turnClock;
    if (turnClock == null) {
      return _rejected(MeditationRejection.openingNotCompleted);
    }
    if (turnClock.isPaused) {
      return _rejected(MeditationRejection.paused);
    }
    final timedOut = _completeTimeoutIfNeeded(now);
    if (timedOut != null) {
      return timedOut;
    }
    _session = _session.copyWith(
      turnClock: turnClock.pause(now),
      clearSelection: true,
      revision: _session.revision + 1,
    );
    return _result(MeditationActionOutcome.paused);
  }

  MeditationActionResult resume() {
    final now = _now();
    if (_session.gameResult != null) {
      return _rejected(MeditationRejection.finished);
    }
    final turnClock = _session.turnClock;
    if (turnClock == null) {
      return _rejected(MeditationRejection.openingNotCompleted);
    }
    if (!turnClock.isPaused) {
      return _rejected(MeditationRejection.notPaused);
    }
    final timedOut = _completeTimeoutIfNeeded(now);
    if (timedOut != null) {
      return timedOut;
    }
    _session = _session.copyWith(
      turnClock: turnClock.resume(now),
      revision: _session.revision + 1,
    );
    return _result(MeditationActionOutcome.resumed);
  }

  MeditationActionResult tick() {
    if (_session.gameResult != null) {
      return _rejected(MeditationRejection.finished);
    }
    final turnClock = _session.turnClock;
    if (turnClock == null) {
      return _rejected(MeditationRejection.openingNotCompleted);
    }
    if (turnClock.isPaused) {
      return _rejected(MeditationRejection.paused);
    }
    return _completeTimeoutIfNeeded(_now()) ??
        _result(MeditationActionOutcome.unchanged);
  }

  MeditationActionResult abandon() {
    final now = _now();
    if (_session.gameResult != null) {
      return _rejected(MeditationRejection.finished);
    }
    if (_session.turnClock == null) {
      return _rejected(MeditationRejection.openingNotCompleted);
    }
    final timedOut = _completeTimeoutIfNeeded(now);
    if (timedOut != null) {
      return timedOut;
    }
    final result = GameResult.abandoned(
      abandonedPlayer: _session.humanPlayer,
      moveCount: _session.moveHistory.length,
      duration: _elapsedDuration(now),
    );
    _session = _session.copyWith(
      gameResult: result,
      clearTurnClock: true,
      clearSelection: true,
      revision: _session.revision + 1,
    );
    return _result(MeditationActionOutcome.completed);
  }

  MeditationActionResult _select(Position position) {
    final validMoves = _moveValidator.getValidMoves(
      _session.boardState,
      position,
    );
    _session = _session.copyWith(
      selectedPosition: position,
      validMoves: validMoves,
      revision: _session.revision + 1,
    );
    return _result(MeditationActionOutcome.selected);
  }

  MeditationActionResult _commitMove(
    Position from,
    Position to, {
    required DateTime at,
  }) {
    if (!from.isValid() || !to.isValid()) {
      return _rejected(MeditationRejection.invalidPosition);
    }
    if (!_moveValidator.isValidMove(_session.boardState, from, to)) {
      return _rejected(MeditationRejection.illegalMove);
    }

    final result = _gameEngine.executeMove(
      _session.boardState,
      from,
      to,
      noCapturePlyCount: _session.noCapturePlyCount,
    );
    if (!result.success || result.move == null || result.newBoard == null) {
      return _rejected(MeditationRejection.illegalMove);
    }

    final authoritativeMove = result.move!.copyWith(
      timestamp: at.toUtc(),
    );
    final history = [..._session.moveHistory, authoritativeMove];
    final terminalResult = result.gameResult == null
        ? null
        : GameResult(
            status: result.gameResult!.status,
            winner: result.gameResult!.winner,
            reason: result.gameResult!.reason,
            endReason: result.gameResult!.endReason,
            moveCount: history.length,
            duration: _elapsedDuration(at),
          );
    _session = _session.copyWith(
      boardState: result.newBoard,
      moveHistory: history,
      noCapturePlyCount: result.noCapturePlyCount,
      turnClock: terminalResult == null ? TurnClock.started(at) : null,
      clearTurnClock: terminalResult != null,
      clearSelection: true,
      gameResult: terminalResult,
      revision: _session.revision + 1,
    );
    return MeditationActionResult(
      outcome: terminalResult == null
          ? MeditationActionOutcome.moved
          : MeditationActionOutcome.completed,
      session: _session,
      committedMove: authoritativeMove,
    );
  }

  MeditationActionResult? _guardMove({
    required bool forHuman,
    required DateTime at,
  }) {
    if (_session.gameResult != null) {
      return _rejected(MeditationRejection.finished);
    }
    final turnClock = _session.turnClock;
    if (turnClock == null) {
      return _rejected(MeditationRejection.openingNotCompleted);
    }
    if (turnClock.isPaused) {
      return _rejected(MeditationRejection.paused);
    }
    final timedOut = _completeTimeoutIfNeeded(at);
    if (timedOut != null) {
      return timedOut;
    }
    if (forHuman && _session.phase != MeditationSessionPhase.humanTurn) {
      return _rejected(MeditationRejection.notHumanTurn);
    }
    if (!forHuman && _session.phase != MeditationSessionPhase.aiTurn) {
      return _rejected(MeditationRejection.notAiTurn);
    }
    return null;
  }

  MeditationActionResult? _completeTimeoutIfNeeded(DateTime at) {
    final clock = _session.turnClock;
    if (clock == null) {
      return null;
    }
    if (!clock.isExpiredAt(at)) {
      return null;
    }
    final result = GameResult.timeout(
      timeoutPlayer: _session.currentPlayer,
      moveCount: _session.moveHistory.length,
      duration: _elapsedDuration(at),
    );
    _session = _session.copyWith(
      gameResult: result,
      clearTurnClock: true,
      clearSelection: true,
      revision: _session.revision + 1,
    );
    return _result(MeditationActionOutcome.completed);
  }

  Duration _elapsedDuration(DateTime at) {
    final elapsed = at.toUtc().difference(_session.startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  MeditationActionResult _rejected(MeditationRejection rejection) {
    return MeditationActionResult(
      outcome: MeditationActionOutcome.rejected,
      session: _session,
      rejection: rejection,
    );
  }

  MeditationActionResult _result(MeditationActionOutcome outcome) {
    return MeditationActionResult(
      outcome: outcome,
      session: _session,
    );
  }

  static void _validateRestoredSession(MeditationSession session) {
    var previousMoveAt = session.startedAt;
    for (final move in session.moveHistory) {
      final moveAt = move.timestamp.toUtc();
      if (moveAt.isBefore(previousMoveAt)) {
        throw StateError('Meditation history timestamps are inconsistent');
      }
      previousMoveAt = moveAt;
    }
    if (session.moveHistory.isEmpty) {
      final initial = BoardState.initial(currentPlayer: session.firstPlayer);
      if (session.boardState != initial || session.noCapturePlyCount != 0) {
        throw StateError('Empty meditation history must use the initial board');
      }
    } else {
      final replay = GameEngine()..startNewGame(startedAt: session.startedAt);
      var board = BoardState.initial(currentPlayer: session.firstPlayer);
      var noCapturePlyCount = 0;
      for (final recorded in session.moveHistory) {
        if (recorded.player != board.currentPlayer) {
          throw StateError('Meditation history player order is inconsistent');
        }
        final result = replay.executeMove(
          board,
          recorded.from,
          recorded.to,
          noCapturePlyCount: noCapturePlyCount,
        );
        if (!result.success ||
            result.move == null ||
            result.newBoard == null ||
            !_samePositions(
              result.move!.capturedPieces,
              recorded.capturedPieces,
            )) {
          throw StateError('Meditation history contains an invalid move');
        }
        board = result.newBoard!;
        noCapturePlyCount = result.noCapturePlyCount;
      }
      if (board != session.boardState ||
          noCapturePlyCount != session.noCapturePlyCount) {
        throw StateError('Meditation snapshot does not match its history');
      }
    }
    if (session.gameResult == null) {
      final expectedPlayer = session.moveHistory.length.isEven
          ? session.firstPlayer
          : session.firstPlayer.getOpponent();
      if (session.currentPlayer != expectedPlayer) {
        throw StateError('Meditation active player is inconsistent');
      }
      if (session.noCapturePlyCount >= 50 ||
          GameEngine().checkGameOver(session.boardState) != null) {
        throw StateError('Meditation active snapshot is already terminal');
      }
    }
    final selected = session.selectedPosition;
    if (selected != null) {
      final expectedMoves = MoveValidator().getValidMoves(
        session.boardState,
        selected,
      );
      if (session.phase != MeditationSessionPhase.humanTurn ||
          session.boardState.getPiece(selected) != session.humanPlayer ||
          !_samePositions(expectedMoves, session.validMoves)) {
        throw StateError('Meditation selection snapshot is inconsistent');
      }
    }
    if (session.gameResult != null &&
        session.gameResult!.moveCount != session.moveHistory.length) {
      throw StateError('Meditation terminal metadata is inconsistent');
    }
    final terminal = session.gameResult;
    if (terminal != null) {
      final minimumDuration = previousMoveAt.difference(session.startedAt);
      if (terminal.status == GameStatus.ongoing ||
          terminal.duration.isNegative ||
          terminal.duration < minimumDuration) {
        throw StateError('Meditation terminal result is invalid');
      }
      switch (terminal.endReason) {
        case GameEndReason.pieceCount:
        case GameEndReason.noLegalMoves:
          final expected = GameEngine().checkGameOver(session.boardState);
          if (expected == null ||
              terminal.status != expected.status ||
              terminal.winner != expected.winner ||
              terminal.endReason != expected.endReason) {
            throw StateError('Meditation board does not match its result');
          }
          break;
        case GameEndReason.noCaptureLimit:
          if (terminal.status != GameStatus.draw ||
              terminal.winner != null ||
              session.noCapturePlyCount < 50) {
            throw StateError('Meditation draw metadata is inconsistent');
          }
          break;
        case GameEndReason.timeout:
          if (terminal.status != GameStatus.timeout ||
              terminal.winner != session.currentPlayer.getOpponent() ||
              terminal.duration < TurnClock.defaultTurnDuration ||
              terminal.reason !=
                  '${session.currentPlayer.getDisplayName()}超时') {
            throw StateError('Meditation timeout metadata is inconsistent');
          }
          break;
        case GameEndReason.abandoned:
          if (terminal.status != GameStatus.abandoned ||
              terminal.winner != session.humanPlayer.getOpponent()) {
            throw StateError('Meditation abandon metadata is inconsistent');
          }
          break;
        case GameEndReason.disconnect:
          throw StateError('Meditation session cannot end by disconnect');
      }
    }
  }

  static bool _samePositions(List<Position> left, List<Position> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}

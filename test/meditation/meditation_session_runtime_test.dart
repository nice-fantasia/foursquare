import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/voice_game_intent.dart';
import 'package:foursquare/meditation/meditation_session.dart';
import 'package:foursquare/meditation/meditation_session_persistence.dart';
import 'package:foursquare/meditation/meditation_session_runtime.dart';
import 'package:foursquare/meditation/meditation_session_snapshot.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_record.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';

void main() {
  final now = DateTime.utc(2026, 8, 1, 12);

  test('新局、开场、人类与 AI 修订通过统一运行时自动落盘', () async {
    final repository = _MemoryRepository();
    final persistence = MeditationSessionPersistence(
      repository: repository,
      now: () => now,
    );
    final runtime = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _SingleMoveAI(),
      persistence: persistence,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    addTearDown(runtime.dispose);

    expect(repository.value?.session.phase.name, 'opening');
    expect(runtime.session.aiDifficulty, AIDifficulty.easy);
    await runtime.start();
    expect(repository.value?.session.phase.name, 'humanTurn');

    await runtime.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(0, 1),
      ),
    );

    expect(runtime.session.moveHistory, hasLength(2));
    expect(repository.value?.session, runtime.session);
  });

  test('恢复时立即超时会先保存终局、归档再删除', () async {
    final repository = _MemoryRepository();
    final persistence = MeditationSessionPersistence(
      repository: repository,
      now: () => now,
    );
    final seed = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _SingleMoveAI(),
      persistence: persistence,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    await seed.start();
    seed.dispose();
    final expired = repository.value!.toJson()..['remainingMilliseconds'] = 0;
    repository.value = MeditationSessionSnapshot.fromJson(expired);
    final operations = <String>[];
    repository.onSave = (_) => operations.add('save');
    repository.onDelete = (_) => operations.add('delete');
    GameRecord? archived;

    final restored = await MeditationSessionRuntime.restore(
      aiPlayer: _FailIfCalledAI(),
      persistence: persistence,
      archiveCompletedGame: (record) async {
        operations.add('archive');
        archived = record;
        return true;
      },
      now: () => now,
    );

    expect(restored?.session.gameResult?.status.name, 'timeout');
    expect(operations, ['save', 'archive', 'delete']);
    expect(archived?.id, restored?.session.matchId);
    expect(repository.value, isNull);
  });

  test('没有未完成存档时恢复返回空', () async {
    final runtime = await MeditationSessionRuntime.restore(
      aiPlayer: _FailIfCalledAI(),
      persistence: MeditationSessionPersistence(
        repository: _MemoryRepository(),
        now: () => now,
      ),
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );

    expect(runtime, isNull);
  });

  test('恢复终局归档失败时保留存档供下次重试', () async {
    final repository = _MemoryRepository();
    final persistence = MeditationSessionPersistence(
      repository: repository,
      now: () => now,
    );
    final seed = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _SingleMoveAI(),
      persistence: persistence,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    await seed.start();
    seed.dispose();
    final expired = repository.value!.toJson()..['remainingMilliseconds'] = 0;
    repository.value = MeditationSessionSnapshot.fromJson(expired);

    await expectLater(
      MeditationSessionRuntime.restore(
        aiPlayer: _FailIfCalledAI(),
        persistence: persistence,
        archiveCompletedGame: (_) async => false,
        now: () => now,
      ),
      throwsStateError,
    );

    expect(repository.value?.session.gameResult?.status.name, 'timeout');
  });

  test('active deadline settles, archives and clears without voice input',
      () async {
    var currentTime = now;
    final timers = _FakeDeadlineTimerFactory();
    final repository = _MemoryRepository();
    final archived = <GameRecord>[];
    final runtime = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _FailIfCalledAI(),
      persistence: MeditationSessionPersistence(
        repository: repository,
        now: () => currentTime,
      ),
      archiveCompletedGame: (record) async {
        archived.add(record);
        return true;
      },
      now: () => currentTime,
      timerFactory: timers.create,
    );
    addTearDown(runtime.dispose);

    await runtime.start();
    expect(timers.latest.delay, const Duration(seconds: 60));
    currentTime = currentTime.add(const Duration(seconds: 60));
    await timers.latest.fire();

    expect(runtime.session.gameResult?.status.name, 'timeout');
    expect(archived, hasLength(1));
    expect(repository.value, isNull);
  });

  test('restored terminal is not archived again when start narrates it',
      () async {
    final repository = _MemoryRepository();
    final persistence = MeditationSessionPersistence(
      repository: repository,
      now: () => now,
    );
    final seed = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _SingleMoveAI(),
      persistence: persistence,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    await seed.start();
    seed.dispose();
    final expired = repository.value!.toJson()..['remainingMilliseconds'] = 0;
    repository.value = MeditationSessionSnapshot.fromJson(expired);
    var archiveCalls = 0;

    final restored = await MeditationSessionRuntime.restore(
      aiPlayer: _FailIfCalledAI(),
      persistence: persistence,
      archiveCompletedGame: (_) async {
        archiveCalls += 1;
        return true;
      },
      now: () => now,
    );
    addTearDown(restored!.dispose);
    await restored.start();

    expect(archiveCalls, 1);
    expect(repository.value, isNull);
  });

  test('restore rejects an AI implementation with a different difficulty',
      () async {
    final repository = _MemoryRepository();
    final persistence = MeditationSessionPersistence(
      repository: repository,
      now: () => now,
    );
    final seed = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _SingleMoveAI(),
      persistence: persistence,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    seed.dispose();

    await expectLater(
      MeditationSessionRuntime.restore(
        aiPlayer: _HardFailIfCalledAI(),
        persistence: persistence,
        archiveCompletedGame: (_) async => true,
        now: () => now,
      ),
      throwsStateError,
    );
  });

  test('disposed runtime cannot overwrite a newly restored AI turn', () async {
    final repository = _MemoryRepository();
    final persistence = MeditationSessionPersistence(
      repository: repository,
      now: () => now,
    );
    final delayedAi = _DelayedAI();
    final oldRuntime = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: delayedAi,
      persistence: persistence,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    await oldRuntime.start();
    final oldTurn = oldRuntime.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(0, 1),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(delayedAi.calls, 1);
    expect(repository.value?.session.moveHistory, hasLength(1));
    oldRuntime.dispose();

    final restored = await MeditationSessionRuntime.restore(
      aiPlayer: _SingleMoveAI(),
      persistence: persistence,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    addTearDown(restored!.dispose);
    delayedAi.complete(
      const AIMoveResult(
        from: Position(0, 3),
        to: Position(0, 2),
        score: 1,
      ),
    );
    await oldTurn;

    expect(repository.value?.session.moveHistory, hasLength(1));
    await restored.start();
    expect(repository.value?.session, restored.session);
    expect(restored.session.moveHistory, hasLength(2));
  });

  test('deadline archive failure is observable and start retries it', () async {
    var currentTime = now;
    final timers = _FakeDeadlineTimerFactory();
    final repository = _MemoryRepository();
    var archiveCalls = 0;
    final backgroundErrors = <Object>[];
    final runtime = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _FailIfCalledAI(),
      persistence: MeditationSessionPersistence(
        repository: repository,
        now: () => currentTime,
      ),
      archiveCompletedGame: (_) async {
        archiveCalls += 1;
        return archiveCalls > 1;
      },
      now: () => currentTime,
      timerFactory: timers.create,
      onBackgroundError: (error, _) => backgroundErrors.add(error),
    );
    addTearDown(runtime.dispose);
    final sessions = <MeditationSession>[];
    final subscription = runtime.sessions.listen(sessions.add);
    addTearDown(subscription.cancel);
    await runtime.start();
    currentTime = currentTime.add(const Duration(seconds: 60));

    await timers.latest.fire();
    await Future<void>.delayed(Duration.zero);

    expect(runtime.backgroundError, isA<StateError>());
    expect(backgroundErrors, hasLength(1));
    expect(repository.value?.session.gameResult?.status.name, 'timeout');
    expect(sessions.last.phase, MeditationSessionPhase.completed);

    await runtime.handle(
      const VoiceActionIntent(VoiceGameAction.repeat),
    );
    expect(runtime.backgroundError, isA<StateError>());

    await runtime.start();

    expect(archiveCalls, 2);
    expect(runtime.backgroundError, isNull);
    expect(repository.value, isNull);
  });

  test('disposed deadline failure does not emit a late background callback',
      () async {
    var currentTime = now;
    final timers = _FakeDeadlineTimerFactory();
    final archiveGate = Completer<bool>();
    final backgroundErrors = <Object>[];
    final runtime = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _FailIfCalledAI(),
      persistence: MeditationSessionPersistence(
        repository: _MemoryRepository(),
        now: () => currentTime,
      ),
      archiveCompletedGame: (_) => archiveGate.future,
      now: () => currentTime,
      timerFactory: timers.create,
      onBackgroundError: (error, _) => backgroundErrors.add(error),
    );
    await runtime.start();
    currentTime = currentTime.add(const Duration(seconds: 60));

    final deadline = timers.latest.fire();
    await Future<void>.delayed(Duration.zero);
    runtime.dispose();
    archiveGate.complete(false);
    await deadline;

    expect(runtime.backgroundError, isNull);
    expect(backgroundErrors, isEmpty);
  });

  test('successful authority commits notify screen adapters', () async {
    final runtime = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _SingleMoveAI(),
      persistence: MeditationSessionPersistence(
        repository: _MemoryRepository(),
        now: () => now,
      ),
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    final sessions = <MeditationSession>[];
    final subscription = runtime.sessions.listen(sessions.add);
    addTearDown(subscription.cancel);
    addTearDown(runtime.dispose);

    await runtime.start();
    await runtime.handle(
      const VoiceMoveIntent(
        from: Position(0, 0),
        to: Position(0, 1),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      sessions.map((session) => session.phase),
      [
        MeditationSessionPhase.humanTurn,
        MeditationSessionPhase.aiTurn,
        MeditationSessionPhase.humanTurn,
      ],
    );
  });
}

final class _MemoryRepository implements MeditationSessionRepository {
  MeditationSessionSnapshot? value;
  void Function(MeditationSessionSnapshot snapshot)? onSave;
  void Function(String? matchId)? onDelete;

  @override
  Future<void> delete({String? matchId}) async {
    onDelete?.call(matchId);
    if (matchId == null || value?.session.matchId == matchId) {
      value = null;
    }
  }

  @override
  Future<MeditationSessionSnapshot?> load() async => value;

  @override
  Future<void> save(MeditationSessionSnapshot snapshot) async {
    onSave?.call(snapshot);
    value = MeditationSessionSnapshot.fromJson(snapshot.toJson());
  }
}

final class _SingleMoveAI extends AIPlayer {
  _SingleMoveAI() : super(AIDifficulty.easy);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) async {
    return const AIMoveResult(
      from: Position(0, 3),
      to: Position(0, 2),
      score: 1,
    );
  }

  @override
  String get name => 'Single move AI';

  @override
  String get description => 'Runtime test AI';
}

final class _FailIfCalledAI extends AIPlayer {
  _FailIfCalledAI() : super(AIDifficulty.easy);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) {
    throw StateError('AI must not run for restored timeout');
  }

  @override
  String get name => 'Fail if called AI';

  @override
  String get description => 'Detects unexpected scheduling';
}

final class _HardFailIfCalledAI extends AIPlayer {
  _HardFailIfCalledAI() : super(AIDifficulty.hard);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) {
    throw StateError('Mismatched AI must not run');
  }

  @override
  String get name => 'Hard fail if called AI';

  @override
  String get description => 'Detects mismatched restored difficulty';
}

final class _DelayedAI extends AIPlayer {
  final Completer<AIMoveResult?> _move = Completer<AIMoveResult?>();
  int calls = 0;

  _DelayedAI() : super(AIDifficulty.easy);

  void complete(AIMoveResult result) => _move.complete(result);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) {
    calls += 1;
    return _move.future;
  }

  @override
  String get name => 'Delayed runtime AI';

  @override
  String get description => 'Controls disposal races';
}

final class _FakeDeadlineTimerFactory {
  final List<_FakeDeadlineTimer> timers = [];

  _FakeDeadlineTimer create(
    Duration delay,
    Future<void> Function() callback,
  ) {
    final timer = _FakeDeadlineTimer(delay, callback);
    timers.add(timer);
    return timer;
  }

  _FakeDeadlineTimer get latest => timers.last;
}

final class _FakeDeadlineTimer implements MeditationDeadlineTimerHandle {
  final Duration delay;
  final Future<void> Function() _callback;
  bool cancelled = false;

  _FakeDeadlineTimer(this.delay, this._callback);

  Future<void> fire() async {
    if (!cancelled) {
      await _callback();
    }
  }

  @override
  void cancel() => cancelled = true;
}

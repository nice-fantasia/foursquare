import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/voice_game_intent.dart';
import 'package:foursquare/meditation/meditation_runtime_factory.dart';
import 'package:foursquare/meditation/meditation_session_persistence.dart';
import 'package:foursquare/meditation/meditation_session_snapshot.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_record.dart';
import 'package:foursquare/models/piece_type.dart';

void main() {
  final now = DateTime.utc(2026, 8, 1, 12);

  test('new sessions use one repository and the requested AI difficulty',
      () async {
    final repository = _MemoryRepository();
    final requestedDifficulties = <AIDifficulty>[];
    final factory = MeditationRuntimeFactory(
      repositoryFactory: () async => repository,
      aiFactory: (difficulty) {
        requestedDifficulties.add(difficulty);
        return _NoMoveAI(difficulty);
      },
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );

    final runtime = await factory.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.white,
      difficulty: AIDifficulty.hard,
    );
    addTearDown(runtime.dispose);

    expect(requestedDifficulties, [AIDifficulty.hard]);
    expect(runtime.session.aiDifficulty, AIDifficulty.hard);
    expect(repository.value?.session, runtime.session);
  });

  test('restore selects the AI from the persisted difficulty', () async {
    final repository = _MemoryRepository();
    final seedFactory = MeditationRuntimeFactory(
      repositoryFactory: () async => repository,
      aiFactory: _NoMoveAI.new,
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );
    final seed = await seedFactory.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      difficulty: AIDifficulty.easy,
    );
    seed.dispose();
    final restoredDifficulties = <AIDifficulty>[];
    final restoringFactory = MeditationRuntimeFactory(
      repositoryFactory: () async => repository,
      aiFactory: (difficulty) {
        restoredDifficulties.add(difficulty);
        return _NoMoveAI(difficulty);
      },
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );

    final restored = await restoringFactory.restore();
    addTearDown(restored!.dispose);

    expect(restoredDifficulties, [AIDifficulty.easy]);
    expect(restored.session.aiDifficulty, AIDifficulty.easy);
  });

  test('restore returns null without constructing an AI when no save exists',
      () async {
    var aiCalls = 0;
    final factory = MeditationRuntimeFactory(
      repositoryFactory: () async => _MemoryRepository(),
      aiFactory: (difficulty) {
        aiCalls += 1;
        return _NoMoveAI(difficulty);
      },
      archiveCompletedGame: (_) async => true,
      now: () => now,
    );

    expect(await factory.restore(), isNull);
    expect(aiCalls, 0);
  });

  test('completed sessions pass through the injected archive boundary',
      () async {
    final repository = _MemoryRepository();
    final archived = <GameRecord>[];
    final factory = MeditationRuntimeFactory(
      repositoryFactory: () async => repository,
      aiFactory: _NoMoveAI.new,
      archiveCompletedGame: (record) async {
        archived.add(record);
        return true;
      },
      now: () => now,
    );
    final runtime = await factory.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      difficulty: AIDifficulty.medium,
    );
    await runtime.start();

    await runtime.handle(
      const VoiceActionIntent(VoiceGameAction.exit),
    );
    await runtime.handle(
      const VoiceActionIntent(VoiceGameAction.confirmExit),
    );

    expect(archived, hasLength(1));
    expect(archived.single.mode, 'meditation');
    expect(repository.value, isNull);
    runtime.dispose();
  });
}

final class _MemoryRepository implements MeditationSessionRepository {
  MeditationSessionSnapshot? value;

  @override
  Future<void> delete({String? matchId}) async {
    if (matchId == null || value?.session.matchId == matchId) {
      value = null;
    }
  }

  @override
  Future<MeditationSessionSnapshot?> load() async => value;

  @override
  Future<void> save(MeditationSessionSnapshot snapshot) async {
    value = MeditationSessionSnapshot.fromJson(snapshot.toJson());
  }
}

final class _NoMoveAI extends AIPlayer {
  _NoMoveAI(super.difficulty);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) async =>
      null;

  @override
  String get name => 'No move AI';

  @override
  String get description => 'Factory boundary test AI';
}

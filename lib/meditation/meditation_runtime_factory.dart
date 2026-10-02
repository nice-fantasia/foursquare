import '../ai/ai_player.dart';
import '../ai/background_ai.dart';
import '../models/piece_type.dart';
import '../services/storage_service.dart';
import 'meditation_session_committer.dart';
import 'meditation_session_persistence.dart';
import 'meditation_session_runtime.dart';

typedef MeditationRepositoryFactory = Future<MeditationSessionRepository>
    Function();
typedef MeditationAiFactory = AIPlayer Function(AIDifficulty difficulty);

/// Production composition boundary for one meditation session runtime.
final class MeditationRuntimeFactory {
  final MeditationRepositoryFactory _repositoryFactory;
  final MeditationAiFactory _aiFactory;
  final MeditationGameArchiver _archiveCompletedGame;
  final DateTime Function() _now;

  const MeditationRuntimeFactory({
    required MeditationRepositoryFactory repositoryFactory,
    required MeditationAiFactory aiFactory,
    required MeditationGameArchiver archiveCompletedGame,
    DateTime Function() now = DateTime.now,
  })  : _repositoryFactory = repositoryFactory,
        _aiFactory = aiFactory,
        _archiveCompletedGame = archiveCompletedGame,
        _now = now;

  factory MeditationRuntimeFactory.production({
    StorageService? storageService,
  }) {
    final storage = storageService ?? StorageService();
    return MeditationRuntimeFactory(
      repositoryFactory: () async =>
          storage.createMeditationSessionRepository(),
      aiFactory: BackgroundAI.new,
      archiveCompletedGame: storage.recordCompletedGame,
    );
  }

  Future<MeditationSessionRuntime> createNew({
    required PieceType humanPlayer,
    required PieceType firstPlayer,
    required AIDifficulty difficulty,
  }) async {
    final repository = await _repositoryFactory();
    return MeditationSessionRuntime.createNew(
      humanPlayer: humanPlayer,
      firstPlayer: firstPlayer,
      aiPlayer: _createAi(difficulty),
      persistence: MeditationSessionPersistence(
        repository: repository,
        now: _now,
      ),
      archiveCompletedGame: _archiveCompletedGame,
      now: _now,
    );
  }

  Future<MeditationSessionRuntime?> restore() async {
    final repository = await _repositoryFactory();
    final snapshot = await repository.load();
    if (snapshot == null) {
      return null;
    }
    return MeditationSessionRuntime.restore(
      aiPlayer: _createAi(snapshot.session.aiDifficulty),
      persistence: MeditationSessionPersistence(
        repository: repository,
        now: _now,
      ),
      archiveCompletedGame: _archiveCompletedGame,
      now: _now,
    );
  }

  AIPlayer _createAi(AIDifficulty difficulty) {
    final ai = _aiFactory(difficulty);
    if (ai.difficulty != difficulty) {
      throw StateError('Meditation AI factory returned a different difficulty');
    }
    return ai;
  }
}

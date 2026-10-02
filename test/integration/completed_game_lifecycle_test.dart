import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/minimax_ai.dart';
import 'package:foursquare/bloc/game_bloc.dart';
import 'package:foursquare/bloc/game_event.dart';
import 'package:foursquare/bloc/game_state.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_result.dart';
import 'package:foursquare/models/game_record.dart';
import 'package:foursquare/models/move.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/services/audio_coordinator.dart' as audio;
import 'package:foursquare/services/game_replay_service.dart';
import 'package:foursquare/services/storage_service.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/ui/screens/game_history_page.dart';
import 'package:foursquare/ui/screens/game_replay_page.dart';
import 'package:foursquare/ui/widgets/themed_board_widget.dart';

class _Audio extends Mock implements audio.AudioCoordinator {}

class _FailsOnceStorage extends StorageService {
  _FailsOnceStorage(Box<dynamic> statistics, Box<dynamic> saves)
      : super.forTesting(statisticsBox: statistics, gameSaveBox: saves);
  bool failNextCompletion = true;
  @override
  Future<bool> recordCompletedGame(GameRecord record) {
    if (failNextCompletion) {
      failNextCompletion = false;
      return Future.value(false);
    }
    return super.recordCompletedGame(record);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(audio.GameEvent.pieceMoved);
    registerFallbackValue(audio.GameScene.gameplay);
  });
  late Directory directory;
  late Box<dynamic> statistics;
  late Box<dynamic> saves;
  late StorageService storage;
  late _Audio sound;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('foursquare-lifecycle-');
    Hive.init(directory.path);
    statistics = await Hive.openBox<dynamic>('completed-statistics');
    saves = await Hive.openBox<dynamic>('completed-saves');
    storage = StorageService.forTesting(
      statisticsBox: statistics,
      gameSaveBox: saves,
    );
    sound = _Audio();
    when(() => sound.initialize()).thenAnswer((_) async {});
    when(() => sound.onSceneChange(any())).thenAnswer((_) async {});
    when(() => sound.onGameEvent(any(), data: any(named: 'data')))
        .thenReturn(null);
  });
  tearDown(() async {
    await storage.dispose();
    await directory.delete(recursive: true);
  });

  test(
      'failed completion retains terminal save and recovers once after reopening',
      () async {
    storage = _FailsOnceStorage(statistics, saves);
    final fixture = await _naturalGame(PieceType.black);
    final bloc = GameBloc(
      storageService: storage,
      audioCoordinator: sound,
      now: () => DateTime.utc(2026, 10, 2),
      startingPlayerPicker: () => PieceType.black,
    );
    addTearDown(bloc.close);
    final started = bloc.stream.firstWhere((s) => s is GamePlaying);
    bloc.add(const NewGameEvent(mode: GameMode.pvp));
    final matchId = (await started).matchId;
    for (var step = 0; step < fixture.moves.length; step++) {
      final changed =
          bloc.stream.firstWhere((s) => s.moveHistory.length == step + 1);
      final move = fixture.moves[step];
      bloc.add(MovePieceEvent(from: move.from, to: move.to));
      await changed.timeout(const Duration(seconds: 5));
    }
    await _waitUntil(
      () async =>
          !(storage as _FailsOnceStorage).failNextCompletion &&
          (await storage.loadGame())?.moveHistory.length ==
              fixture.moves.length,
    );
    expect(bloc.state, isA<GameOver>());
    expect(await storage.hasSavedGame(), isTrue);
    expect((await storage.loadGame())!.matchId, matchId);
    expect((await storage.loadStatistics()).totalGames, 0);
    await bloc.close();
    await storage.dispose();
    statistics = await Hive.openBox<dynamic>('completed-statistics');
    saves = await Hive.openBox<dynamic>('completed-saves');
    storage = StorageService.forTesting(
      statisticsBox: statistics,
      gameSaveBox: saves,
    );
    final restored = GameBloc(
      storageService: storage,
      audioCoordinator: sound,
      now: () => DateTime.utc(2026, 10, 3),
    );
    addTearDown(restored.close);
    final ended = restored.stream.firstWhere((s) => s is GameOver);
    restored.add(const LoadGameEvent());
    expect(
      (await ended.timeout(const Duration(seconds: 5))).gameResult?.winner,
      fixture.result.winner,
    );
    await _waitUntil(
      () async =>
          (await storage.loadStatistics()).totalGames == 1 &&
          !await storage.hasSavedGame(),
    );
    expect(await storage.hasSavedGame(), isFalse);
    expect((await storage.loadStatistics()).totalGames, 1);
    expect((await storage.loadGameHistory()).single.id, matchId);
    expect(
      (await storage.loadGameHistory()).single.completedAt,
      DateTime.utc(2026, 10, 2),
    );
    restored.add(const LoadGameEvent());
    await pumpEventQueue();
    expect((await storage.loadStatistics()).totalGames, 1);
  });

  test(
    'twenty-one completed games retain twenty replays and all aggregate totals',
    () async {
      final fixture = await _naturalGame(PieceType.black);
      var now = DateTime.utc(2026, 10, 2);
      final bloc = GameBloc(
        storageService: storage,
        audioCoordinator: sound,
        now: () => now,
        startingPlayerPicker: () => PieceType.black,
      );
      addTearDown(bloc.close);
      final ids = <String>[];
      for (var game = 0; game < 21; game++) {
        now = now.add(const Duration(minutes: 1));
        final started = bloc.stream.firstWhere((s) => s is GamePlaying);
        bloc.add(const NewGameEvent(mode: GameMode.pvp));
        ids.add((await started).matchId!);
        for (var step = 0; step < fixture.moves.length; step++) {
          now = now.add(const Duration(seconds: 1));
          final changed =
              bloc.stream.firstWhere((s) => s.moveHistory.length == step + 1);
          final move = fixture.moves[step];
          bloc.add(MovePieceEvent(from: move.from, to: move.to));
          await changed.timeout(const Duration(seconds: 5));
        }
        await _waitUntil(
          () async =>
              (await storage.loadStatistics()).totalGames == game + 1 &&
              !await storage.hasSavedGame(),
        );
        expect(bloc.state, isA<GameOver>());
      }
      final history = await storage.loadGameHistory();
      final totals = await storage.loadStatistics();
      expect(
        history.map((record) => record.id).toList(),
        ids.skip(1).toList().reversed.toList(),
      );
      expect(totals.totalGames, 21);
      expect(totals.totalMoves, fixture.moves.length * 21);
      expect(
        totals.totalCaptures,
        fixture.moves.fold<int>(0, (n, m) => n + m.captureCount) * 21,
      );
      for (final record in history) {
        final replay = GameReplayService()
          ..startReplay(record.moves, startingPlayer: record.startingPlayer);
        expect(replay.goToEnd().boardState, fixture.boards.last);
      }
      expect(await storage.recordCompletedGame(history.first), isTrue);
      expect((await storage.loadStatistics()).totalGames, 21);
      await bloc.close();
      await storage.dispose();
      statistics = await Hive.openBox<dynamic>('completed-statistics');
      saves = await Hive.openBox<dynamic>('completed-saves');
      storage = StorageService.forTesting(
        statisticsBox: statistics,
        gameSaveBox: saves,
      );
      expect((await storage.loadStatistics()).totalGames, 21);
      expect(
        (await storage.loadGameHistory()).map((record) => record.id),
        history.map((record) => record.id),
      );
      expect(await storage.hasSavedGame(), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'natural PVE completion records the actual human color and difficulty',
    () async {
      var now = DateTime.utc(2026, 10, 2);
      final bloc = GameBloc(
        storageService: storage,
        audioCoordinator: sound,
        now: () => now,
        startingPlayerPicker: () => PieceType.black,
        humanPlayerPicker: () => PieceType.white,
        aiFactory: (difficulty) => MinimaxAI(difficulty, random: Random(42)),
      );
      addTearDown(bloc.close);
      final humanTurn = bloc.stream.firstWhere(
        (s) => s is GamePlaying && !s.isAITurn && !s.isAIThinking,
      );
      bloc.add(const NewGameEvent(mode: GameMode.pve, aiDifficulty: 'easy'));
      final initial = await humanTurn.timeout(const Duration(seconds: 5));
      for (var turn = 0; turn < 100 && bloc.state is GamePlaying; turn++) {
        final current = bloc.state as GamePlaying;
        expect(current.humanPlayer, PieceType.white);
        expect(current.isAITurn, isFalse);
        final move = (await MinimaxAI(AIDifficulty.medium, random: Random(turn))
            .selectMove(
          current.boardState,
          noCapturePlyCount: current.noCapturePlyCount,
        ))!;
        now = now.add(const Duration(seconds: 1));
        final advanced = bloc.stream.firstWhere(
          (s) =>
              s is GameOver ||
              s is GamePlaying &&
                  !s.isAITurn &&
                  !s.isAIThinking &&
                  s.moveHistory.length >= current.moveHistory.length + 2,
        );
        bloc.add(MovePieceEvent(from: move.from, to: move.to));
        await advanced.timeout(const Duration(seconds: 5));
      }
      await _waitUntil(
        () async =>
            (await storage.loadStatistics()).totalGames == 1 &&
            !await storage.hasSavedGame(),
      );
      final ended = bloc.state as GameOver;
      final record = (await storage.loadGameHistory()).single;
      final totals = await storage.loadStatistics();
      expect(record.id, initial.matchId);
      expect(record.humanPlayer, PieceType.white);
      expect(record.difficulty, 'easy');
      expect(record.mode, 'pve');
      expect(record.result, ended.gameResult);
      expect(totals.totalGames, 1);
      expect(totals.wins, record.result.winner == PieceType.white ? 1 : 0);
      expect(totals.losses, record.result.winner == PieceType.black ? 1 : 0);
      expect(totals.draws, record.result.winner == null ? 1 : 0);
      expect(totals.difficultyWins['easy'] ?? 0, totals.wins);
      expect(await storage.hasSavedGame(), isFalse);
      final replay = GameReplayService()
        ..startReplay(record.moves, startingPlayer: record.startingPlayer);
      expect(replay.goToEnd().boardState, ended.boardState);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
      'persisted natural history opens a replay with the original first player',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _naturalGame(PieceType.white)))!;
    final record = GameRecord(
      id: 'ui-natural-game',
      completedAt: DateTime.utc(2026, 10, 2),
      mode: 'pvp',
      startingPlayer: PieceType.white,
      result: fixture.result,
      moves: fixture.moves,
    );
    expect(
      await tester.runAsync(() => storage.recordCompletedGame(record)),
      isTrue,
    );
    final records = (await tester.runAsync(storage.loadGameHistory))!;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GameHistoryPage(loadHistory: () async => records),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<GameReplayPage>(find.byType(GameReplayPage)).startingPlayer,
      PieceType.white,
    );
    expect(
      tester
          .widget<ThemedBoardWidget>(find.byType(ThemedBoardWidget))
          .boardState,
      BoardState.initial(currentPlayer: PieceType.white),
    );
    await tester.tap(find.byIcon(Icons.last_page));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<ThemedBoardWidget>(find.byType(ThemedBoardWidget))
          .boardState,
      fixture.boards.last,
    );
    expect(find.textContaining('Position('), findsNothing);
  });

  for (final first in [PieceType.black, PieceType.white]) {
    test(
      'natural $first-first game persists, archives, and replays every move',
      () async {
        final fixture = await _naturalGame(first);
        var now = DateTime.utc(2026, 10, 2);
        final bloc = GameBloc(
          storageService: storage,
          audioCoordinator: sound,
          now: () => now,
          startingPlayerPicker: () => first,
        );
        addTearDown(bloc.close);
        final started = bloc.stream.firstWhere((state) => state is GamePlaying);
        bloc.add(const NewGameEvent(mode: GameMode.pvp));
        final initial = await started as GamePlaying;
        for (var index = 0; index < fixture.moves.length; index++) {
          now = now.add(const Duration(seconds: 1));
          final changed = bloc.stream
              .firstWhere((state) => state.moveHistory.length == index + 1);
          final move = fixture.moves[index];
          bloc.add(MovePieceEvent(from: move.from, to: move.to));
          final state = await changed.timeout(const Duration(seconds: 5));
          expect(state.boardState, fixture.boards[index]);
          if (state is GamePlaying) {
            await pumpEventQueue();
            expect(
              (await storage.loadGame())!
                  .boardState
                  .toBoardState(state.currentPlayer),
              state.boardState,
            );
          }
        }
        await _waitUntil(
          () async =>
              (await storage.loadStatistics()).totalGames == 1 &&
              !await storage.hasSavedGame(),
        );
        final ended = bloc.state as GameOver;
        expect(ended.gameResult?.endReason, fixture.result.endReason);
        expect(ended.gameResult?.winner, fixture.result.winner);
        expect(ended.matchId, initial.matchId);
        expect(await storage.hasSavedGame(), isFalse);
        final history = await storage.loadGameHistory();
        expect(history, hasLength(1));
        final record = history.single;
        expect(record.id, initial.matchId);
        expect(record.startingPlayer, first);
        expect(record.moves.length, fixture.moves.length);
        final totals = await storage.loadStatistics();
        expect(totals.totalGames, 1);
        expect(totals.totalMoves, record.moves.length);
        expect(
          totals.totalCaptures,
          record.moves.fold<int>(0, (sum, move) => sum + move.captureCount),
        );
        expect(totals.lastPlayedAt, record.completedAt);
        final replay = GameReplayService()
          ..startReplay(record.moves, startingPlayer: record.startingPlayer);
        for (var step = 0; step < fixture.moves.length; step++) {
          expect(replay.goForward().boardState, fixture.boards[step]);
        }
        expect(
          replay.goToStart().boardState,
          BoardState.initial(currentPlayer: first),
        );
        expect(replay.goToEnd().boardState, ended.boardState);
        bloc.add(TurnClockTickEvent(now.add(const Duration(seconds: 60))));
        await pumpEventQueue();
        expect((await storage.loadStatistics()).totalGames, 1);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Persistence did not reach expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<({List<Move> moves, List<BoardState> boards, GameResult result})>
    _naturalGame(PieceType first) async {
  final engine = GameEngine()..startNewGame();
  var board = BoardState.initial(currentPlayer: first);
  var count = 0;
  final boards = <BoardState>[];
  for (var ply = 0; ply < 200; ply++) {
    final ai = MinimaxAI(
      board.currentPlayer == first ? AIDifficulty.medium : AIDifficulty.easy,
      random: Random(20261002 + ply),
    );
    final move = (await ai.selectMove(board, noCapturePlyCount: count))!;
    final result =
        engine.executeMove(board, move.from, move.to, noCapturePlyCount: count);
    expect(result.success, isTrue);
    board = result.newBoard!;
    count = result.noCapturePlyCount;
    boards.add(board);
    if (result.gameOver) {
      return (
        moves: engine.moveHistory,
        boards: boards,
        result: result.gameResult!
      );
    }
  }
  throw StateError('Fixture did not reach a natural terminal result');
}

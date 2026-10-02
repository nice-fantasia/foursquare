/// Game BLoC 单元测试
///
/// 测试覆盖：
/// - 新游戏事件
/// - 重新开始事件
/// - 选中棋子事件
/// - 移动棋子事件
/// - 取消选中事件
/// - 撤销移动事件
/// - 游戏结束检测
library;

import 'dart:async';
import 'package:foursquare/ai/ai_player.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:foursquare/bloc/game_bloc.dart';
import 'package:foursquare/bloc/game_event.dart';
import 'package:foursquare/bloc/game_state.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_save.dart';
import 'package:foursquare/models/game_result.dart';
import 'package:foursquare/models/game_record.dart';
import 'package:foursquare/models/move.dart';
import 'package:foursquare/engine/game_engine.dart';
import 'package:foursquare/engine/move_validator.dart';
import 'package:foursquare/services/audio_coordinator.dart' as audio;
import 'package:foursquare/services/storage_service.dart';
import 'package:foursquare/services/turn_clock.dart';
import 'package:foursquare/models/audio_settings.dart';

// Mock classes
class MockGameEngine extends Mock implements GameEngine {}

class MockMoveValidator extends Mock implements MoveValidator {}

class MockAudioCoordinator extends Mock implements audio.AudioCoordinator {}

class MockStorageService extends Mock implements StorageService {}

class FakeGameSave extends Fake implements GameSave {}

class FakeGameRecord extends Fake implements GameRecord {}

const _blackOpeningMove = AIMoveResult(
  from: Position(0, 0),
  to: Position(0, 1),
  score: 0,
);

class DeferredAI extends AIPlayer {
  DeferredAI() : super(AIDifficulty.medium);
  final started = Completer<void>();
  final result = Completer<AIMoveResult?>();
  @override
  String get name => 'Deferred test AI';
  @override
  String get description => name;
  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) {
    started.complete();
    return result.future;
  }
}

void main() {
  // 注册fallback值以支持mocktail的any()匹配器
  setUpAll(() {
    registerFallbackValue(audio.GameEvent.pieceMoved);
    registerFallbackValue(audio.GameScene.gameplay);
    registerFallbackValue(BoardState.initial());
    registerFallbackValue(const Position(0, 0));
    registerFallbackValue(AudioSettings.defaultSettings);
    registerFallbackValue(FakeGameSave());
    registerFallbackValue(FakeGameRecord());
  });

  group('GameBloc', () {
    late GameEngine gameEngine;
    late MoveValidator moveValidator;
    late audio.AudioCoordinator audioCoordinator;
    late StorageService storageService;

    setUp(() {
      gameEngine = MockGameEngine();
      moveValidator = MockMoveValidator();
      audioCoordinator = MockAudioCoordinator();
      storageService = MockStorageService();

      // 设置默认的mock行为
      when(() => audioCoordinator.initialize()).thenAnswer((_) async {});
      when(() => audioCoordinator.onGameEvent(any(), data: any(named: 'data')))
          .thenReturn(null);
      when(() => audioCoordinator.onSceneChange(any()))
          .thenAnswer((_) async {});
      when(() => audioCoordinator.updateSettings(any()))
          .thenAnswer((_) async {});
      when(() => audioCoordinator.settings)
          .thenReturn(AudioSettings.defaultSettings);
      when(() => storageService.saveGame(any())).thenAnswer((_) async => true);
      when(() => storageService.deleteGameSave()).thenAnswer((_) async => true);
      when(() => storageService.archiveGame(any()))
          .thenAnswer((_) async => true);
      when(
        () => storageService.updateStatistics(
          isWin: any(named: 'isWin'),
          isLoss: any(named: 'isLoss'),
          isDraw: any(named: 'isDraw'),
          moves: any(named: 'moves'),
          captures: any(named: 'captures'),
          difficulty: any(named: 'difficulty'),
        ),
      ).thenAnswer((_) async => true);
    });

    test('初始状态应该是 GameInitial', () {
      final bloc = GameBloc(
        gameEngine: gameEngine,
        moveValidator: moveValidator,
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      );

      expect(bloc.state, isA<GameInitial>());

      bloc.close();
    });

    test('late AI result cannot overwrite a new game', () async {
      final ai = DeferredAI();
      final bloc = GameBloc(
        audioCoordinator: audioCoordinator,
        storageService: storageService,
        startingPlayerPicker: () => PieceType.black,
        humanPlayerPicker: () => PieceType.white,
        aiFactory: (_) => ai,
      );
      bloc.add(const NewGameEvent(mode: GameMode.pve));
      await ai.started.future;
      final newGame = bloc.stream.firstWhere((s) => s.mode == GameMode.pvp);
      bloc.add(const NewGameEvent(mode: GameMode.pvp));
      await newGame;
      ai.result.complete(_blackOpeningMove);
      await pumpEventQueue();
      expect(bloc.state.mode, GameMode.pvp);
      expect(bloc.state.moveHistory, isEmpty);
      expect(bloc.state.isAIThinking, isFalse);
      await bloc.close();
    });

    test(
        'pause invalidates AI result and resume starts exactly one fresh search',
        () async {
      final first = DeferredAI();
      final second = DeferredAI();
      var calls = 0;
      var now = DateTime.utc(2026, 9, 21);
      final bloc = GameBloc(
        audioCoordinator: audioCoordinator,
        storageService: storageService,
        startingPlayerPicker: () => PieceType.black,
        humanPlayerPicker: () => PieceType.white,
        now: () => now,
        aiFactory: (_) => ++calls == 1 ? first : second,
      );
      bloc.add(const NewGameEvent(mode: GameMode.pve));
      await first.started.future;
      bloc.add(const AIPlayEvent());
      await pumpEventQueue();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 5));
      final paused =
          bloc.stream.firstWhere((s) => s.turnClock?.isPaused == true);
      bloc.add(PauseTurnClockEvent(now));
      await paused;
      first.result.complete(_blackOpeningMove);
      await pumpEventQueue();
      expect(bloc.state.moveHistory, isEmpty);
      expect(
        bloc.state.turnClock!.remainingAt(now),
        const Duration(seconds: 55),
      );
      now = now.add(const Duration(seconds: 30));
      bloc.add(ResumeTurnClockEvent(now));
      await second.started.future;
      final committed =
          bloc.stream.firstWhere((s) => s.moveHistory.length == 1);
      second.result.complete(_blackOpeningMove);
      await committed;
      expect(calls, 2);
      expect(bloc.state.currentPlayer, PieceType.white);
      expect(bloc.state.isAIThinking, isFalse);
      await bloc.close();
    });

    test('deadline while AI thinks wins over its late move', () async {
      final ai = DeferredAI();
      var now = DateTime.utc(2026, 9, 21);
      final bloc = GameBloc(
        audioCoordinator: audioCoordinator,
        storageService: storageService,
        startingPlayerPicker: () => PieceType.black,
        humanPlayerPicker: () => PieceType.white,
        now: () => now,
        aiFactory: (_) => ai,
      );
      bloc.add(const NewGameEvent(mode: GameMode.pve));
      await ai.started.future;
      now = now.add(const Duration(seconds: 60));
      final ended = bloc.stream.firstWhere((s) => s is GameOver);
      bloc.add(TurnClockTickEvent(now));
      await ended;
      ai.result.complete(_blackOpeningMove);
      await pumpEventQueue();
      expect(bloc.state.gameResult?.endReason, GameEndReason.timeout);
      expect(bloc.state.moveHistory, isEmpty);
      await bloc.close();
    });

    test('closing while AI thinks ignores the late result', () async {
      final ai = DeferredAI();
      final bloc = GameBloc(
        audioCoordinator: audioCoordinator,
        storageService: storageService,
        startingPlayerPicker: () => PieceType.black,
        humanPlayerPicker: () => PieceType.white,
        aiFactory: (_) => ai,
      );
      bloc.add(const NewGameEvent(mode: GameMode.pve));
      await ai.started.future;
      final closing = bloc.close();
      ai.result.complete(_blackOpeningMove);
      await closing;
      expect(bloc.state.moveHistory, isEmpty);
    });

    blocTest<GameBloc, GameState>(
      '新游戏事件应该创建 GamePlaying 状态',
      build: () => GameBloc(
        gameEngine: gameEngine,
        moveValidator: moveValidator,
        audioCoordinator: audioCoordinator,
        storageService: storageService,
        startingPlayerPicker: () => PieceType.white,
      ),
      act: (bloc) => bloc.add(const NewGameEvent(mode: GameMode.pvp)),
      expect: () => [
        isA<GamePlaying>()
            .having((s) => s.mode, 'mode', GameMode.pvp)
            .having(
              (s) => s.boardState.currentPlayer,
              'currentPlayer',
              PieceType.white,
            )
            .having((s) => s.firstPlayer, 'firstPlayer', PieceType.white)
            .having((s) => s.moveHistory.length, 'moveHistory', 0),
      ],
      verify: (_) {
        verify(
          () => audioCoordinator.onGameEvent(audio.GameEvent.buttonClicked),
        ).called(1);
        verify(() => audioCoordinator.onSceneChange(audio.GameScene.gameplay))
            .called(1);
        verify(() => storageService.deleteGameSave()).called(1);
        verifyNever(() => storageService.archiveGame(any()));
      },
    );

    blocTest<GameBloc, GameState>(
      '重新开始事件应该重置游戏状态',
      build: () => GameBloc(
        gameEngine: gameEngine,
        moveValidator: moveValidator,
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial().movePiece(
          const Position(0, 0),
          const Position(0, 1),
        ),
        mode: GameMode.pvp,
        moveHistory: [
          Move.now(
            from: const Position(0, 0),
            to: const Position(0, 1),
            player: PieceType.black,
          ),
        ],
        selectedPiece: const Position(1, 0),
        validMoves: const [Position(1, 1)],
      ),
      act: (bloc) => bloc.add(const RestartGameEvent()),
      expect: () => [
        isA<GamePlaying>()
            .having((s) => s.moveHistory.length, 'moveHistory', 0),
      ],
      verify: (_) {
        verify(
          () => audioCoordinator.onGameEvent(audio.GameEvent.buttonClicked),
        ).called(1);
        verify(() => audioCoordinator.onSceneChange(audio.GameScene.gameplay))
            .called(1);
        verify(() => storageService.deleteGameSave()).called(1);
      },
    );

    blocTest<GameBloc, GameState>(
      '选中己方棋子应该更新选中状态和合法移动',
      build: () {
        when(() => moveValidator.getValidMoves(any(), any())).thenReturn([
          const Position(0, 1),
          const Position(1, 0),
        ]);

        return GameBloc(
          gameEngine: gameEngine,
          moveValidator: moveValidator,
          audioCoordinator: audioCoordinator,
          storageService: storageService,
        );
      },
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(const SelectPieceEvent(Position(0, 0))),
      expect: () => [
        isA<GamePlaying>()
            .having(
              (s) => s.selectedPiece,
              'selectedPiece',
              const Position(0, 0),
            )
            .having((s) => s.validMoves.length, 'validMoves', 2),
      ],
      verify: (_) {
        verify(
          () => audioCoordinator.onGameEvent(audio.GameEvent.pieceSelected),
        ).called(1);
        verify(() => moveValidator.getValidMoves(any(), const Position(0, 0)))
            .called(1);
      },
    );

    blocTest<GameBloc, GameState>(
      '统一棋盘位置事件应该选中己方棋子',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(
        const ActivateBoardPositionEvent(Position(0, 0)),
      ),
      expect: () => [
        isA<GamePlaying>()
            .having(
              (state) => state.selectedPiece,
              'selectedPiece',
              const Position(0, 0),
            )
            .having(
              (state) => state.validMoves,
              'validMoves',
              contains(const Position(0, 1)),
            ),
      ],
    );

    blocTest<GameBloc, GameState>(
      '统一棋盘位置事件应该通过权威移动链完成落子',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        selectedPiece: const Position(0, 0),
        validMoves: const [Position(0, 1)],
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(
        const ActivateBoardPositionEvent(Position(0, 1)),
      ),
      expect: () => [
        isA<GamePlaying>()
            .having(
              (state) => state.moveHistory,
              'moveHistory',
              hasLength(1),
            )
            .having(
              (state) => state.selectedPiece,
              'selectedPiece',
              isNull,
            ),
      ],
      verify: (_) {
        verify(() => storageService.saveGame(any())).called(1);
      },
    );

    blocTest<GameBloc, GameState>(
      '统一棋盘位置事件应该支持重选和取消',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        selectedPiece: const Position(0, 0),
        validMoves: const [Position(0, 1)],
        moveHistory: const [],
      ),
      act: (bloc) async {
        bloc.add(const ActivateBoardPositionEvent(Position(1, 0)));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ActivateBoardPositionEvent(Position(1, 0)));
      },
      expect: () => [
        isA<GamePlaying>().having(
          (state) => state.selectedPiece,
          'reselectedPiece',
          const Position(1, 0),
        ),
        isA<GamePlaying>().having(
          (state) => state.selectedPiece,
          'clearedPiece',
          isNull,
        ),
      ],
    );

    blocTest<GameBloc, GameState>(
      'AI回合应该忽略统一棋盘位置事件',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(currentPlayer: PieceType.black),
        mode: GameMode.pve,
        humanPlayer: PieceType.white,
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(
        const ActivateBoardPositionEvent(Position(0, 0)),
      ),
      expect: () => [],
    );

    blocTest<GameBloc, GameState>(
      '选中对方棋子不应该改变状态',
      build: () => GameBloc(
        gameEngine: gameEngine,
        moveValidator: moveValidator,
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(const SelectPieceEvent(Position(3, 3))), // 白方棋子
      expect: () => [],
    );

    blocTest<GameBloc, GameState>(
      '取消选中应该清除选中状态',
      build: () => GameBloc(
        gameEngine: gameEngine,
        moveValidator: moveValidator,
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        selectedPiece: const Position(0, 0),
        validMoves: const [Position(0, 1), Position(1, 0)],
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(const DeselectPieceEvent()),
      expect: () => [
        isA<GamePlaying>()
            .having((s) => s.selectedPiece, 'selectedPiece', null)
            .having((s) => s.validMoves.length, 'validMoves', 0),
      ],
    );

    blocTest<GameBloc, GameState>(
      '合法移动应该更新棋盘状态',
      build: () {
        when(() => moveValidator.isValidMove(any(), any(), any()))
            .thenReturn(true);

        final newBoard = BoardState.initial().movePiece(
          const Position(0, 0),
          const Position(0, 1),
        );

        when(() => gameEngine.executeMove(any(), any(), any())).thenReturn(
          MoveResult(
            success: true,
            move: Move.now(
              from: const Position(0, 0),
              to: const Position(0, 1),
              player: PieceType.black,
            ),
            newBoard: newBoard,
          ),
        );

        return GameBloc(
          gameEngine: gameEngine,
          moveValidator: moveValidator,
          audioCoordinator: audioCoordinator,
          storageService: storageService,
        );
      },
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        selectedPiece: const Position(0, 0),
        validMoves: const [Position(0, 1)],
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(
        const MovePieceEvent(
          from: Position(0, 0),
          to: Position(0, 1),
        ),
      ),
      expect: () => [
        isA<GamePlaying>()
            .having((s) => s.selectedPiece, 'selectedPiece', null)
            .having((s) => s.moveHistory.length, 'moveHistory', 1)
            .having(
              (s) => s.lastMove?.from,
              'lastMove.from',
              const Position(0, 0),
            )
            .having((s) => s.lastMove?.to, 'lastMove.to', const Position(0, 1)),
      ],
      verify: (_) {
        verify(
          () => moveValidator.isValidMove(
            any(),
            const Position(0, 0),
            const Position(0, 1),
          ),
        ).called(1);
        verify(
          () => gameEngine.executeMove(
            any(),
            const Position(0, 0),
            const Position(0, 1),
          ),
        ).called(1);
        verify(() => audioCoordinator.onGameEvent(audio.GameEvent.pieceMoved))
            .called(1);
      },
    );

    blocTest<GameBloc, GameState>(
      '非法移动不应该改变状态',
      build: () {
        when(() => moveValidator.isValidMove(any(), any(), any()))
            .thenReturn(false);

        return GameBloc(
          gameEngine: gameEngine,
          moveValidator: moveValidator,
          audioCoordinator: audioCoordinator,
          storageService: storageService,
        );
      },
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        selectedPiece: const Position(0, 0),
        validMoves: const [Position(0, 1)],
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(
        const MovePieceEvent(
          from: Position(0, 0),
          to: Position(3, 3),
        ),
      ),
      expect: () => [],
    );

    blocTest<GameBloc, GameState>(
      '吃子移动应该播放吃子音效',
      build: () {
        when(() => moveValidator.isValidMove(any(), any(), any()))
            .thenReturn(true);

        final newBoard = BoardState.initial().movePiece(
          const Position(0, 0),
          const Position(0, 1),
        );

        when(() => gameEngine.executeMove(any(), any(), any())).thenReturn(
          MoveResult(
            success: true,
            move: Move.now(
              from: const Position(0, 0),
              to: const Position(0, 1),
              player: PieceType.black,
            ),
            newBoard: newBoard,
            captured: const Position(3, 3),
          ),
        );

        return GameBloc(
          gameEngine: gameEngine,
          moveValidator: moveValidator,
          audioCoordinator: audioCoordinator,
          storageService: storageService,
        );
      },
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        selectedPiece: const Position(0, 0),
        validMoves: const [Position(0, 1)],
        moveHistory: const [],
      ),
      act: (bloc) => bloc.add(
        const MovePieceEvent(
          from: Position(0, 0),
          to: Position(0, 1),
        ),
      ),
      skip: 0,
      verify: (_) {
        verify(
          () => audioCoordinator.onGameEvent(
            audio.GameEvent.pieceCaptured,
            data: any(named: 'data'),
          ),
        ).called(1);
      },
    );

    blocTest<GameBloc, GameState>(
      '有效落子应该把连续未吃子计数同步回公开状态',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial()
            .setPiece(const Position(0, 1), PieceType.black)
            .setPiece(const Position(2, 1), PieceType.black)
            .setPiece(const Position(3, 1), PieceType.white),
        mode: GameMode.pvp,
        moveHistory: const [],
        noCapturePlyCount: 49,
      ),
      act: (bloc) => bloc.add(
        const MovePieceEvent(
          from: Position(0, 1),
          to: Position(1, 1),
        ),
      ),
      expect: () => [
        isA<GamePlaying>()
            .having(
              (state) => state.noCapturePlyCount,
              'noCapturePlyCount',
              0,
            )
            .having(
              (state) => state.lastMove!.captureCount,
              'captureCount',
              1,
            ),
      ],
    );

    blocTest<GameBloc, GameState>(
      '每次有效落子后自动覆盖单槽存档',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        moveHistory: const [],
        firstPlayer: PieceType.black,
      ),
      act: (bloc) => bloc.add(
        const MovePieceEvent(
          from: Position(0, 0),
          to: Position(0, 1),
        ),
      ),
      expect: () => [isA<GamePlaying>()],
      verify: (_) {
        final captured = verify(
          () => storageService.saveGame(captureAny()),
        ).captured.single as GameSave;
        expect(captured.moveHistory, hasLength(1));
        expect(captured.currentPlayer, 'white');
        expect(captured.startingPlayer, 'black');
        expect(captured.noCapturePlyCount, 1);
      },
    );

    blocTest<GameBloc, GameState>(
      '回合到达60秒边界时当前行棋方立即判负',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () {
        final startedAt = DateTime.utc(2026, 8, 1, 12);
        return GamePlaying(
          boardState: BoardState.initial(),
          mode: GameMode.pvp,
          moveHistory: const [],
          turnClock: TurnClock.started(startedAt),
        );
      },
      act: (bloc) => bloc.add(
        TurnClockTickEvent(DateTime.utc(2026, 8, 1, 12, 1)),
      ),
      expect: () => [
        isA<GameOver>()
            .having(
              (state) => state.gameResult!.status,
              'status',
              GameStatus.timeout,
            )
            .having(
              (state) => state.gameResult!.winner,
              'winner',
              PieceType.white,
            ),
      ],
      verify: (_) {
        verify(
          () => storageService.updateStatistics(
            isWin: true,
            isLoss: false,
            isDraw: false,
            moves: 0,
            captures: 0,
            difficulty: null,
          ),
        ).called(1);
        verify(() => storageService.deleteGameSave()).called(1);
        final record = verify(
          () => storageService.archiveGame(captureAny()),
        ).captured.single as GameRecord;
        expect(record.result.status, GameStatus.timeout);
        expect(record.result.winner, PieceType.white);
      },
    );

    blocTest<GameBloc, GameState>(
      '截止时刻落子必须先判超时且不改变棋盘',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
        now: () => DateTime.utc(2026, 8, 1, 12, 1),
      ),
      seed: () => GamePlaying(
        boardState: BoardState.initial(),
        mode: GameMode.pvp,
        moveHistory: const [],
        turnClock: TurnClock.started(DateTime.utc(2026, 8, 1, 12)),
      ),
      act: (bloc) => bloc.add(
        const MovePieceEvent(
          from: Position(0, 0),
          to: Position(0, 1),
        ),
      ),
      expect: () => [
        isA<GameOver>()
            .having(
              (state) => state.gameResult!.status,
              'status',
              GameStatus.timeout,
            )
            .having(
              (state) => state.boardState,
              'unchanged board',
              BoardState.initial(),
            ),
      ],
    );

    blocTest<GameBloc, GameState>(
      '终局存档恢复时立即结束并清除存档',
      setUp: () {
        final terminalBoard = BoardState.initial()
            .removePiece(const Position(1, 0))
            .removePiece(const Position(2, 0))
            .removePiece(const Position(3, 0));
        when(() => storageService.loadGame()).thenAnswer(
          (_) async => GameSave(
            id: 'terminal-save',
            saveTime: DateTime.utc(2026, 8, 1),
            boardState: BoardStateData.fromBoardState(terminalBoard),
            moveHistory: const [],
            currentPlayer: 'black',
            mode: 'pvp',
          ),
        );
      },
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      act: (bloc) => bloc.add(const LoadGameEvent()),
      expect: () => [
        isA<GameOver>()
            .having(
              (state) => state.gameResult!.winner,
              'winner',
              PieceType.white,
            )
            .having(
              (state) => state.gameResult!.endReason,
              'end reason',
              GameEndReason.pieceCount,
            ),
      ],
      verify: (_) {
        verify(() => storageService.deleteGameSave()).called(1);
      },
    );

    blocTest<GameBloc, GameState>(
      '离线对局进入后台时暂停回合时钟',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () {
        final startedAt = DateTime.utc(2026, 8, 1, 12);
        return GamePlaying(
          boardState: BoardState.initial(),
          mode: GameMode.pvp,
          moveHistory: const [],
          turnClock: TurnClock.started(startedAt),
        );
      },
      act: (bloc) => bloc.add(
        PauseTurnClockEvent(DateTime.utc(2026, 8, 1, 12, 0, 10)),
      ),
      expect: () => [
        isA<GamePlaying>()
            .having((state) => state.turnClock!.isPaused, 'isPaused', isTrue)
            .having(
              (state) => state.turnClock!.remainingAt(
                DateTime.utc(2026, 8, 1, 13),
              ),
              'remaining',
              const Duration(seconds: 50),
            ),
      ],
    );

    blocTest<GameBloc, GameState>(
      '撤销移动应该恢复到之前的状态',
      build: () {
        // Mock executeMove for replay
        when(() => gameEngine.executeMove(any(), any(), any()))
            .thenAnswer((invocation) {
          final board = invocation.positionalArguments[0] as BoardState;
          final from = invocation.positionalArguments[1] as Position;
          final to = invocation.positionalArguments[2] as Position;

          return MoveResult(
            success: true,
            move: Move.now(
              from: from,
              to: to,
              player: board.currentPlayer,
            ),
            newBoard: board.movePiece(from, to),
          );
        });

        return GameBloc(
          gameEngine: gameEngine,
          moveValidator: moveValidator,
          audioCoordinator: audioCoordinator,
          storageService: storageService,
        );
      },
      seed: () => GamePlaying(
        boardState: BoardState.initial().movePiece(
          const Position(0, 0),
          const Position(0, 1),
        ),
        mode: GameMode.pvp,
        moveHistory: [
          Move.now(
            from: const Position(0, 0),
            to: const Position(0, 1),
            player: PieceType.black,
          ),
        ],
        lastMove: Move.now(
          from: const Position(0, 0),
          to: const Position(0, 1),
          player: PieceType.black,
        ),
      ),
      act: (bloc) => bloc.add(const UndoMoveEvent()),
      expect: () => [
        isA<GamePlaying>()
            .having((s) => s.moveHistory.length, 'moveHistory', 0),
      ],
      verify: (_) {
        verify(
          () => audioCoordinator.onGameEvent(audio.GameEvent.buttonClicked),
        ).called(1);
      },
    );

    blocTest<GameBloc, GameState>(
      '白方先手对局撤销后恢复真实初始行棋方',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () {
        final move = Move.now(
          from: const Position(0, 3),
          to: const Position(0, 2),
          player: PieceType.white,
        );
        return GamePlaying(
          boardState: BoardState.initial(currentPlayer: PieceType.white)
              .movePiece(move.from, move.to)
              .switchPlayer(),
          mode: GameMode.pvp,
          moveHistory: [move],
          firstPlayer: PieceType.white,
        );
      },
      act: (bloc) => bloc.add(const UndoMoveEvent()),
      expect: () => [
        isA<GamePlaying>()
            .having(
              (state) => state.currentPlayer,
              'currentPlayer',
              PieceType.white,
            )
            .having(
              (state) => state.boardState.getPiece(const Position(0, 3)),
              'restoredPiece',
              PieceType.white,
            ),
      ],
    );

    blocTest<GameBloc, GameState>(
      'AI模式撤销两步后一次重做恢复两步',
      build: () => GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      seed: () {
        final blackMove = Move.now(
          from: const Position(0, 0),
          to: const Position(0, 1),
          player: PieceType.black,
        );
        final whiteMove = Move.now(
          from: const Position(0, 3),
          to: const Position(0, 2),
          player: PieceType.white,
        );
        return GamePlaying(
          boardState: BoardState.initial(),
          mode: GameMode.pve,
          moveHistory: const [],
          undoStack: [blackMove, whiteMove],
          firstPlayer: PieceType.black,
          humanPlayer: PieceType.black,
        );
      },
      act: (bloc) => bloc.add(const RedoMoveEvent()),
      expect: () => [
        isA<GamePlaying>()
            .having((state) => state.moveHistory.length, 'move count', 2)
            .having((state) => state.undoStack, 'redo stack', isEmpty),
      ],
    );

    test('恢复到AI回合的存档后会自动继续行棋', () async {
      final savedAt = DateTime.utc(2026, 8, 1, 12);
      final board = BoardState.initial(currentPlayer: PieceType.white);
      when(() => storageService.loadGame()).thenAnswer(
        (_) async => GameSave(
          id: 'ai-turn-save',
          saveTime: savedAt,
          startedAt: savedAt,
          boardState: BoardStateData.fromBoardState(board),
          moveHistory: const [],
          currentPlayer: 'white',
          startingPlayer: 'black',
          humanPlayer: 'black',
          mode: 'pve',
          aiDifficulty: 'easy',
        ),
      );
      final bloc = GameBloc(
        gameEngine: GameEngine(),
        moveValidator: MoveValidator(),
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      );

      bloc.add(const LoadGameEvent());
      final continued = await bloc.stream
          .where((state) => state is GamePlaying)
          .cast<GamePlaying>()
          .firstWhere((state) => state.moveHistory.length == 1)
          .timeout(const Duration(seconds: 5));

      expect(continued.currentPlayer, PieceType.black);
      expect(continued.moveHistory.single.player, PieceType.white);
      await bloc.close();
    });

    blocTest<GameBloc, GameState>(
      '设置变更应该更新音频服务',
      build: () => GameBloc(
        gameEngine: gameEngine,
        moveValidator: moveValidator,
        audioCoordinator: audioCoordinator,
        storageService: storageService,
      ),
      act: (bloc) => bloc.add(
        const SettingsChangedEvent(soundEnabled: false),
      ),
      verify: (_) {
        verify(() => audioCoordinator.updateSettings(any())).called(1);
      },
    );
  });
}

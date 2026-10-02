import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/bloc/game_bloc.dart';
import 'package:foursquare/bloc/game_event.dart';
import 'package:foursquare/bloc/game_state.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_result.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/services/voice/game_voice_session.dart';
import 'package:foursquare/ui/screens/game_page.dart';
import 'package:mocktail/mocktail.dart';

final class _MockGameBloc extends MockBloc<GameEvent, GameState>
    implements GameBloc {}

final class _FakeGameEvent extends Fake implements GameEvent {}

void main() {
  setUpAll(() => registerFallbackValue(_FakeGameEvent()));

  late _MockGameBloc bloc;

  setUp(() {
    bloc = _MockGameBloc();
    when(() => bloc.add(any())).thenReturn(null);
  });

  test('production voice constructor is side-effect free', () {
    expect(
      GamePage.voice(
        mode: GameMode.pve,
        aiDifficulty: 'easy',
      ),
      isA<GamePage>(),
    );
  });

  testWidgets('ordinary game omits voice UI when capability is not injected',
      (tester) async {
    _usePortraitViewport(tester);
    final state = _playing();
    _stubState(bloc, state);

    await tester.pumpWidget(_app(bloc: bloc, child: const GamePageView()));

    expect(find.byKey(const Key('game-voice-panel')), findsNothing);
  });

  testWidgets('PVE disclosure creates the session only after explicit action',
      (tester) async {
    _usePortraitViewport(tester);
    final state = _playing();
    final session = _FakeGameVoiceSession();
    final expectedBloc = bloc;
    var factoryCalls = 0;
    PieceType? actualControlledPlayer;
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) {
            factoryCalls += 1;
            expect(bloc, same(expectedBloc));
            actualControlledPlayer = controlledPlayer;
            return session;
          },
        ),
      ),
    );

    expect(find.byKey(const Key('game-voice-disclosure')), findsOneWidget);
    expect(factoryCalls, 0);

    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();

    expect(factoryCalls, 1);
    expect(actualControlledPlayer, PieceType.black);
    expect(session.enableCalls, 1);
    expect(find.byKey(const Key('game-voice-listen')), findsOneWidget);
  });

  testWidgets('PVP never exposes an ambiguous controlled-side voice panel',
      (tester) async {
    _usePortraitViewport(tester);
    final state = _playing(mode: GameMode.pvp);
    var factoryCalls = 0;
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) {
            factoryCalls += 1;
            return _FakeGameVoiceSession();
          },
        ),
      ),
    );

    expect(find.byKey(const Key('game-voice-panel')), findsNothing);
    expect(factoryCalls, 0);
  });

  testWidgets('restored PVE capability uses the human side from loaded state',
      (tester) async {
    _usePortraitViewport(tester);
    final state = GamePlaying(
      boardState: BoardState.initial(currentPlayer: PieceType.white),
      mode: GameMode.pve,
      humanPlayer: PieceType.white,
      firstPlayer: PieceType.black,
    );
    PieceType? actualControlledPlayer;
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) {
            actualControlledPlayer = controlledPlayer;
            return _FakeGameVoiceSession();
          },
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();

    expect(actualControlledPlayer, PieceType.white);
  });

  testWidgets('AI turn keeps disclosure passive and cannot create a session',
      (tester) async {
    _usePortraitViewport(tester);
    final state = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
    );
    var factoryCalls = 0;
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) {
            factoryCalls += 1;
            return _FakeGameVoiceSession();
          },
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();
    expect(factoryCalls, 0);
  });

  testWidgets('stale human-turn UI rechecks BLoC authority before setup',
      (tester) async {
    _usePortraitViewport(tester);
    final humanTurn = _playing();
    var latestState = humanTurn;
    var factoryCalls = 0;
    _stubState(bloc, humanTurn);
    when(() => bloc.state).thenAnswer((_) => latestState);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) {
            factoryCalls += 1;
            return _FakeGameVoiceSession();
          },
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));

    latestState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
    );
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();

    expect(factoryCalls, 0);
  });

  testWidgets('authoritative terminal state keeps active audio available', (
    tester,
  ) async {
    _usePortraitViewport(tester);
    GameState currentState = _playing();
    final states = StreamController<GameState>();
    final session = _FakeGameVoiceSession();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(bloc, states.stream, initialState: currentState);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) =>
              session,
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();

    currentState = GameOver.fromPlaying(
      _playing(),
      GameResult.blackWin(
        reason: 'test',
        moveCount: 1,
        duration: const Duration(seconds: 1),
      ),
    );
    states.add(currentState);
    await tester.pump();

    expect(session.availability, [true]);
    await states.close();
  });

  testWidgets('failed result speech exposes replay without another listen', (
    tester,
  ) async {
    _usePortraitViewport(tester);
    final state = _playing();
    final session = _FakeGameVoiceSession();
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) =>
              session,
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();

    session.emitAwaitingReplay();
    await tester.pump();
    final replay = find.byKey(const Key('game-voice-replay'));
    expect(replay, findsOneWidget);
    await tester.tap(replay);
    await tester.pump();

    expect(session.replayCalls, 1);
    expect(session.listenCalls, 0);
  });

  testWidgets('lifecycle updates voice availability and keeps clock events',
      (tester) async {
    _usePortraitViewport(tester);
    final state = _playing();
    final session = _FakeGameVoiceSession();
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) =>
              session,
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(session.availability, [false, true]);
    verify(() => bloc.add(any(that: isA<PauseTurnClockEvent>()))).called(1);
    verify(() => bloc.add(any(that: isA<ResumeTurnClockEvent>()))).called(1);
  });

  testWidgets('an inactive state interrupts active voice and pauses the clock',
      (tester) async {
    _usePortraitViewport(tester);
    final state = _playing();
    final session = _FakeGameVoiceSession();
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) =>
              session,
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(session.availability, [false]);
    verify(() => bloc.add(any(that: isA<PauseTurnClockEvent>()))).called(1);
  });

  testWidgets('voice panel disposes once and fits compact large-text layout',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final state = _playing();
    final session = _FakeGameVoiceSession();
    _stubState(bloc, state);

    await tester.pumpWidget(
      _app(
        bloc: bloc,
        child: GamePageView(
          voiceSessionFactory: ({required bloc, required controlledPlayer}) =>
              session,
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('game-voice-enable')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('game-voice-enable')));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(session.disposeCalls, 1);
  });
}

void _usePortraitViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _stubState(_MockGameBloc bloc, GameState state) {
  when(() => bloc.state).thenReturn(state);
  whenListen(
    bloc,
    const Stream<GameState>.empty(),
    initialState: state,
  );
}

Widget _app({required GameBloc bloc, required Widget child}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: BlocProvider<GameBloc>.value(value: bloc, child: child),
  );
}

GamePlaying _playing({
  GameMode mode = GameMode.pve,
  PieceType currentPlayer = PieceType.black,
  bool isAIThinking = false,
}) {
  return GamePlaying(
    boardState: BoardState.initial(currentPlayer: currentPlayer),
    mode: mode,
    humanPlayer: mode == GameMode.pve ? PieceType.black : null,
    firstPlayer: PieceType.black,
    isAIThinking: isAIThinking,
  );
}

final class _FakeGameVoiceSession implements GameVoiceSession {
  final StreamController<VoiceInteractionState> _states =
      StreamController<VoiceInteractionState>.broadcast();
  VoiceInteractionState _state =
      const VoiceInteractionState(VoiceInteractionPhase.disabled);
  int enableCalls = 0;
  int listenCalls = 0;
  int replayCalls = 0;
  int disposeCalls = 0;
  final List<bool> availability = [];

  @override
  bool get canAcceptInput => true;

  @override
  VoiceInteractionState get state => _state;

  @override
  Stream<VoiceInteractionState> get states => _states.stream;

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    await _states.close();
  }

  @override
  Future<void> enableAfterDisclosure() async {
    enableCalls += 1;
    _emit(const VoiceInteractionState(VoiceInteractionPhase.ready));
  }

  @override
  Future<void> listenOnce() async {
    listenCalls += 1;
  }

  @override
  Future<void> replayPendingReply() async {
    replayCalls += 1;
  }

  @override
  Future<void> updateAvailability({required bool appIsActive}) async {
    availability.add(appIsActive);
  }

  void _emit(VoiceInteractionState state) {
    _state = state;
    _states.add(state);
  }

  void emitAwaitingReplay() {
    _emit(
      const VoiceInteractionState(
        VoiceInteractionPhase.awaitingReplay,
      ),
    );
  }
}

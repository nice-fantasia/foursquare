import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/bloc/game_bloc.dart';
import 'package:foursquare/bloc/game_event.dart';
import 'package:foursquare/bloc/game_state.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_result.dart';
import 'package:foursquare/models/move.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/services/voice/game_voice_session.dart';
import 'package:foursquare/services/voice/voice_ports.dart';
import 'package:mocktail/mocktail.dart';

final class _MockGameBloc extends MockBloc<GameEvent, GameState>
    implements GameBloc {}

final class _FakeGameEvent extends Fake implements GameEvent {}

void main() {
  setUpAll(() => registerFallbackValue(_FakeGameEvent()));

  late _MockGameBloc bloc;
  late _PermissionPort permission;
  late _RecognitionPort recognition;
  late _SynthesisPort synthesis;

  setUp(() {
    bloc = _MockGameBloc();
    permission = _PermissionPort();
    recognition = _RecognitionPort();
    synthesis = _SynthesisPort();
    when(() => bloc.add(any())).thenReturn(null);
  });

  BlocGameVoiceSession createSession(GameState state) {
    when(() => bloc.state).thenReturn(state);
    return BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
  }

  test('construction is passive until disclosure is accepted', () async {
    final session = createSession(_playing());

    expect(session.state.phase, VoiceInteractionPhase.disabled);
    expect(permission.checkCalls, 0);
    expect(recognition.initializeCalls, 0);
    expect(synthesis.initializeCalls, 0);

    await session.dispose();
  });

  test('disclosure enables ports only during the controlled PVE turn',
      () async {
    final session = createSession(_playing());

    await session.enableAfterDisclosure();

    expect(session.state.phase, VoiceInteractionPhase.ready);
    expect(permission.checkCalls, 1);
    expect(recognition.initializeCalls, 1);
    expect(synthesis.initializeCalls, 1);
    await session.dispose();
  });

  test('AI turn cannot request permission or initialize voice ports', () async {
    final session = createSession(
      _playing(currentPlayer: PieceType.white, isAIThinking: true),
    );

    await session.enableAfterDisclosure();

    expect(session.state.phase, VoiceInteractionPhase.disabled);
    expect(permission.checkCalls, 0);
    expect(recognition.initializeCalls, 0);
    expect(synthesis.initializeCalls, 0);
    await session.dispose();
  });

  test('backgrounding during permission prevents later port initialization',
      () async {
    permission.holdNextCheck();
    final session = createSession(_playing());

    final enabling = session.enableAfterDisclosure();
    expect(session.state.phase, VoiceInteractionPhase.requestingPermission);
    await session.updateAvailability(appIsActive: false);
    permission.completeCheck(VoicePermissionStatus.granted);
    await enabling;

    expect(session.state.phase, VoiceInteractionPhase.interrupted);
    expect(recognition.initializeCalls, 0);
    expect(synthesis.initializeCalls, 0);
    await session.dispose();
  });

  test('resuming a disclosed permission flow safely restarts setup', () async {
    permission.holdNextCheck();
    final session = createSession(_playing());

    final enabling = session.enableAfterDisclosure();
    await session.updateAvailability(appIsActive: false);
    final resuming = session.updateAvailability(appIsActive: true);
    permission.completeCheck(VoicePermissionStatus.granted);
    await Future.wait([enabling, resuming]);

    expect(session.state.phase, VoiceInteractionPhase.ready);
    expect(permission.checkCalls, 2);
    expect(recognition.initializeCalls, 1);
    expect(synthesis.initializeCalls, 1);
    await session.dispose();
  });

  test('AI turn during recognition setup prevents synthesis initialization',
      () async {
    recognition.holdNextInitialize();
    var currentState = _playing();
    when(() => bloc.state).thenAnswer((_) => currentState);
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );

    final enabling = session.enableAfterDisclosure();
    await Future<void>.delayed(Duration.zero);
    expect(session.state.phase, VoiceInteractionPhase.initializing);
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
    );
    await session.updateAvailability(appIsActive: true);
    recognition.completeInitialize(true);
    await enabling;

    expect(session.state.phase, VoiceInteractionPhase.interrupted);
    expect(synthesis.initializeCalls, 0);
    await session.dispose();
  });

  test('a final position command enters the source-neutral BLoC event path',
      () async {
    final session = createSession(_playing());
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('A1');
    await Future<void>.delayed(Duration.zero);

    verify(
      () => bloc.add(
        const ActivateBoardPositionEvent(Position(0, 0)),
      ),
    ).called(1);
    await session.dispose();
  });

  test('a full move command can never gain AI authorization', () async {
    final session = createSession(_playing());
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final captured =
        verify(() => bloc.add(captureAny())).captured.single as MovePieceEvent;
    expect(captured.from, const Position(0, 0));
    expect(captured.to, const Position(0, 1));
    expect(captured.isAIMove, isFalse);
    await session.dispose();
  });

  test('a full move speaks only after the authoritative commit', () async {
    var currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    expect(synthesis.spokenTexts, isEmpty);
    verify(() => bloc.add(any(that: isA<MovePieceEvent>()))).called(1);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
      moveHistory: [committedMove],
      lastMove: committedMove,
    );
    authoritativeStates.add(currentState);
    await session.updateAvailability(appIsActive: true);
    await Future<void>.delayed(Duration.zero);

    expect(synthesis.spokenTexts, ['移动成功']);
    expect(recognition.listenCalls, 1);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('AI updates cannot interrupt committed-result playback', () async {
    GameState currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();
    synthesis.holdNextSpeak();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
      moveHistory: [committedMove],
      lastMove: committedMove,
    );
    authoritativeStates.add(currentState);
    await Future<void>.delayed(Duration.zero);
    expect(session.state.phase, VoiceInteractionPhase.speaking);

    await session.updateAvailability(appIsActive: true);
    expect(synthesis.stopCalls, 0);
    expect(session.state.phase, VoiceInteractionPhase.speaking);

    synthesis.completeSpeak();
    await Future<void>.delayed(Duration.zero);
    expect(synthesis.spokenTexts, ['移动成功']);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('a failed committed-result speech can replay without another move',
      () async {
    GameState currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();
    synthesis.failNextSpeak = true;

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
      moveHistory: [committedMove],
      lastMove: committedMove,
    );
    authoritativeStates.add(currentState);
    await session.updateAvailability(appIsActive: true);
    await Future<void>.delayed(Duration.zero);
    expect(session.state.phase, VoiceInteractionPhase.awaitingReplay);

    await session.replayPendingReply();
    await Future<void>.delayed(Duration.zero);

    verify(() => bloc.add(any(that: isA<MovePieceEvent>()))).called(1);
    expect(synthesis.spokenTexts, ['移动成功', '移动成功']);
    expect(recognition.listenCalls, 1);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('an interrupted committed result remains replayable after resume',
      () async {
    GameState currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();
    synthesis.holdNextSpeak();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
      moveHistory: [committedMove],
      lastMove: committedMove,
    );
    authoritativeStates.add(currentState);
    await Future<void>.delayed(Duration.zero);
    expect(session.state.phase, VoiceInteractionPhase.speaking);

    await session.updateAvailability(appIsActive: false);
    expect(session.state.phase, VoiceInteractionPhase.awaitingReplay);
    synthesis.completeSpeak();
    await Future<void>.delayed(Duration.zero);
    await session.updateAvailability(appIsActive: true);
    expect(session.state.phase, VoiceInteractionPhase.awaitingReplay);

    await session.replayPendingReply();
    await Future<void>.delayed(Duration.zero);
    verify(() => bloc.add(any(that: isA<MovePieceEvent>()))).called(1);
    expect(synthesis.spokenTexts, ['移动成功', '移动成功']);
    expect(recognition.listenCalls, 1);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('restarting after terminal speech failure discards the old result',
      () async {
    GameState currentState = _playing(matchId: 'match-1');
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();
    synthesis.failNextSpeak = true;

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = GameOver(
      boardState: BoardState.initial(currentPlayer: PieceType.white),
      mode: GameMode.pve,
      gameResult: GameResult.blackWin(
        reason: 'test',
        moveCount: 1,
        duration: const Duration(seconds: 1),
      ),
      moveHistory: [committedMove],
      lastMove: committedMove,
      firstPlayer: PieceType.black,
      humanPlayer: PieceType.black,
      matchId: 'match-1',
    );
    authoritativeStates.add(currentState);
    await session.updateAvailability(appIsActive: true);
    await Future<void>.delayed(Duration.zero);
    expect(session.state.phase, VoiceInteractionPhase.awaitingReplay);

    currentState = _playing(matchId: 'match-2');
    when(() => bloc.state).thenReturn(currentState);
    authoritativeStates.add(currentState);
    await Future<void>.delayed(Duration.zero);
    await session.updateAvailability(appIsActive: true);
    await session.replayPendingReply();
    await Future<void>.delayed(Duration.zero);

    expect(synthesis.spokenTexts, ['移动成功，你获胜了']);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('restarting while an old result is speaking stops that result',
      () async {
    GameState currentState = _playing(matchId: 'match-1');
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();
    synthesis.holdNextSpeak();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
      moveHistory: [committedMove],
      lastMove: committedMove,
      matchId: 'match-1',
    );
    authoritativeStates.add(currentState);
    await Future<void>.delayed(Duration.zero);
    expect(session.state.phase, VoiceInteractionPhase.speaking);

    currentState = _playing(matchId: 'match-2');
    when(() => bloc.state).thenReturn(currentState);
    await session.updateAvailability(appIsActive: true);

    expect(synthesis.stopCalls, 1);
    expect(session.state.phase, VoiceInteractionPhase.ready);
    synthesis.completeSpeak();
    await Future<void>.delayed(Duration.zero);
    await session.replayPendingReply();
    expect(synthesis.spokenTexts, ['移动成功']);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('an authoritative double capture speaks the complete result', () async {
    var currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      capturedPieces: const [Position(1, 1), Position(2, 2)],
      timestamp: DateTime.utc(2026),
    );
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
      moveHistory: [committedMove],
      lastMove: committedMove,
    );
    authoritativeStates.add(currentState);
    await session.updateAvailability(appIsActive: true);
    await Future<void>.delayed(Duration.zero);

    expect(synthesis.spokenTexts, ['移动成功，吃掉两枚棋子']);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('an authoritative terminal move speaks the controlled result', () async {
    GameState currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = GameOver(
      boardState: BoardState.initial(currentPlayer: PieceType.white),
      mode: GameMode.pve,
      gameResult: GameResult.blackWin(
        reason: 'test',
        moveCount: 1,
        duration: const Duration(seconds: 1),
      ),
      moveHistory: [committedMove],
      lastMove: committedMove,
      firstPlayer: PieceType.black,
      humanPlayer: PieceType.black,
    );
    authoritativeStates.add(currentState);
    await session.updateAvailability(appIsActive: true);
    await Future<void>.delayed(Duration.zero);

    expect(synthesis.spokenTexts, ['移动成功，你获胜了']);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('an uncommitted move never speaks a false success', () async {
    final currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenReturn(currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
      committedOutcomeTimeout: const Duration(milliseconds: 10),
    );
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    verify(() => bloc.add(any(that: isA<MovePieceEvent>()))).called(1);
    expect(synthesis.spokenTexts, isEmpty);
    expect(session.state.phase, VoiceInteractionPhase.ready);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('backgrounding while a move commits never speaks in the background',
      () async {
    GameState currentState = _playing();
    final authoritativeStates = StreamController<GameState>();
    when(() => bloc.state).thenAnswer((_) => currentState);
    whenListen(
      bloc,
      authoritativeStates.stream,
      initialState: currentState,
    );
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(Duration.zero);
    await session.updateAvailability(appIsActive: false);

    final committedMove = Move(
      from: const Position(0, 0),
      to: const Position(0, 1),
      player: PieceType.black,
      timestamp: DateTime.utc(2026),
    );
    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
      moveHistory: [committedMove],
      lastMove: committedMove,
    );
    authoritativeStates.add(currentState);
    await Future<void>.delayed(Duration.zero);

    expect(synthesis.spokenTexts, isEmpty);
    expect(session.state.phase, VoiceInteractionPhase.interrupted);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('disposing cancels an outstanding committed-move waiter', () async {
    final currentState = _playing();
    final waiterCancelled = Completer<void>();
    final authoritativeStates = StreamController<GameState>(
      onCancel: () {
        if (!waiterCancelled.isCompleted) waiterCancelled.complete();
      },
    );
    when(() => bloc.state).thenReturn(currentState);
    when(() => bloc.stream).thenAnswer((_) => authoritativeStates.stream);
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
      committedOutcomeTimeout: const Duration(hours: 1),
    );
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    verify(() => bloc.add(any(that: isA<MovePieceEvent>()))).called(1);
    await session.dispose();

    await waiterCancelled.future.timeout(const Duration(milliseconds: 100));
    await authoritativeStates.close();
  });

  test('a dispatch failure cancels the committed-move waiter', () async {
    final currentState = _playing();
    final waiterCancelled = Completer<void>();
    final authoritativeStates = StreamController<GameState>(
      onCancel: () {
        if (!waiterCancelled.isCompleted) waiterCancelled.complete();
      },
    );
    when(() => bloc.state).thenReturn(currentState);
    when(() => bloc.stream).thenAnswer((_) => authoritativeStates.stream);
    when(() => bloc.add(any())).thenThrow(StateError('bloc closed'));
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
      committedOutcomeTimeout: const Duration(hours: 1),
    );
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('从A1移动到A2');
    await waiterCancelled.future.timeout(const Duration(milliseconds: 100));
    await Future<void>.delayed(Duration.zero);

    expect(synthesis.spokenTexts, isEmpty);
    expect(session.state.failure, VoicePortFailure.commandFailed);
    await authoritativeStates.close();
    await session.dispose();
  });

  test('a late final result after the AI turn begins cannot enter the BLoC',
      () async {
    var currentState = _playing();
    when(() => bloc.state).thenAnswer((_) => currentState);
    final session = BlocGameVoiceSession(
      bloc: bloc,
      controlledPlayer: PieceType.black,
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
    );
    await session.enableAfterDisclosure();
    await session.listenOnce();

    currentState = _playing(
      currentPlayer: PieceType.white,
      isAIThinking: true,
    );
    await session.updateAvailability(appIsActive: true);
    recognition.emitFinal('A1');
    await Future<void>.delayed(Duration.zero);

    verifyNever(() => bloc.add(any()));
    await session.dispose();
  });

  test('ordinary-game control commands do not invent unsupported semantics',
      () async {
    final session = createSession(_playing());
    await session.enableAfterDisclosure();

    await session.listenOnce();
    recognition.emitFinal('暂停');
    await Future<void>.delayed(Duration.zero);

    verifyNever(() => bloc.add(any()));
    await session.dispose();
  });

  test('backgrounding interrupts audio and never auto-opens the microphone',
      () async {
    final session = createSession(_playing());
    await session.enableAfterDisclosure();
    await session.listenOnce();
    expect(recognition.listenCalls, 1);

    await session.updateAvailability(appIsActive: false);

    expect(recognition.stopCalls, 1);
    expect(session.state.phase, VoiceInteractionPhase.interrupted);
    await session.updateAvailability(appIsActive: true);
    expect(session.state.phase, VoiceInteractionPhase.ready);
    expect(recognition.listenCalls, 1);
    await session.dispose();
  });

  test('PVP and finished games are never voice-controllable', () async {
    final pvp = createSession(_playing(mode: GameMode.pvp));
    expect(pvp.canAcceptInput, isFalse);
    await pvp.dispose();

    final finished = createSession(
      GameOver.fromPlaying(
        _playing(),
        const GameResult(
          status: GameStatus.draw,
          winner: null,
          reason: 'test',
          moveCount: 0,
          duration: Duration.zero,
        ),
      ),
    );
    expect(finished.canAcceptInput, isFalse);
    await finished.dispose();
  });
}

GamePlaying _playing({
  GameMode mode = GameMode.pve,
  PieceType currentPlayer = PieceType.black,
  bool isAIThinking = false,
  List<Move> moveHistory = const [],
  Move? lastMove,
  String matchId = 'match',
}) {
  return GamePlaying(
    boardState: BoardState.initial(currentPlayer: currentPlayer),
    mode: mode,
    humanPlayer: mode == GameMode.pve ? PieceType.black : null,
    firstPlayer: PieceType.black,
    isAIThinking: isAIThinking,
    moveHistory: moveHistory,
    lastMove: lastMove,
    matchId: matchId,
  );
}

final class _PermissionPort implements MicrophonePermissionPort {
  int checkCalls = 0;
  Completer<VoicePermissionStatus>? _checkCompleter;

  void holdNextCheck() {
    _checkCompleter = Completer<VoicePermissionStatus>();
  }

  void completeCheck(VoicePermissionStatus status) {
    _checkCompleter?.complete(status);
    _checkCompleter = null;
  }

  @override
  Future<VoicePermissionStatus> check() async {
    checkCalls += 1;
    final completer = _checkCompleter;
    if (completer != null) {
      return completer.future;
    }
    return VoicePermissionStatus.granted;
  }

  @override
  Future<VoicePermissionStatus> request() async =>
      VoicePermissionStatus.granted;
}

final class _RecognitionPort implements VoiceRecognitionPort {
  int initializeCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  Completer<bool>? _initializeCompleter;
  void Function(VoiceRecognitionSample sample)? _onSample;

  void holdNextInitialize() {
    _initializeCompleter = Completer<bool>();
  }

  void completeInitialize(bool result) {
    _initializeCompleter?.complete(result);
    _initializeCompleter = null;
  }

  @override
  Future<void> dispose() async {}

  void emitFinal(String text) {
    _onSample!(
      VoiceRecognitionSample(
        text: text,
        isFinal: true,
        confidence: 1,
      ),
    );
  }

  @override
  Future<bool> initialize() async {
    initializeCalls += 1;
    final completer = _initializeCompleter;
    if (completer != null) {
      return completer.future;
    }
    return true;
  }

  @override
  Future<void> listenOnce({
    required void Function(VoiceRecognitionSample sample) onSample,
    required void Function(VoicePortFailure failure) onFailure,
  }) async {
    listenCalls += 1;
    _onSample = onSample;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }
}

final class _SynthesisPort implements VoiceSynthesisPort {
  int initializeCalls = 0;
  int stopCalls = 0;
  bool failNextSpeak = false;
  final List<String> spokenTexts = [];
  Completer<void>? _speakCompleter;

  void holdNextSpeak() {
    _speakCompleter = Completer<void>();
  }

  void completeSpeak() {
    _speakCompleter?.complete();
    _speakCompleter = null;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> initialize() async {
    initializeCalls += 1;
    return true;
  }

  @override
  Future<void> speak(String text) async {
    spokenTexts.add(text);
    if (failNextSpeak) {
      failNextSpeak = false;
      throw StateError('synthesis failed');
    }
    final completer = _speakCompleter;
    if (completer != null) await completer.future;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }
}

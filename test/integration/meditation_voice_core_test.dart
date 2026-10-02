import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/ai/voice_command_parser.dart';
import 'package:foursquare/ai/voice_game_intent.dart';
import 'package:foursquare/engine/capture_detector.dart';
import 'package:foursquare/meditation/meditation_intent_handler.dart';
import 'package:foursquare/meditation/meditation_session.dart';
import 'package:foursquare/meditation/meditation_session_controller.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_result.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/services/turn_clock.dart';
import 'package:foursquare/services/voice/voice_interaction_controller.dart';
import 'package:foursquare/services/voice/voice_ports.dart';

void main() {
  test('fake voice ports complete a human and AI turn without a screen',
      () async {
    final order = <String>[];
    final recognition = _ScriptRecognition(order);
    final synthesis = _RecordingSynthesis(order);
    final sessionController = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => DateTime.utc(2026, 8, 1, 12),
    );
    final handler = MeditationIntentHandler(
      controller: sessionController,
      aiPlayer: _SingleMoveAI(),
    );
    final voice = VoiceInteractionController(
      permission: _GrantedPermission(),
      recognition: recognition,
      synthesis: synthesis,
      interpret: VoiceGameIntentParser.parse,
      onIntent: (intent) async {
        final response = await handler.handle(intent);
        return VoiceInteractionReply(response.prompt.text);
      },
    );
    addTearDown(voice.dispose);

    await voice.enableAfterDisclosure();
    expect(await voice.announce(handler.openingPrompt().text), isTrue);
    final started = await handler.start();
    expect(await voice.announce(started.prompt.text), isTrue);
    expect(recognition.listenCalls, 0);

    await voice.listenOnce();
    recognition.emitFinal('横一竖一');
    await _waitUntilReady(voice, expectedSpeakCalls: 3, synthesis: synthesis);
    expect(sessionController.session.selectedPosition, const Position(0, 0));

    await voice.listenOnce();
    recognition.emitFinal('横一竖二');
    await _waitUntilReady(voice, expectedSpeakCalls: 4, synthesis: synthesis);

    expect(sessionController.session.moveHistory, hasLength(2));
    expect(sessionController.session.phase, MeditationSessionPhase.humanTurn);
    expect(recognition.listenCalls, 2);
    expect(synthesis.spoken.last, contains('您从横一竖一移动到横一竖二'));
    expect(synthesis.spoken.last, contains('对手从横一竖四移动到横一竖三'));
    expect(
      order.indexOf('recognition.stop.2'),
      lessThan(order.indexOf('synthesis.speak.4')),
    );
    expect(voice.state.toString(), isNot(contains('横一竖二')));
  });

  test('opening clock waits until a failed announcement is replayed', () async {
    final order = <String>[];
    final synthesis = _RecordingSynthesis(order)..failuresRemaining = 1;
    final sessionController = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => DateTime.utc(2026, 8, 1, 12),
    );
    final handler = MeditationIntentHandler(
      controller: sessionController,
      aiPlayer: _SingleMoveAI(),
    );
    final voice = VoiceInteractionController(
      permission: _GrantedPermission(),
      recognition: _ScriptRecognition(order),
      synthesis: synthesis,
      interpret: VoiceGameIntentParser.parse,
      onIntent: (_) => null,
    );
    addTearDown(voice.dispose);
    await voice.enableAfterDisclosure();

    expect(await voice.announce(handler.openingPrompt().text), isFalse);
    expect(sessionController.session.phase, MeditationSessionPhase.opening);
    expect(sessionController.session.turnClock, isNull);

    expect(await voice.replayPendingReply(), isTrue);
    await handler.start();

    expect(sessionController.session.phase, MeditationSessionPhase.humanTurn);
    expect(sessionController.session.turnClock, isNotNull);
  });

  test('fake voice ports narrate both captures from one authoritative move',
      () async {
    final order = <String>[];
    final recognition = _ScriptRecognition(order);
    final synthesis = _RecordingSynthesis(order);
    final now = DateTime.utc(2026, 8, 1, 12);
    final doubleCaptureBoard = BoardState.initial()
        .setPiece(const Position(0, 1), PieceType.black)
        .setPiece(const Position(1, 1), PieceType.empty)
        .setPiece(const Position(2, 1), PieceType.black)
        .setPiece(const Position(3, 1), PieceType.white)
        .setPiece(const Position(1, 2), PieceType.white)
        .setPiece(const Position(1, 3), PieceType.empty);
    final sessionController =
        MeditationSessionController.fromSnapshotForTesting(
      MeditationSession(
        matchId: 'voice-double-capture',
        startedAt: now,
        boardState: doubleCaptureBoard,
        firstPlayer: PieceType.black,
        humanPlayer: PieceType.black,
        aiDifficulty: AIDifficulty.easy,
        turnClock: TurnClock.started(now),
      ),
      now: () => now,
    );
    final handler = MeditationIntentHandler(
      controller: sessionController,
      aiPlayer: _GreedyDeterministicAI(),
    );
    final voice = VoiceInteractionController(
      permission: _GrantedPermission(),
      recognition: recognition,
      synthesis: synthesis,
      interpret: VoiceGameIntentParser.parse,
      onIntent: (intent) async {
        final response = await handler.handle(intent);
        return VoiceInteractionReply(response.prompt.text);
      },
    );
    addTearDown(voice.dispose);
    await voice.enableAfterDisclosure();
    final started = await handler.start();
    expect(await voice.announce(started.prompt.text), isTrue);

    await _sayMove(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      move: const AIMoveResult(
        from: Position(0, 1),
        to: Position(1, 1),
        score: 2,
      ),
    );

    expect(
      sessionController.session.moveHistory.first.capturedPieces,
      const [Position(3, 1), Position(1, 2)],
    );
    expect(synthesis.spoken.last, contains('横四竖二'));
    expect(synthesis.spoken.last, contains('横二竖三'));
    expect(synthesis.spoken.last, contains('2枚棋子'));
  });

  test('scripted voice ports complete a deterministic game to natural terminal',
      () async {
    final order = <String>[];
    final recognition = _ScriptRecognition(order);
    final synthesis = _RecordingSynthesis(order);
    var now = DateTime.utc(2026, 8, 1, 12);
    final sessionController = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    final ai = _GreedyDeterministicAI()..failuresRemaining = 1;
    final handler = MeditationIntentHandler(
      controller: sessionController,
      aiPlayer: ai,
    );
    final voice = VoiceInteractionController(
      permission: _GrantedPermission(),
      recognition: recognition,
      synthesis: synthesis,
      interpret: VoiceGameIntentParser.parse,
      onIntent: (intent) async {
        final response = await handler.handle(intent);
        return VoiceInteractionReply(response.prompt.text);
      },
    );
    addTearDown(voice.dispose);

    await voice.enableAfterDisclosure();
    expect(await voice.announce(handler.openingPrompt().text), isTrue);
    final started = await handler.start();
    expect(await voice.announce(started.prompt.text), isTrue);

    final initialRevision = sessionController.session.revision;
    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '我的棋子在哪',
    );
    expect(sessionController.session.revision, initialRevision);
    final piecePrompt = synthesis.spoken.last;
    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '重复一遍',
    );
    expect(synthesis.spoken.last, piecePrompt);
    for (final query in ['对方棋子在哪', '还剩几个', '可以走哪']) {
      await _say(
        voice,
        recognition: recognition,
        synthesis: synthesis,
        text: query,
      );
    }
    expect(sessionController.session.revision, initialRevision);

    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '横一竖一',
    );
    expect(sessionController.session.selectedPosition, const Position(0, 0));
    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '取消选择',
    );
    expect(sessionController.session.selectedPosition, isNull);

    final remainingBeforePause =
        sessionController.session.turnClock!.remainingAt(now);
    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '暂停',
    );
    expect(sessionController.session.phase, MeditationSessionPhase.paused);
    now = now.add(const Duration(minutes: 5));
    final pausedRevision = sessionController.session.revision;
    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '可以走哪',
    );
    expect(sessionController.session.revision, pausedRevision);
    expect(
      sessionController.session.turnClock!.remainingAt(now),
      remainingBeforePause,
    );
    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '继续',
    );
    expect(sessionController.session.phase, MeditationSessionPhase.humanTurn);

    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '退出',
    );
    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '取消退出',
    );
    expect(sessionController.session.gameResult, isNull);

    final firstMove = _chooseGreedyMove(sessionController.session.boardState);
    await _sayMove(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      move: firstMove,
    );
    expect(sessionController.session.moveHistory, hasLength(1));
    expect(sessionController.session.phase, MeditationSessionPhase.aiTurn);
    expect(synthesis.spoken.last, contains('重试'));

    await _say(
      voice,
      recognition: recognition,
      synthesis: synthesis,
      text: '重试',
    );
    expect(sessionController.session.moveHistory, hasLength(2));
    expect(sessionController.session.phase, MeditationSessionPhase.humanTurn);

    var humanTurns = 1;
    while (sessionController.session.gameResult == null) {
      if (humanTurns >= 16) {
        fail(
          'Deterministic game exceeded turn bound.\n'
          '${sessionController.session.boardState.toDebugString()}\n'
          'history=${sessionController.session.moveHistory}\n'
          'noCapture=${sessionController.session.noCapturePlyCount}',
        );
      }
      expect(
        sessionController.session.phase,
        MeditationSessionPhase.humanTurn,
      );
      final move = _chooseGreedyMove(sessionController.session.boardState);
      await _sayMove(
        voice,
        recognition: recognition,
        synthesis: synthesis,
        move: move,
      );
      humanTurns += 1;
    }

    final session = sessionController.session;
    expect(session.moveHistory, hasLength(15));
    expect(session.gameResult?.status, GameStatus.blackWin);
    expect(session.gameResult?.winner, PieceType.black);
    expect(session.gameResult?.endReason, GameEndReason.pieceCount);
    expect(session.boardState.getPieceCount(PieceType.black), 4);
    expect(session.boardState.getPieceCount(PieceType.white), 1);
    expect(
      session.moveHistory
          .where((move) => move.hasCapture)
          .expand((move) => move.capturedPieces),
      const [Position(0, 2), Position(1, 2), Position(2, 2)],
    );
    expect(session.turnClock, isNull);
    expect(synthesis.spoken.last, contains('横三竖三'));
    expect(synthesis.spoken.last, contains('您获胜'));

    final listenCallsAtTerminal = recognition.listenCalls;
    await voice.interrupt();
    await voice.listenOnce();
    expect(recognition.listenCalls, listenCallsAtTerminal);
    expect(voice.state.toString(), isNot(contains('横三竖三')));
  });
}

Future<void> _say(
  VoiceInteractionController voice, {
  required _ScriptRecognition recognition,
  required _RecordingSynthesis synthesis,
  required String text,
}) async {
  final expectedSpeakCalls = synthesis.spoken.length + 1;
  await voice.listenOnce();
  expect(voice.state.phase, VoiceInteractionPhase.listening);
  recognition.emitFinal(text);
  await _waitUntilReady(
    voice,
    expectedSpeakCalls: expectedSpeakCalls,
    synthesis: synthesis,
  );
}

Future<void> _sayMove(
  VoiceInteractionController voice, {
  required _ScriptRecognition recognition,
  required _RecordingSynthesis synthesis,
  required AIMoveResult move,
}) async {
  final from = VoiceCommandParser.formatPosition(move.from);
  final to = VoiceCommandParser.formatPosition(move.to);
  final command = '从$from移动到$to';
  expect(
    VoiceGameIntentParser.parse(command),
    VoiceMoveIntent(from: move.from, to: move.to),
  );
  await _say(
    voice,
    recognition: recognition,
    synthesis: synthesis,
    text: command,
  );
}

AIMoveResult _chooseGreedyMove(BoardState board) {
  final pieces = board.getAllPieces(board.currentPlayer)
    ..sort((left, right) {
      final row = left.y.compareTo(right.y);
      return row == 0 ? left.x.compareTo(right.x) : row;
    });
  AIMoveResult? best;
  var bestCaptureCount = -1;
  final detector = CaptureDetector();
  for (final from in pieces) {
    for (final to in from.getAdjacentPositions().where(board.isEmpty)) {
      final captures = detector.detectCaptures(
        board.movePiece(from, to),
        movedPiece: to,
        player: board.currentPlayer,
      );
      if (captures.length > bestCaptureCount) {
        bestCaptureCount = captures.length;
        best = AIMoveResult(from: from, to: to, score: captures.length);
      }
    }
  }
  if (best == null) {
    throw StateError('Current player has no legal move');
  }
  return best;
}

Future<void> _waitUntilReady(
  VoiceInteractionController voice, {
  required int expectedSpeakCalls,
  required _RecordingSynthesis synthesis,
}) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (voice.state.phase == VoiceInteractionPhase.ready &&
        synthesis.spoken.length == expectedSpeakCalls) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail(
    'Voice loop did not settle: state=${voice.state}, '
    'speakCalls=${synthesis.spoken.length}',
  );
}

final class _GrantedPermission implements MicrophonePermissionPort {
  @override
  Future<VoicePermissionStatus> check() async => VoicePermissionStatus.granted;

  @override
  Future<VoicePermissionStatus> request() async =>
      VoicePermissionStatus.granted;
}

final class _ScriptRecognition implements VoiceRecognitionPort {
  final List<String> order;
  int listenCalls = 0;
  int stopCalls = 0;
  void Function(VoiceRecognitionSample sample)? _onSample;
  bool _isListening = false;

  _ScriptRecognition(this.order);

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> listenOnce({
    required void Function(VoiceRecognitionSample sample) onSample,
    required void Function(VoicePortFailure failure) onFailure,
  }) async {
    if (_isListening) {
      throw StateError('Recognition sessions overlapped');
    }
    _isListening = true;
    listenCalls += 1;
    order.add('recognition.listen.$listenCalls');
    _onSample = onSample;
  }

  void emitFinal(String text) {
    _onSample?.call(
      VoiceRecognitionSample(
        text: text,
        confidence: 0.95,
        isFinal: true,
      ),
    );
  }

  @override
  Future<void> stop() async {
    _isListening = false;
    stopCalls += 1;
    order.add('recognition.stop.$stopCalls');
  }

  @override
  Future<void> dispose() async {}
}

final class _RecordingSynthesis implements VoiceSynthesisPort {
  final List<String> order;
  final List<String> spoken = [];
  int failuresRemaining = 0;
  bool _isSpeaking = false;

  _RecordingSynthesis(this.order);

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> speak(String text) async {
    if (_isSpeaking) {
      throw StateError('Synthesis sessions overlapped');
    }
    _isSpeaking = true;
    spoken.add(text);
    order.add('synthesis.speak.${spoken.length}');
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      _isSpeaking = false;
      throw StateError('synthetic TTS failure');
    }
    _isSpeaking = false;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
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
  String get description => 'Deterministic integration AI';
}

final class _GreedyDeterministicAI extends AIPlayer {
  int failuresRemaining = 0;

  _GreedyDeterministicAI() : super(AIDifficulty.easy);

  @override
  Future<AIMoveResult?> selectMove(
    BoardState board, {
    int noCapturePlyCount = 0,
  }) async {
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      return null;
    }
    return _chooseGreedyMove(board);
  }

  @override
  String get name => 'Greedy deterministic AI';

  @override
  String get description => 'Stable full-game integration policy';
}

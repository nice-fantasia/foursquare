import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/meditation/meditation_session.dart';
import 'package:foursquare/meditation/meditation_session_persistence.dart';
import 'package:foursquare/meditation/meditation_session_runtime.dart';
import 'package:foursquare/meditation/meditation_session_snapshot.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_record.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/services/voice/voice_ports.dart';
import 'package:foursquare/ui/screens/meditation/meditation_page.dart';

void main() {
  final now = DateTime.utc(2026, 8, 1, 12);

  Future<_Harness> pumpPage(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    Locale locale = const Locale('zh'),
    TextScaler textScaler = TextScaler.noScaling,
    Future<bool> Function(GameRecord record)? archiveCompletedGame,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final clock = _Clock(now);
    final runtime = await MeditationSessionRuntime.createNew(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiPlayer: _SingleMoveAI(),
      persistence: MeditationSessionPersistence(
        repository: _MemoryRepository(),
        now: clock.call,
      ),
      archiveCompletedGame: archiveCompletedGame ?? (_) async => true,
      now: clock.call,
    );
    final permission = _FakePermissionPort();
    final recognition = _FakeRecognitionPort();
    final synthesis = _FakeSynthesisPort();
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: MeditationPage(
            runtime: runtime,
            permission: permission,
            recognition: recognition,
            synthesis: synthesis,
            now: clock.call,
          ),
        ),
      ),
    );
    await tester.pump();
    return _Harness(runtime, permission, recognition, synthesis, clock);
  }

  Future<void> enableAndBegin(
    WidgetTester tester,
    _Harness harness,
  ) async {
    final enable = find.byKey(const Key('meditation-enable'));
    await tester.ensureVisible(enable);
    await tester.pump();
    await tester.tap(enable);
    await tester.pumpAndSettle();
    expect(harness.runtime.session.phase, MeditationSessionPhase.opening);
    final begin = find.byKey(const Key('meditation-begin'));
    await tester.ensureVisible(begin);
    await tester.pump();
    await tester.tap(begin);
    await tester.pumpAndSettle();
    expect(harness.runtime.session.phase, MeditationSessionPhase.humanTurn);
  }

  testWidgets('disclosure is passive until the player explicitly enables voice',
      (tester) async {
    final harness = await pumpPage(tester);

    expect(find.byKey(const Key('meditation-disclosure')), findsOneWidget);
    expect(harness.permission.checkCalls, 0);
    expect(harness.permission.requestCalls, 0);
    expect(harness.recognition.initializeCalls, 0);
    expect(harness.synthesis.initializeCalls, 0);
    expect(harness.runtime.session.phase, MeditationSessionPhase.opening);
  });

  testWidgets('opening speech completes before the turn clock starts',
      (tester) async {
    final harness = await pumpPage(tester);
    await tester.tap(find.byKey(const Key('meditation-enable')));
    await tester.pumpAndSettle();
    harness.synthesis.holdNextSpeak();

    await tester.tap(find.byKey(const Key('meditation-begin')));
    await tester.pump();

    expect(harness.runtime.session.phase, MeditationSessionPhase.opening);
    expect(harness.runtime.session.turnClock, isNull);
    harness.synthesis.completeSpeak();
    await tester.pumpAndSettle();

    expect(harness.runtime.session.phase, MeditationSessionPhase.humanTurn);
    expect(harness.runtime.session.turnClock, isNotNull);
  });

  testWidgets('one final voice result drives an authorized human and AI turn',
      (tester) async {
    final harness = await pumpPage(tester);
    await enableAndBegin(tester, harness);

    await tester.tap(find.byKey(const Key('meditation-listen')));
    await tester.pump();
    harness.recognition.emitFinal('从A1到A2');
    await tester.pumpAndSettle();

    expect(harness.runtime.session.moveHistory, hasLength(2));
    expect(find.text('从A1到A2'), findsNothing);
    expect(harness.recognition.listenCalls, 1);
  });

  testWidgets('an unrecognized result gives feedback without showing raw text',
      (tester) async {
    final harness = await pumpPage(tester);
    await enableAndBegin(tester, harness);

    await tester.tap(find.byKey(const Key('meditation-listen')));
    await tester.pump();
    harness.recognition.emitFinal(
      '从A1到A2',
      confidence: 0.2,
    );
    await tester.pumpAndSettle();

    expect(find.text('未听懂，请再说一次'), findsOneWidget);
    expect(find.text('从A1到A2'), findsNothing);
    expect(harness.runtime.session.moveHistory, isEmpty);
  });

  testWidgets('foregrounding never resumes a player-paused game',
      (tester) async {
    final harness = await pumpPage(tester);
    await enableAndBegin(tester, harness);
    await tester.tap(find.byKey(const Key('meditation-pause-resume')));
    await tester.pumpAndSettle();
    expect(harness.runtime.session.phase, MeditationSessionPhase.paused);

    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pumpAndSettle();

    expect(harness.runtime.session.phase, MeditationSessionPhase.paused);
  });

  testWidgets('exit requires confirmation and cancellation preserves the game',
      (tester) async {
    final harness = await pumpPage(tester);
    await enableAndBegin(tester, harness);

    await tester.tap(find.byKey(const Key('meditation-exit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('meditation-exit-confirmation')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('meditation-cancel-exit')));
    await tester.pumpAndSettle();
    expect(harness.runtime.session.phase, MeditationSessionPhase.humanTurn);
    expect(
      find.byKey(const Key('meditation-exit-confirmation')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('meditation-exit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('meditation-confirm-exit')));
    await tester.pumpAndSettle();
    expect(harness.runtime.session.phase, MeditationSessionPhase.completed);
    expect(find.byKey(const Key('meditation-leave')), findsOneWidget);
  });

  testWidgets('background deadline commit refreshes the terminal prompt',
      (tester) async {
    final harness = await pumpPage(tester);
    await enableAndBegin(tester, harness);

    harness.clock.value = harness.clock.value.add(
      const Duration(seconds: 60),
    );
    await harness.runtime.settle();
    await tester.pumpAndSettle();

    expect(harness.runtime.session.phase, MeditationSessionPhase.completed);
    expect(find.textContaining('超时'), findsOneWidget);
    expect(find.byKey(const Key('meditation-leave')), findsOneWidget);
  });

  testWidgets('archive failure still displays the terminal authority state',
      (tester) async {
    final harness = await pumpPage(
      tester,
      archiveCompletedGame: (_) async => false,
    );
    await enableAndBegin(tester, harness);

    harness.clock.value = harness.clock.value.add(
      const Duration(seconds: 60),
    );
    await expectLater(harness.runtime.settle(), throwsStateError);
    await tester.pumpAndSettle();

    expect(harness.runtime.session.phase, MeditationSessionPhase.completed);
    expect(find.byKey(const Key('meditation-leave')), findsOneWidget);
    expect(find.text('本局已结束，正在确认对局记录'), findsOneWidget);
  });

  testWidgets('compact phone layout scrolls without overflow', (tester) async {
    await pumpPage(tester, size: const Size(320, 568));

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final enableSize = tester.getSize(
      find.byKey(const Key('meditation-enable')),
    );
    expect(enableSize.height, greaterThanOrEqualTo(48));
  });

  testWidgets('English exit confirmation stacks safely on a compact phone',
      (tester) async {
    final harness = await pumpPage(
      tester,
      size: const Size(320, 568),
      locale: const Locale('en'),
      textScaler: const TextScaler.linear(2),
    );
    await enableAndBegin(tester, harness);
    final exit = find.byKey(const Key('meditation-exit'));
    await tester.ensureVisible(exit);
    await tester.pump();
    await tester.tap(exit);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Confirm abandonment'), findsOneWidget);
    expect(find.text('Continue game'), findsOneWidget);
  });
}

final class _Harness {
  const _Harness(
    this.runtime,
    this.permission,
    this.recognition,
    this.synthesis,
    this.clock,
  );

  final MeditationSessionRuntime runtime;
  final _FakePermissionPort permission;
  final _FakeRecognitionPort recognition;
  final _FakeSynthesisPort synthesis;
  final _Clock clock;
}

final class _Clock {
  _Clock(this.value);

  DateTime value;

  DateTime call() => value;
}

final class _MemoryRepository implements MeditationSessionRepository {
  MeditationSessionSnapshot? value;

  @override
  Future<void> delete({String? matchId}) async {
    if (matchId == null || value?.session.matchId == matchId) value = null;
  }

  @override
  Future<MeditationSessionSnapshot?> load() async => value;

  @override
  Future<void> save(MeditationSessionSnapshot snapshot) async {
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
  String get name => 'Meditation page test AI';

  @override
  String get description => 'Returns one legal move';
}

final class _FakePermissionPort implements MicrophonePermissionPort {
  int checkCalls = 0;
  int requestCalls = 0;

  @override
  Future<VoicePermissionStatus> check() async {
    checkCalls += 1;
    return VoicePermissionStatus.granted;
  }

  @override
  Future<VoicePermissionStatus> request() async {
    requestCalls += 1;
    return VoicePermissionStatus.granted;
  }
}

final class _FakeRecognitionPort implements VoiceRecognitionPort {
  int initializeCalls = 0;
  int listenCalls = 0;
  void Function(VoiceRecognitionSample sample)? _onSample;

  @override
  Future<bool> initialize() async {
    initializeCalls += 1;
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

  void emitFinal(String text, {double confidence = 1}) {
    _onSample?.call(
      VoiceRecognitionSample(
        text: text,
        confidence: confidence,
        isFinal: true,
      ),
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

final class _FakeSynthesisPort implements VoiceSynthesisPort {
  int initializeCalls = 0;
  Completer<void>? _heldSpeak;

  @override
  Future<bool> initialize() async {
    initializeCalls += 1;
    return true;
  }

  void holdNextSpeak() => _heldSpeak = Completer<void>();

  void completeSpeak() {
    _heldSpeak?.complete();
    _heldSpeak = null;
  }

  @override
  Future<void> speak(String text) async {
    final held = _heldSpeak;
    if (held != null) await held.future;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

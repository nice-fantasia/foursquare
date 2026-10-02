import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/meditation/meditation_session_persistence.dart';
import 'package:foursquare/meditation/meditation_session_runtime.dart';
import 'package:foursquare/meditation/meditation_session_snapshot.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/services/voice/platform_voice_adapters.dart';
import 'package:foursquare/services/voice/voice_ports.dart';
import 'package:foursquare/ui/screens/meditation/meditation_page.dart';
import 'package:foursquare/ui/screens/meditation/meditation_route_page.dart';

void main() {
  test('production route constructors are side-effect free', () {
    expect(
      MeditationRoutePage.newGame(
        humanPlayer: PieceType.black,
        firstPlayer: PieceType.black,
        difficulty: AIDifficulty.easy,
      ),
      isA<MeditationRoutePage>(),
    );
    expect(MeditationRoutePage.restore(), isA<MeditationRoutePage>());
  });

  testWidgets('loads runtime before constructing still-lazy platform ports',
      (tester) async {
    final runtime = await _createRuntime();
    final loading = Completer<MeditationSessionRuntime?>();
    var runtimeLoads = 0;
    var adapterCreations = 0;

    await tester.pumpWidget(
      _app(
        MeditationRoutePage(
          loadRuntime: () {
            runtimeLoads += 1;
            return loading.future;
          },
          createVoiceAdapters: () {
            adapterCreations += 1;
            return _adapters();
          },
        ),
      ),
    );

    expect(runtimeLoads, 1);
    expect(adapterCreations, 0);
    expect(find.byKey(const Key('meditation-route-loading')), findsOneWidget);

    loading.complete(runtime);
    await tester.pumpAndSettle();

    expect(adapterCreations, 1);
    expect(find.byType(MeditationPage), findsOneWidget);
  });

  testWidgets('missing saved session does not construct voice adapters',
      (tester) async {
    var adapterCreations = 0;

    await tester.pumpWidget(
      _app(
        MeditationRoutePage(
          loadRuntime: () async => null,
          createVoiceAdapters: () {
            adapterCreations += 1;
            return _adapters();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(adapterCreations, 0);
    expect(find.byKey(const Key('meditation-route-empty')), findsOneWidget);
  });

  testWidgets('load failure is sanitized and retry can recover',
      (tester) async {
    final runtime = await _createRuntime();
    var attempts = 0;

    await tester.pumpWidget(
      _app(
        MeditationRoutePage(
          loadRuntime: () async {
            attempts += 1;
            if (attempts == 1) {
              throw StateError('private storage details');
            }
            return runtime;
          },
          createVoiceAdapters: _adapters,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('meditation-route-error')), findsOneWidget);
    expect(find.textContaining('private storage details'), findsNothing);

    await tester.tap(find.byKey(const Key('meditation-route-retry')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byType(MeditationPage), findsOneWidget);
  });

  testWidgets('voice adapter construction failure is sanitized',
      (tester) async {
    final runtime = await _createRuntime();
    final streamClosed = expectLater(runtime.sessions, emitsDone);

    await tester.pumpWidget(
      _app(
        MeditationRoutePage(
          loadRuntime: () async => runtime,
          createVoiceAdapters: () {
            throw StateError('private plugin details');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('meditation-route-error')), findsOneWidget);
    expect(find.textContaining('private plugin details'), findsNothing);
    await streamClosed;
  });

  testWidgets('status shell fits a compact screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      _app(
        MeditationRoutePage(
          loadRuntime: () async => null,
          createVoiceAdapters: _adapters,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('meditation-route-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late runtime is disposed when the route has already left',
      (tester) async {
    final runtime = await _createRuntime();
    final loading = Completer<MeditationSessionRuntime?>();
    final streamClosed = expectLater(runtime.sessions, emitsDone);

    await tester.pumpWidget(
      _app(
        MeditationRoutePage(
          loadRuntime: () => loading.future,
          createVoiceAdapters: _adapters,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());

    loading.complete(runtime);
    await tester.pump();

    await streamClosed;
  });

  testWidgets('route owns and disposes the mounted runtime exactly once',
      (tester) async {
    final runtime = await _createRuntime();
    final streamClosed = expectLater(runtime.sessions, emitsDone);

    await tester.pumpWidget(
      _app(
        MeditationRoutePage(
          loadRuntime: () async => runtime,
          createVoiceAdapters: _adapters,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MeditationPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await streamClosed;
  });
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}

PlatformVoiceAdapters _adapters() {
  return PlatformVoiceAdapters(
    permission: _PermissionPort(),
    recognition: _RecognitionPort(),
    synthesis: _SynthesisPort(),
  );
}

Future<MeditationSessionRuntime> _createRuntime() {
  return MeditationSessionRuntime.createNew(
    humanPlayer: PieceType.black,
    firstPlayer: PieceType.black,
    aiPlayer: _NoMoveAI(AIDifficulty.easy),
    persistence: MeditationSessionPersistence(
      repository: _MemoryRepository(),
    ),
    archiveCompletedGame: (_) async => true,
  );
}

final class _MemoryRepository implements MeditationSessionRepository {
  MeditationSessionSnapshot? value;

  @override
  Future<void> delete({String? matchId}) async {
    value = null;
  }

  @override
  Future<MeditationSessionSnapshot?> load() async => value;

  @override
  Future<void> save(MeditationSessionSnapshot snapshot) async {
    value = snapshot;
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
  String get name => 'No move';

  @override
  String get description => 'Composition test';
}

final class _PermissionPort implements MicrophonePermissionPort {
  @override
  Future<VoicePermissionStatus> check() async => VoicePermissionStatus.granted;

  @override
  Future<VoicePermissionStatus> request() async =>
      VoicePermissionStatus.granted;
}

final class _RecognitionPort implements VoiceRecognitionPort {
  @override
  Future<void> dispose() async {}

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> listenOnce({
    required void Function(VoiceRecognitionSample sample) onSample,
    required void Function(VoicePortFailure failure) onFailure,
  }) async {}

  @override
  Future<void> stop() async {}
}

final class _SynthesisPort implements VoiceSynthesisPort {
  @override
  Future<void> dispose() async {}

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

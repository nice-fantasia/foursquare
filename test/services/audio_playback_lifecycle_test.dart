import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:foursquare/services/audio_coordinator.dart';
import 'package:foursquare/services/audio_service.dart';
import 'package:foursquare/services/music_service.dart';
import 'package:foursquare/services/voice_synthesis_service.dart';

class _Voice extends Mock implements VoiceSynthesisService {}

class _Player extends Mock implements AudioPlayer {
  bool playing = false;
  int resumes = 0;
  Completer<void>? sourceGate;
  Completer<void>? stopGate;
  final sourceEntered = Completer<void>();
  final stopEntered = Completer<void>();

  _Player() {
    when(() => onPlayerComplete).thenAnswer((_) => const Stream<void>.empty());
    when(() => onPlayerStateChanged)
        .thenAnswer((_) => const Stream<PlayerState>.empty());
    when(() => setVolume(any())).thenAnswer((_) async {});
    when(() => setReleaseMode(any())).thenAnswer((_) async {});
    when(() => setSource(any())).thenAnswer((_) async {
      if (!sourceEntered.isCompleted) sourceEntered.complete();
      await sourceGate?.future;
    });
    when(() => stop()).thenAnswer((_) async {
      if (!stopEntered.isCompleted) stopEntered.complete();
      await stopGate?.future;
      playing = false;
    });
    when(() => pause()).thenAnswer((_) async {
      playing = false;
    });
    when(() => resume()).thenAnswer((_) async {
      resumes++;
      playing = true;
    });
    when(() => dispose()).thenAnswer((_) async {
      playing = false;
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(AssetSource('test.wav'));
    registerFallbackValue(ReleaseMode.stop);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'repeated audio initialization retains exactly six effect players and one music player',
      () async {
    final players = <_Player>[];
    _Player createPlayer() {
      final player = _Player();
      players.add(player);
      return player;
    }

    final audio = AudioService.forTesting(playerFactory: createPlayer);
    final music = MusicService.forTesting(playerFactory: createPlayer);
    final coordinator = AudioCoordinator.forTesting(
      audioService: audio,
      musicService: music,
      voiceService: _Voice(),
    );
    await Future.wait([coordinator.initialize(), coordinator.initialize()]);
    await coordinator.initialize();
    expect(players.length, 7);
    await coordinator.onSceneChange(GameScene.aiGame);
    await audio.playSound(SoundType.move);
    expect(players.where((p) => p.playing).length, 2);
    await coordinator.stopAll();
    expect(players.any((p) => p.playing), isFalse);
    await coordinator.onSceneChange(GameScene.aiGame);
    expect(music.isPlaying(), isTrue);
    await coordinator.dispose();
  });

  for (final mute in [false, true]) {
    test('pending music source cannot restart after ${mute ? "mute" : "stop"}',
        () async {
      final player = _Player()..sourceGate = Completer<void>();
      final music = MusicService.forTesting(playerFactory: () => player);
      await music.initialize();
      final playing = music.playMusic(MusicTheme.gameplay);
      await player.sourceEntered.future;
      final stopping = mute ? music.setEnabled(false) : music.stopMusic();
      player.sourceGate!.complete();
      await Future.wait([playing, stopping]);
      expect(player.playing, isFalse);
      expect(player.resumes, 0);
      if (!mute) {
        await music.resumeMusic();
        expect(player.resumes, 0);
      }
      await music.dispose();
    });
  }

  test(
      'turning off effects cancels a pending restart and stops all active effects',
      () async {
    final players = <_Player>[];
    final audio = AudioService.forTesting(
      playerFactory: () {
        final player = _Player();
        players.add(player);
        return player;
      },
    );
    await audio.initialize();
    await audio.playSound(SoundType.move);
    expect(players[SoundType.move.index].playing, isTrue);
    final selection = players[SoundType.select.index]
      ..stopGate = Completer<void>();
    final playing = audio.playSound(SoundType.select);
    await selection.stopEntered.future;
    final mute = audio.setEnabled(false);
    selection.stopGate!.complete();
    await Future.wait([playing, mute]);
    expect(selection.resumes, 0);
    expect(players.any((p) => p.playing), isFalse);
    await audio.setEnabled(true);
    await audio.playSound(SoundType.move);
    expect(players[SoundType.move.index].playing, isTrue);
    await audio.dispose();
  });

  test(
      'background stops effects and music; exit during background cannot resume old audio',
      () async {
    final players = <_Player>[];
    _Player createPlayer() {
      final player = _Player();
      players.add(player);
      return player;
    }

    final audio = AudioService.forTesting(playerFactory: createPlayer);
    final music = MusicService.forTesting(playerFactory: createPlayer);
    final coordinator = AudioCoordinator.forTesting(
      audioService: audio,
      musicService: music,
      voiceService: _Voice(),
    );
    await coordinator.onSceneChange(GameScene.aiGame);
    await audio.playSound(SoundType.move);
    await coordinator.pauseAll();
    expect(players.any((p) => p.playing), isFalse);
    coordinator.onGameEvent(GameEvent.gameWon);
    await coordinator
        .updateSettings(coordinator.settings.copyWith(soundVolume: 0.3));
    expect(players.any((p) => p.playing), isFalse);
    await coordinator.resumeAll();
    expect(music.isPlaying(), isTrue);
    await coordinator.pauseAll();
    await coordinator.stopAll();
    await coordinator.resumeAll();
    expect(players.any((p) => p.playing), isFalse);
    await coordinator.dispose();
  });

  test('exit while initialization is pending prevents late scene music',
      () async {
    final players = <_Player>[];
    final gate = Completer<void>();
    final audio = AudioService.forTesting(
      playerFactory: () {
        final player = _Player()..sourceGate = gate;
        players.add(player);
        return player;
      },
    );
    final musicPlayer = _Player();
    final music = MusicService.forTesting(playerFactory: () => musicPlayer);
    final coordinator = AudioCoordinator.forTesting(
      audioService: audio,
      musicService: music,
      voiceService: _Voice(),
    );
    final starting = coordinator.onSceneChange(GameScene.aiGame);
    await Future<void>.delayed(Duration.zero);
    final stopping = coordinator.stopAll();
    gate.complete();
    await Future.wait([starting, stopping]);
    expect(musicPlayer.resumes, 0);
    await coordinator.dispose();
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/models/audio_settings.dart';
import 'package:foursquare/services/audio_coordinator.dart';
import 'package:foursquare/services/audio_service.dart';
import 'package:foursquare/services/music_service.dart';
import 'package:foursquare/services/voice_synthesis_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAudioService extends Mock implements AudioService {}

class _MockMusicService extends Mock implements MusicService {}

class _MockVoiceSynthesisService extends Mock
    implements VoiceSynthesisService {}

void main() {
  late _MockAudioService audioService;
  late _MockMusicService musicService;
  late _MockVoiceSynthesisService voiceService;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'audio_settings': jsonEncode(
        const AudioSettings(voiceEnabled: true).toMap(),
      ),
    });
    audioService = _MockAudioService();
    musicService = _MockMusicService();
    voiceService = _MockVoiceSynthesisService();

    when(() => audioService.initialize()).thenAnswer((_) async {});
    when(() => audioService.setEnabled(any())).thenAnswer((_) async {});
    when(() => musicService.initialize()).thenAnswer((_) async {});
    when(() => musicService.setEnabled(any())).thenAnswer((_) async {});
    when(() => musicService.setVolume(any())).thenAnswer((_) async {});
  });

  test('hidden voice output stays off and does not initialize TTS', () async {
    final coordinator = AudioCoordinator.forTesting(
      audioService: audioService,
      musicService: musicService,
      voiceService: voiceService,
    );

    await coordinator.initialize();
    coordinator.onGameEvent(
      GameEvent.turnChanged,
      data: const {'player': 'black'},
    );

    expect(coordinator.settings.voiceEnabled, isFalse);
    verifyNever(() => voiceService.initialize());
    verifyNever(() => voiceService.speak(any()));
  });

  test('runtime settings cannot enable a hidden voice feature', () async {
    SharedPreferences.setMockInitialValues(const {});
    final coordinator = AudioCoordinator.forTesting(
      audioService: audioService,
      musicService: musicService,
      voiceService: voiceService,
    );
    await coordinator.initialize();

    await coordinator.updateSettings(
      coordinator.settings.copyWith(voiceEnabled: true),
    );

    expect(coordinator.settings.voiceEnabled, isFalse);
    verifyNever(() => voiceService.initialize());
  });
}

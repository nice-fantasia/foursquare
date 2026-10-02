/// Music Service - 游戏音乐服务
///
/// 职责：
/// - 管理背景音乐播放
/// - 支持多种音乐主题切换
/// - 控制音乐音量
/// - 循环播放控制
library;

import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'logger_service.dart';

/// 音乐主题类型
enum MusicTheme {
  /// 主菜单音乐
  main,

  /// 游戏进行中音乐
  gameplay,

  /// 胜利音乐
  victory,

  /// 经典主题
  classic,

  /// 夜间主题
  night,

  /// 轻松主题
  relaxing,
}

/// 音乐服务
///
/// 负责游戏背景音乐的播放和管理
class MusicService {
  static final MusicService _instance = MusicService._internal();
  factory MusicService() => _instance;
  MusicService._internal() : _playerFactory = AudioPlayer.new;

  MusicService.forTesting({required AudioPlayer Function() playerFactory})
      : _playerFactory = playerFactory;

  final AudioPlayer Function() _playerFactory;
  Future<void>? _initialization;
  Future<void> _operation = Future<void>.value();
  int _generation = 0;
  StreamSubscription<void>? _completeSubscription;
  StreamSubscription<PlayerState>? _stateSubscription;

  AudioPlayer? _player;

  bool _enabled = true;
  double _volume = 0.4;
  MusicTheme? _currentTheme;
  bool _isPlaying = false;

  /// 音乐文件映射
  final Map<MusicTheme, String> _musicFiles = {
    MusicTheme.main: 'sounds/music/main.wav',
    MusicTheme.gameplay: 'sounds/music/gameplay.wav',
    MusicTheme.victory: 'sounds/music/main.wav', // 暂时复用
    MusicTheme.classic: 'sounds/music/gameplay.wav', // 暂时复用
    MusicTheme.night: 'sounds/music/gameplay.wav', // 暂时复用
    MusicTheme.relaxing: 'sounds/music/main.wav', // 暂时复用
  };

  /// 初始化音乐服务
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final player = _player ??= _playerFactory();
    await player.setVolume(_volume);

    // 设置循环播放
    await player.setReleaseMode(ReleaseMode.loop);

    // 监听播放完成事件
    _completeSubscription = player.onPlayerComplete.listen((_) {
      _isPlaying = false;
    });

    // 监听播放状态变化
    _stateSubscription = player.onPlayerStateChanged.listen((state) {
      _isPlaying = state == PlayerState.playing;
    });
  }

  /// 播放指定主题音乐
  Future<void> playMusic(MusicTheme theme) async {
    if (!_enabled) return;

    // 如果已经在播放相同主题，不需要重新播放
    if (_currentTheme == theme && _isPlaying) {
      return;
    }

    final musicFile = _musicFiles[theme];
    if (musicFile == null) return;
    final generation = ++_generation;
    _currentTheme = theme;
    final player = _player;
    if (player == null) {
      return;
    }

    await _enqueue(() async {
      if (!_enabled || generation != _generation) return;
      // 停止当前播放
      await player.stop();
      if (!_enabled || generation != _generation) return;

      // 设置新的音乐源
      await player.setSource(AssetSource(musicFile));
      if (!_enabled || generation != _generation) return;

      // 开始播放
      await player.resume();

      if (generation == _generation) _isPlaying = true;
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _operation = _operation.then((_) => action()).catchError((Object error) {
      logger.error('音乐操作失败', 'MusicService', error);
      _isPlaying = false;
    });
    return _operation;
  }

  /// 停止音乐
  Future<void> stopMusic() async {
    _generation++;
    _isPlaying = false;
    _currentTheme = null;
    await _enqueue(() async {
      await _player?.stop();
    });
  }

  /// 暂停音乐
  Future<void> pauseMusic() async {
    _generation++;
    _isPlaying = false;
    await _enqueue(() async {
      await _player?.pause();
    });
  }

  /// 恢复音乐
  Future<void> resumeMusic() async {
    if (_enabled && !_isPlaying && _player != null && _currentTheme != null) {
      final generation = ++_generation;
      await _enqueue(() async {
        if (!_enabled || generation != _generation) return;
        await _player!.resume();
        if (generation == _generation) _isPlaying = true;
      });
    }
  }

  /// 切换音乐主题
  Future<void> switchTheme(MusicTheme theme) async {
    await playMusic(theme);
  }

  /// 设置音乐开关
  Future<void> setEnabled(bool enabled) async {
    final wasEnabled = _enabled;
    _enabled = enabled;

    if (!enabled) {
      await pauseMusic();
    } else if (!wasEnabled && _currentTheme != null) {
      await playMusic(_currentTheme!);
    }
  }

  /// 获取音乐开关状态
  bool isEnabled() => _enabled;

  /// 设置音量 (0.0 - 1.0)
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _player?.setVolume(_volume);
  }

  /// 获取音量
  double getVolume() => _volume;

  /// 获取当前主题
  MusicTheme? getCurrentTheme() => _currentTheme;

  /// 是否正在播放
  bool isPlaying() => _isPlaying;

  /// 淡入效果播放
  Future<void> fadeIn(
    MusicTheme theme, {
    Duration duration = const Duration(seconds: 2),
  }) async {
    if (!_enabled) return;
    final player = _player;
    if (player == null) {
      _currentTheme = theme;
      return;
    }

    final targetVolume = _volume;
    await player.setVolume(0);
    await playMusic(theme);

    // 逐渐增加音量
    const steps = 20;
    final stepDuration = duration.inMilliseconds ~/ steps;
    final volumeStep = targetVolume / steps;

    for (int i = 1; i <= steps; i++) {
      await Future.delayed(Duration(milliseconds: stepDuration));
      if (!_isPlaying) break;
      await player.setVolume(volumeStep * i);
    }
  }

  /// 淡出效果停止
  Future<void> fadeOut({Duration duration = const Duration(seconds: 2)}) async {
    if (!_isPlaying) return;
    final player = _player;
    if (player == null) return;

    final currentVolume = _volume;

    // 逐渐减小音量
    const steps = 20;
    final stepDuration = duration.inMilliseconds ~/ steps;
    final volumeStep = currentVolume / steps;

    for (int i = steps - 1; i >= 0; i--) {
      await Future.delayed(Duration(milliseconds: stepDuration));
      await player.setVolume(volumeStep * i);
    }

    await stopMusic();
    await player.setVolume(currentVolume);
  }

  /// 释放资源
  Future<void> dispose() async {
    await stopMusic();
    await _initialization;
    await _completeSubscription?.cancel();
    await _stateSubscription?.cancel();
    await _player?.dispose();
    _player = null;
    _initialization = null;
  }
}

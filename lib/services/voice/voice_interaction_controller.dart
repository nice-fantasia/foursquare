import 'dart:async';

import '../../ai/voice_game_intent.dart';
import 'voice_ports.dart';

enum VoiceInteractionPhase {
  disabled,
  requestingPermission,
  initializing,
  ready,
  listening,
  processing,
  speaking,
  awaitingReplay,
  permissionDenied,
  permissionPermanentlyDenied,
  restricted,
  unavailable,
  interrupted,
  failed,
  disposed,
}

final class VoiceInteractionState {
  final VoiceInteractionPhase phase;
  final VoicePortFailure? failure;

  const VoiceInteractionState(this.phase, {this.failure});

  bool get canListen => phase == VoiceInteractionPhase.ready;

  @override
  String toString() => 'VoiceInteractionState(phase: ${phase.name}, '
      'failure: ${failure?.name})';
}

/// Owns voice permission and audio sequencing, but no game rules.
final class VoiceInteractionController {
  static const double defaultMinimumConfidence = 0.6;

  final MicrophonePermissionPort _permission;
  final VoiceRecognitionPort _recognition;
  final VoiceSynthesisPort _synthesis;
  final VoiceGameIntent? Function(String) _interpret;
  final FutureOr<VoiceInteractionReply?> Function(VoiceGameIntent) _onIntent;
  final double _minimumConfidence;
  final StreamController<VoiceInteractionState> _states =
      StreamController<VoiceInteractionState>.broadcast();

  VoiceInteractionState _state =
      const VoiceInteractionState(VoiceInteractionPhase.disabled);
  int _generation = 0;
  bool _disposed = false;
  bool _portsReady = false;
  bool _interruptRequested = false;
  bool _interruptInFlight = false;
  bool _resumeRequested = false;
  VoiceInteractionReply? _pendingReply;

  VoiceInteractionController({
    required MicrophonePermissionPort permission,
    required VoiceRecognitionPort recognition,
    required VoiceSynthesisPort synthesis,
    required VoiceGameIntent? Function(String) interpret,
    required FutureOr<VoiceInteractionReply?> Function(VoiceGameIntent)
        onIntent,
    double minimumConfidence = defaultMinimumConfidence,
  })  : _permission = permission,
        _recognition = recognition,
        _synthesis = synthesis,
        _interpret = interpret,
        _onIntent = onIntent,
        _minimumConfidence = minimumConfidence,
        assert(
          minimumConfidence >= 0 && minimumConfidence <= 1,
          'minimumConfidence must be between 0 and 1',
        );

  VoiceInteractionState get state => _state;

  Stream<VoiceInteractionState> get states => _states.stream;

  bool get hasPendingReply => _pendingReply != null;

  Future<void> enableAfterDisclosure() async {
    final canRestartInterruptedSetup =
        _state.phase == VoiceInteractionPhase.interrupted &&
            !_portsReady &&
            !_interruptInFlight;
    if (_disposed ||
        (_state.phase != VoiceInteractionPhase.disabled &&
            !canRestartInterruptedSetup)) {
      return;
    }

    final generation = ++_generation;
    _emit(
      const VoiceInteractionState(
        VoiceInteractionPhase.requestingPermission,
      ),
    );

    try {
      var permission = await _permission.check();
      if (!_isCurrent(generation)) {
        return;
      }
      if (permission == VoicePermissionStatus.notDetermined ||
          permission == VoicePermissionStatus.denied) {
        permission = await _permission.request();
        if (!_isCurrent(generation)) {
          return;
        }
      }
      if (!_acceptPermission(permission)) {
        return;
      }

      _emit(const VoiceInteractionState(VoiceInteractionPhase.initializing));
      final recognitionReady = await _recognition.initialize();
      if (!_isCurrent(generation)) {
        return;
      }
      final synthesisReady = await _synthesis.initialize();
      if (!_isCurrent(generation)) {
        return;
      }
      if (!recognitionReady || !synthesisReady) {
        _portsReady = false;
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.unavailable,
            failure: VoicePortFailure.unavailable,
          ),
        );
        return;
      }

      _portsReady = true;
      _emit(const VoiceInteractionState(VoiceInteractionPhase.ready));
    } catch (_) {
      if (_isCurrent(generation)) {
        _portsReady = false;
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.unavailable,
            failure: VoicePortFailure.unavailable,
          ),
        );
      }
    }
  }

  Future<void> listenOnce() async {
    if (_disposed || !_state.canListen || _pendingReply != null) {
      return;
    }

    final generation = _generation;
    var finalHandled = false;
    _emit(const VoiceInteractionState(VoiceInteractionPhase.listening));

    try {
      await _recognition.listenOnce(
        onSample: (sample) {
          if (!_isCurrent(generation) ||
              _state.phase != VoiceInteractionPhase.listening ||
              !sample.isFinal ||
              finalHandled) {
            return;
          }
          finalHandled = true;
          unawaited(_handleFinalSample(sample, generation));
        },
        onFailure: (failure) {
          if (!_isCurrent(generation) ||
              _state.phase != VoiceInteractionPhase.listening) {
            return;
          }
          unawaited(_handleRecognitionFailure(failure, generation));
        },
      );
      if (!_isCurrent(generation)) {
        await _ignorePortFailure(_recognition.stop());
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        await _handleRecognitionFailure(
          VoicePortFailure.recognitionFailed,
          generation,
        );
      }
    }
  }

  Future<bool> announce(String text) async {
    if (_disposed ||
        (_state.phase != VoiceInteractionPhase.ready &&
            _state.phase != VoiceInteractionPhase.listening)) {
      return false;
    }

    final wasListening = _state.phase == VoiceInteractionPhase.listening;
    final generation = ++_generation;
    final reply = VoiceInteractionReply(text);
    _pendingReply = reply;
    _emit(const VoiceInteractionState(VoiceInteractionPhase.speaking));
    if (!_isCurrent(generation)) {
      return false;
    }
    try {
      if (wasListening) {
        final recognitionStopped =
            await _portOperationSucceeded(_recognition.stop());
        if (!_isCurrent(generation)) {
          return false;
        }
        if (!recognitionStopped) {
          _pendingReply = null;
          _emit(
            const VoiceInteractionState(
              VoiceInteractionPhase.failed,
              failure: VoicePortFailure.interrupted,
            ),
          );
          return false;
        }
      }
      return _speakPendingReply(reply, generation);
    } catch (_) {
      if (_isCurrent(generation)) {
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.awaitingReplay,
            failure: VoicePortFailure.synthesisFailed,
          ),
        );
      }
      return false;
    }
  }

  /// Replays an already-authorized reply without interpreting or executing
  /// the original command again.
  Future<bool> replayPendingReply() async {
    final reply = _pendingReply;
    if (_disposed ||
        !_portsReady ||
        _state.phase != VoiceInteractionPhase.awaitingReplay ||
        reply == null) {
      return false;
    }

    final generation = ++_generation;
    _emit(const VoiceInteractionState(VoiceInteractionPhase.speaking));
    if (!_isCurrent(generation)) {
      return false;
    }
    return _speakPendingReply(reply, generation);
  }

  /// Drops an authorized reply that belongs to a superseded game/session.
  Future<bool> discardPendingReply() async {
    if (_disposed ||
        (_state.phase != VoiceInteractionPhase.awaitingReplay &&
            _state.phase != VoiceInteractionPhase.speaking) ||
        _pendingReply == null) {
      return false;
    }
    final wasSpeaking = _state.phase == VoiceInteractionPhase.speaking;
    _pendingReply = null;
    final generation = ++_generation;
    if (!wasSpeaking) {
      _emit(const VoiceInteractionState(VoiceInteractionPhase.ready));
      return true;
    }

    _emit(const VoiceInteractionState(VoiceInteractionPhase.interrupted));
    final stopped = await _portOperationSucceeded(_synthesis.stop());
    if (_isCurrent(generation)) {
      _emit(
        stopped
            ? const VoiceInteractionState(VoiceInteractionPhase.ready)
            : const VoiceInteractionState(
                VoiceInteractionPhase.failed,
                failure: VoicePortFailure.interrupted,
              ),
      );
    }
    return stopped;
  }

  Future<void> interrupt() async {
    if (_disposed) {
      return;
    }
    if (_state.phase == VoiceInteractionPhase.processing) {
      _interruptRequested = true;
      return;
    }
    if (!_isInterruptible(_state.phase)) {
      return;
    }

    final hadPendingReply = _pendingReply != null;
    _interruptInFlight = true;
    _resumeRequested = false;
    final generation = ++_generation;
    _emit(const VoiceInteractionState(VoiceInteractionPhase.interrupted));
    final stopped = await _stopBothPorts();
    _interruptInFlight = false;
    if (_isCurrent(generation) && !stopped) {
      _resumeRequested = false;
      _emit(
        const VoiceInteractionState(
          VoiceInteractionPhase.failed,
          failure: VoicePortFailure.interrupted,
        ),
      );
    } else if (_isCurrent(generation) && hadPendingReply) {
      _resumeRequested = false;
      _emit(
        const VoiceInteractionState(
          VoiceInteractionPhase.awaitingReplay,
          failure: VoicePortFailure.interrupted,
        ),
      );
    } else if (_isCurrent(generation) && _resumeRequested) {
      _resumeRequested = false;
      _emit(const VoiceInteractionState(VoiceInteractionPhase.ready));
    }
  }

  void resume() {
    if (!_disposed &&
        _portsReady &&
        _state.phase == VoiceInteractionPhase.interrupted) {
      if (_interruptInFlight) {
        _resumeRequested = true;
        return;
      }
      _emit(const VoiceInteractionState(VoiceInteractionPhase.ready));
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;
    _portsReady = false;
    _interruptRequested = false;
    _interruptInFlight = false;
    _resumeRequested = false;
    _pendingReply = null;
    ++_generation;
    _state = const VoiceInteractionState(VoiceInteractionPhase.disposed);
    if (!_states.isClosed) {
      _states.add(_state);
    }

    await Future.wait([
      _ignorePortFailure(_recognition.stop()),
      _ignorePortFailure(_synthesis.stop()),
    ]);
    await Future.wait([
      _ignorePortFailure(_recognition.dispose()),
      _ignorePortFailure(_synthesis.dispose()),
    ]);
    await _states.close();
  }

  Future<void> _handleFinalSample(
    VoiceRecognitionSample sample,
    int generation,
  ) async {
    _emit(const VoiceInteractionState(VoiceInteractionPhase.processing));
    try {
      await _recognition.stop();
    } catch (_) {
      if (_isCurrent(generation)) {
        _interruptRequested = false;
        _fail(VoicePortFailure.recognitionFailed);
      }
      return;
    }
    if (!_isCurrent(generation)) {
      return;
    }
    if (sample.confidence < _minimumConfidence) {
      if (!_finishDeferredInterrupt()) {
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.ready,
            failure: VoicePortFailure.unrecognized,
          ),
        );
      }
      return;
    }

    final VoiceGameIntent? intent;
    try {
      intent = _interpret(sample.text);
    } catch (_) {
      if (!_finishDeferredInterrupt()) {
        _fail(VoicePortFailure.commandFailed);
      }
      return;
    }
    if (intent == null) {
      if (_finishDeferredInterrupt()) {
        return;
      }
      _emit(
        const VoiceInteractionState(
          VoiceInteractionPhase.ready,
          failure: VoicePortFailure.unrecognized,
        ),
      );
      return;
    }

    final VoiceInteractionReply? reply;
    try {
      reply = await _onIntent(intent);
    } catch (_) {
      if (_isCurrent(generation)) {
        if (!_finishDeferredInterrupt()) {
          _fail(VoicePortFailure.commandFailed);
        }
      }
      return;
    }
    if (!_isCurrent(generation)) {
      return;
    }
    if (_finishDeferredInterrupt(reply)) {
      return;
    }
    if (reply == null) {
      _pendingReply = null;
      _emit(const VoiceInteractionState(VoiceInteractionPhase.ready));
      return;
    }

    _pendingReply = reply;
    _emit(const VoiceInteractionState(VoiceInteractionPhase.speaking));
    if (!_isCurrent(generation)) {
      return;
    }
    await _speakPendingReply(reply, generation);
  }

  Future<bool> _speakPendingReply(
    VoiceInteractionReply reply,
    int generation,
  ) async {
    try {
      await _synthesis.speak(reply.text);
      if (_isCurrent(generation)) {
        if (identical(_pendingReply, reply)) {
          _pendingReply = null;
        }
        _emit(const VoiceInteractionState(VoiceInteractionPhase.ready));
        return true;
      }
      return false;
    } catch (_) {
      if (_isCurrent(generation)) {
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.awaitingReplay,
            failure: VoicePortFailure.synthesisFailed,
          ),
        );
      }
      return false;
    }
  }

  Future<void> _handleRecognitionFailure(
    VoicePortFailure failure,
    int generation,
  ) async {
    if (!_isCurrent(generation) ||
        _state.phase != VoiceInteractionPhase.listening) {
      return;
    }

    final recoveryGeneration = ++_generation;
    _emit(
      VoiceInteractionState(
        VoiceInteractionPhase.failed,
        failure: failure,
      ),
    );
    final stopped = await _portOperationSucceeded(_recognition.stop());
    if (_isCurrent(recoveryGeneration) && stopped) {
      _emit(
        VoiceInteractionState(
          VoiceInteractionPhase.ready,
          failure: failure,
        ),
      );
    }
  }

  bool _finishDeferredInterrupt([VoiceInteractionReply? reply]) {
    if (!_interruptRequested) {
      return false;
    }
    _interruptRequested = false;
    if (reply == null) {
      _pendingReply = null;
      _emit(const VoiceInteractionState(VoiceInteractionPhase.interrupted));
    } else {
      _pendingReply = reply;
      _emit(
        const VoiceInteractionState(
          VoiceInteractionPhase.awaitingReplay,
          failure: VoicePortFailure.interrupted,
        ),
      );
    }
    return true;
  }

  bool _acceptPermission(VoicePermissionStatus permission) {
    switch (permission) {
      case VoicePermissionStatus.granted:
        return true;
      case VoicePermissionStatus.denied:
      case VoicePermissionStatus.notDetermined:
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.permissionDenied,
            failure: VoicePortFailure.permissionDenied,
          ),
        );
      case VoicePermissionStatus.permanentlyDenied:
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.permissionPermanentlyDenied,
            failure: VoicePortFailure.permissionDenied,
          ),
        );
      case VoicePermissionStatus.restricted:
        _emit(
          const VoiceInteractionState(
            VoiceInteractionPhase.restricted,
            failure: VoicePortFailure.permissionDenied,
          ),
        );
    }
    return false;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  static bool _isInterruptible(VoiceInteractionPhase phase) {
    return phase == VoiceInteractionPhase.requestingPermission ||
        phase == VoiceInteractionPhase.initializing ||
        phase == VoiceInteractionPhase.ready ||
        phase == VoiceInteractionPhase.listening ||
        phase == VoiceInteractionPhase.speaking;
  }

  Future<bool> _stopBothPorts() async {
    final results = await Future.wait([
      _portOperationSucceeded(_recognition.stop()),
      _portOperationSucceeded(_synthesis.stop()),
    ]);
    return results.every((result) => result);
  }

  static Future<bool> _portOperationSucceeded(Future<void> operation) async {
    try {
      await operation;
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _ignorePortFailure(Future<void> operation) async {
    await _portOperationSucceeded(operation);
  }

  void _fail(VoicePortFailure failure) {
    _emit(
      VoiceInteractionState(
        VoiceInteractionPhase.failed,
        failure: failure,
      ),
    );
  }

  void _emit(VoiceInteractionState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    _states.add(state);
  }
}

import 'dart:async';

import '../../ai/voice_game_intent.dart';
import '../../bloc/game_bloc.dart';
import '../../bloc/game_event.dart';
import '../../bloc/game_state.dart';
import '../../models/piece_type.dart';
import 'platform_voice_adapters.dart';
import 'voice_game_intent_dispatcher.dart';
import 'voice_interaction_controller.dart';
import 'voice_ports.dart';

export 'voice_interaction_controller.dart'
    show VoiceInteractionPhase, VoiceInteractionState;

typedef GameVoiceSessionFactory = GameVoiceSession Function({
  required GameBloc bloc,
  required PieceType controlledPlayer,
});

/// Voice capability boundary for an already-authoritative ordinary PVE game.
abstract interface class GameVoiceSession {
  VoiceInteractionState get state;

  Stream<VoiceInteractionState> get states;

  bool get canAcceptInput;

  Future<void> enableAfterDisclosure();

  Future<void> listenOnce();

  Future<void> replayPendingReply();

  Future<void> updateAvailability({required bool appIsActive});

  Future<void> dispose();
}

/// Sends typed intents into [GameBloc] and narrates only committed full moves.
///
/// Position selection remains silent. Full moves wait for a matching
/// authoritative state before reporting success. Control actions whose product
/// semantics have not been defined for PVE remain ignored.
final class BlocGameVoiceSession implements GameVoiceSession {
  final GameBloc _bloc;
  final PieceType _controlledPlayer;
  final Duration _committedOutcomeTimeout;
  late final VoiceInteractionController _voice;
  late final StreamSubscription<VoiceInteractionState> _voiceStateSubscription;
  late final VoiceGameIntentDispatcher _dispatcher;
  Future<void>? _enableOperation;
  Future<void> _availabilityUpdates = Future<void>.value();
  bool _appIsActive = true;
  bool _awaitingCommittedOutcome = false;
  bool _committedReplyInFlight = false;
  String? _committedReplyMatchId;
  _CommittedMoveWaiter? _activeCommittedMoveWaiter;

  BlocGameVoiceSession({
    required GameBloc bloc,
    required PieceType controlledPlayer,
    required MicrophonePermissionPort permission,
    required VoiceRecognitionPort recognition,
    required VoiceSynthesisPort synthesis,
    Duration committedOutcomeTimeout = const Duration(seconds: 2),
  })  : _bloc = bloc,
        _controlledPlayer = controlledPlayer,
        _committedOutcomeTimeout = committedOutcomeTimeout {
    _dispatcher = VoiceGameIntentDispatcher(
      addGameEvent: _bloc.add,
      onControlAction: (_) {},
    );
    _voice = VoiceInteractionController(
      permission: permission,
      recognition: recognition,
      synthesis: synthesis,
      interpret: VoiceGameIntentParser.parse,
      onIntent: _handleIntent,
    );
    _voiceStateSubscription = _voice.states.listen(_onVoiceStateChanged);
  }

  @override
  VoiceInteractionState get state => _voice.state;

  @override
  Stream<VoiceInteractionState> get states => _voice.states;

  @override
  bool get canAcceptInput {
    final state = _bloc.state;
    return _appIsActive &&
        state is GamePlaying &&
        state.mode == GameMode.pve &&
        state.humanPlayer == _controlledPlayer &&
        state.currentPlayer == _controlledPlayer &&
        !state.isAIThinking;
  }

  @override
  Future<void> enableAfterDisclosure() async {
    if (!canAcceptInput) return;
    await _runEnable();
    if (!canAcceptInput) await _voice.interrupt();
  }

  @override
  Future<void> listenOnce() async {
    if (!canAcceptInput) {
      await _voice.interrupt();
      return;
    }
    await _voice.listenOnce();
  }

  @override
  Future<void> replayPendingReply() async {
    if (!_appIsActive || !_committedReplyInFlight) return;
    await _voice.replayPendingReply();
  }

  @override
  Future<void> updateAvailability({required bool appIsActive}) async {
    _appIsActive = appIsActive;
    final requestedActive = appIsActive;
    _availabilityUpdates = _availabilityUpdates.then((_) async {
      if (_committedReplyInFlight &&
          _committedReplyMatchId != null &&
          _bloc.state.matchId != _committedReplyMatchId) {
        _committedReplyInFlight = false;
        _committedReplyMatchId = null;
        await _voice.discardPendingReply();
      }
      if (!requestedActive) {
        await _voice.interrupt();
        return;
      }
      if (!_appIsActive) {
        await _voice.interrupt();
        return;
      }
      if (_awaitingCommittedOutcome || _committedReplyInFlight) return;
      if (!canAcceptInput) {
        await _voice.interrupt();
        return;
      }

      final enabling = _enableOperation;
      if (enabling != null) await enabling;
      if (!_appIsActive || !canAcceptInput) return;

      _voice.resume();
      if (_voice.state.phase == VoiceInteractionPhase.interrupted) {
        await _runEnable();
      }
    });
    await _availabilityUpdates;
  }

  @override
  Future<void> dispose() async {
    _committedReplyInFlight = false;
    _committedReplyMatchId = null;
    _awaitingCommittedOutcome = false;
    final waiter = _activeCommittedMoveWaiter;
    _activeCommittedMoveWaiter = null;
    if (waiter != null) await waiter.cancel();
    await _voiceStateSubscription.cancel();
    await _voice.dispose();
  }

  Future<VoiceInteractionReply?> _handleIntent(VoiceGameIntent intent) async {
    if (!canAcceptInput) return null;
    if (intent case VoiceMoveIntent(:final from, :final to)) {
      final before = _bloc.state;
      if (before is! GamePlaying) return null;
      final expectedMoveCount = before.moveHistory.length + 1;
      final waiter = _CommittedMoveWaiter(
        states: _bloc.stream,
        timeout: _committedOutcomeTimeout,
        matches: (state) {
          final move = state.lastMove;
          return state.moveHistory.length == expectedMoveCount &&
              move != null &&
              move.from == from &&
              move.to == to &&
              move.player == _controlledPlayer;
        },
      );
      _activeCommittedMoveWaiter = waiter;

      _awaitingCommittedOutcome = true;
      try {
        _dispatcher.dispatch(intent);
        final committed = await waiter.result;
        if (committed == null) {
          if (!canAcceptInput) unawaited(_voice.interrupt());
          return null;
        }
        if (!_appIsActive) return null;
        if (committed is GameOver) {
          final winner = committed.gameResult?.winner;
          _committedReplyInFlight = true;
          _committedReplyMatchId = before.matchId;
          return VoiceInteractionReply(
            winner == _controlledPlayer
                ? '移动成功，你获胜了'
                : winner == null
                    ? '移动成功，本局平局'
                    : '移动成功，本局结束',
          );
        }
        final captureCount = committed.lastMove?.captureCount ?? 0;
        _committedReplyInFlight = true;
        _committedReplyMatchId = before.matchId;
        return VoiceInteractionReply(
          switch (captureCount) {
            1 => '移动成功，吃掉一枚棋子',
            2 => '移动成功，吃掉两枚棋子',
            _ => '移动成功',
          },
        );
      } finally {
        if (identical(_activeCommittedMoveWaiter, waiter)) {
          _activeCommittedMoveWaiter = null;
        }
        await waiter.cancel();
        _awaitingCommittedOutcome = false;
      }
    }
    _dispatcher.dispatch(intent);
    return null;
  }

  void _onVoiceStateChanged(VoiceInteractionState state) {
    if (!_committedReplyInFlight ||
        state.phase != VoiceInteractionPhase.ready) {
      return;
    }
    _committedReplyInFlight = false;
    _committedReplyMatchId = null;
    if (!canAcceptInput) unawaited(_voice.interrupt());
  }

  Future<void> _runEnable() {
    final current = _enableOperation;
    if (current != null) return current;

    late final Future<void> operation;
    operation = _voice.enableAfterDisclosure().whenComplete(() {
      if (identical(_enableOperation, operation)) {
        _enableOperation = null;
      }
    });
    _enableOperation = operation;
    return operation;
  }
}

final class _CommittedMoveWaiter {
  final Completer<GameState?> _outcome = Completer<GameState?>();
  late final Timer _timeout;
  late final StreamSubscription<GameState> _subscription;
  bool _cancelled = false;

  _CommittedMoveWaiter({
    required Stream<GameState> states,
    required Duration timeout,
    required bool Function(GameState state) matches,
  }) {
    _timeout = Timer(timeout, () => _complete(null));
    _subscription = states.listen(
      (state) {
        if (matches(state)) _complete(state);
      },
      onError: (_, __) => _complete(null),
      onDone: () => _complete(null),
    );
  }

  Future<GameState?> get result => _outcome.future;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _timeout.cancel();
    _complete(null);
    await _subscription.cancel();
  }

  void _complete(GameState? state) {
    if (!_outcome.isCompleted) _outcome.complete(state);
  }
}

GameVoiceSession createProductionGameVoiceSession({
  required GameBloc bloc,
  required PieceType controlledPlayer,
}) {
  final adapters = PlatformVoiceAdapters.create();
  return BlocGameVoiceSession(
    bloc: bloc,
    controlledPlayer: controlledPlayer,
    permission: adapters.permission,
    recognition: adapters.recognition,
    synthesis: adapters.synthesis,
  );
}

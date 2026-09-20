import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/local_network_service.dart';
import '../services/logger_service.dart';
import 'lan_lobby_event.dart';
import 'lan_lobby_state.dart';

class LanLobbyBloc extends Bloc<LanLobbyEvent, LanLobbyState> {
  final LocalNetworkService _networkService;
  StreamSubscription? _servicesSubscription;
  StreamSubscription?
      _messageSubscription; // To detect connection handshake if needed

  LanLobbyBloc({LocalNetworkService? networkService})
      : _networkService = networkService ?? LocalNetworkService(),
        super(const LanLobbyState()) {
    on<StartDiscovery>(_onStartDiscovery);
    on<StopDiscovery>(_onStopDiscovery);
    on<StartHosting>(_onStartHosting);
    on<StopHosting>(_onStopHosting);
    on<ConnectToHost>(_onConnectToHost);
    on<DisconnectLan>(_onDisconnect);
    on<ServicesUpdated>(_onServicesUpdated);
    on<LanConnectionStatusChanged>(_onConnectionStatusChanged);

    // Subscribe to connection state changes
    _messageSubscription =
        _networkService.connectionStateStream.listen((state) {
      final isConnected = state == LocalNetworkConnectionState.connected;
      final isHost = _networkService.role == LocalNetworkRole.host;

      // Map service state to bloc event
      add(
        LanConnectionStatusChanged(
          isConnected: isConnected,
          isHost: isHost,
        ),
      );
    });
  }

  Future<void> _onStartDiscovery(
    StartDiscovery event,
    Emitter<LanLobbyState> emit,
  ) async {
    // Only update to scanning if success, but we should let the service drive the state potentially.
    // However, for UI responsiveness, setting scanning here is fine.
    // The service updates connection state to scanning too.
    emit(
      state.copyWith(
        status: LanLobbyStatus.scanning,
        clearFailure: true,
      ),
    );
    try {
      await _servicesSubscription?.cancel();
      _servicesSubscription = _networkService.foundServices.listen(
        (services) => add(ServicesUpdated(services)),
      );

      await _networkService.startDiscovery();
    } catch (error, stackTrace) {
      logger.error(
        'LAN discovery failed',
        'LanLobbyBloc',
        error,
        stackTrace,
      );
      emit(
        state.copyWith(
          status: LanLobbyStatus.failure,
          failure: LanLobbyFailure.discovery,
        ),
      );
    }
  }

  Future<void> _onStopDiscovery(
    StopDiscovery event,
    Emitter<LanLobbyState> emit,
  ) async {
    await _servicesSubscription?.cancel();
    await _networkService.stop();
    // State update will be handled by connection stream
  }

  Future<void> _onStartHosting(
    StartHosting event,
    Emitter<LanLobbyState> emit,
  ) async {
    emit(
      state.copyWith(
        status: LanLobbyStatus.hosting,
        isHost: true,
        clearFailure: true,
      ),
    );
    try {
      await _networkService.startHost(roomName: event.roomName);
    } catch (error, stackTrace) {
      logger.error(
        'LAN hosting failed',
        'LanLobbyBloc',
        error,
        stackTrace,
      );
      emit(
        state.copyWith(
          status: LanLobbyStatus.failure,
          failure: LanLobbyFailure.hosting,
          isHost: false,
        ),
      );
    }
  }

  Future<void> _onStopHosting(
    StopHosting event,
    Emitter<LanLobbyState> emit,
  ) async {
    await _networkService.stop();
  }

  Future<void> _onConnectToHost(
    ConnectToHost event,
    Emitter<LanLobbyState> emit,
  ) async {
    emit(
      state.copyWith(
        status: LanLobbyStatus.connecting,
        clearFailure: true,
      ),
    );
    try {
      await _networkService.connectToHost(event.service);
    } catch (error, stackTrace) {
      logger.error(
        'LAN connection failed',
        'LanLobbyBloc',
        error,
        stackTrace,
      );
      emit(
        state.copyWith(
          status: LanLobbyStatus.failure,
          failure: LanLobbyFailure.connection,
        ),
      );
    }
  }

  Future<void> _onDisconnect(
    DisconnectLan event,
    Emitter<LanLobbyState> emit,
  ) async {
    await _networkService.stop();
  }

  void _onServicesUpdated(
    ServicesUpdated event,
    Emitter<LanLobbyState> emit,
  ) {
    // Always update services if we receive them
    emit(state.copyWith(foundServices: event.services));
  }

  void _onConnectionStatusChanged(
    LanConnectionStatusChanged event,
    Emitter<LanLobbyState> emit,
  ) {
    if (event.isConnected) {
      emit(
        state.copyWith(
          status: LanLobbyStatus.connected,
          isHost: event.isHost,
        ),
      );
    } else if (event.isHost) {
      emit(
        state.copyWith(
          status: LanLobbyStatus.hosting,
          isHost: true,
        ),
      );
    } else {
      // A non-host disconnect ends an active lobby session.
      if (state.status == LanLobbyStatus.connected ||
          state.status == LanLobbyStatus.hosting) {
        emit(state.copyWith(status: LanLobbyStatus.initial, isHost: false));
      }
    }
  }

  @override
  Future<void> close() {
    _servicesSubscription?.cancel();
    _messageSubscription?.cancel();
    return super.close();
  }
}

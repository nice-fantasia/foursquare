import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/bloc/lan_lobby_bloc.dart';
import 'package:foursquare/bloc/lan_lobby_event.dart';
import 'package:foursquare/bloc/lan_lobby_state.dart';
import 'package:foursquare/services/local_network_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nsd/nsd.dart';

class _MockLocalNetworkService extends Mock implements LocalNetworkService {}

void main() {
  late _MockLocalNetworkService networkService;
  late StreamController<LocalNetworkConnectionState> connectionStates;

  setUp(() {
    networkService = _MockLocalNetworkService();
    connectionStates =
        StreamController<LocalNetworkConnectionState>.broadcast();
    when(() => networkService.connectionStateStream).thenAnswer(
      (_) => connectionStates.stream,
    );
    when(() => networkService.foundServices).thenAnswer(
      (_) => const Stream<List<Service>>.empty(),
    );
  });

  tearDown(() async {
    await connectionStates.close();
  });

  blocTest<LanLobbyBloc, LanLobbyState>(
    'exposes a stable discovery failure without leaking exception text',
    build: () {
      when(() => networkService.startDiscovery()).thenThrow(
        StateError('private network details must not reach the UI'),
      );
      return LanLobbyBloc(networkService: networkService);
    },
    act: (bloc) => bloc.add(StartDiscovery()),
    expect: () => const <LanLobbyState>[
      LanLobbyState(status: LanLobbyStatus.scanning),
      LanLobbyState(
        status: LanLobbyStatus.failure,
        failure: LanLobbyFailure.discovery,
      ),
    ],
  );

  test('a successful retry clears the previous failure code', () {
    const failed = LanLobbyState(
      status: LanLobbyStatus.failure,
      failure: LanLobbyFailure.hosting,
    );

    final retrying = failed.copyWith(
      status: LanLobbyStatus.hosting,
      clearFailure: true,
    );

    expect(retrying.failure, isNull);
  });

  blocTest<LanLobbyBloc, LanLobbyState>(
    'host startup remains in the waiting state while the service initializes',
    build: () {
      when(() => networkService.role).thenReturn(LocalNetworkRole.host);
      when(
        () => networkService.startHost(roomName: '我的棋室'),
      ).thenAnswer((_) async {
        connectionStates.add(LocalNetworkConnectionState.disconnected);
        await Future<void>.delayed(Duration.zero);
        connectionStates.add(LocalNetworkConnectionState.hosting);
      });
      return LanLobbyBloc(networkService: networkService);
    },
    act: (bloc) => bloc.add(const StartHosting(roomName: '我的棋室')),
    wait: const Duration(milliseconds: 20),
    expect: () => const <LanLobbyState>[
      LanLobbyState(status: LanLobbyStatus.hosting, isHost: true),
    ],
    verify: (_) {
      verify(
        () => networkService.startHost(roomName: '我的棋室'),
      ).called(1);
    },
  );
}

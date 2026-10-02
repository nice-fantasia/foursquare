import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/services/online_identity_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockSharedPreferences extends Mock implements SharedPreferences {}

void main() {
  test('creates one anonymous identity and reuses it across service instances',
      () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    var generated = 0;
    String nextId() => 'device-${++generated}';

    final first = OnlineIdentityService(idGenerator: nextId);
    final second = OnlineIdentityService(idGenerator: nextId);

    expect(await first.getOrCreate(), 'device-1');
    expect(await second.getOrCreate(), 'device-1');
    expect(generated, 1);
  });

  test('reading an unused online identity does not create one', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    var generated = 0;
    final service = OnlineIdentityService(
      idGenerator: () => 'device-${++generated}',
    );

    expect(await service.readExisting(), isNull);
    expect(generated, 0);
  });

  test('deleting unused online data is a no-op and does not create identity',
      () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    var remoteCalls = 0;
    var generated = 0;
    final service = OnlineIdentityService(
      idGenerator: () => 'device-${++generated}',
    );

    final result = await service.deleteOnlineDataAndReset(
      deleteRemoteData: (_) async => remoteCalls += 1,
      timeout: const Duration(seconds: 1),
    );

    expect(result, OnlineIdentityResetResult.noExistingIdentity);
    expect(remoteCalls, 0);
    expect(generated, 0);
    expect(await service.readExisting(), isNull);
  });

  test('confirmed remote deletion replaces the expected local identity',
      () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    String? deletedIdentity;
    final service = OnlineIdentityService(
      idGenerator: () => 'device-replacement',
    );

    final result = await service.deleteOnlineDataAndReset(
      deleteRemoteData: (identity) async => deletedIdentity = identity,
      timeout: const Duration(seconds: 1),
    );

    expect(result, OnlineIdentityResetResult.reset);
    expect(deletedIdentity, 'device-existing');
    expect(await service.readExisting(), 'device-replacement');
  });

  test('remote deletion failure preserves the existing identity', () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    final service = OnlineIdentityService(
      idGenerator: () => 'device-replacement',
    );

    final result = await service.deleteOnlineDataAndReset(
      deleteRemoteData: (_) async => throw StateError('remote rejected'),
      timeout: const Duration(seconds: 1),
    );

    expect(result, OnlineIdentityResetResult.remoteDeletionFailed);
    expect(await service.readExisting(), 'device-existing');
  });

  test('remote deletion timeout preserves the existing identity', () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    final pending = Completer<void>();
    final service = OnlineIdentityService(
      idGenerator: () => 'device-replacement',
    );

    final result = await service.deleteOnlineDataAndReset(
      deleteRemoteData: (_) => pending.future,
      timeout: const Duration(milliseconds: 10),
    );

    expect(result, OnlineIdentityResetResult.remoteDeletionFailed);
    expect(await service.readExisting(), 'device-existing');
  });

  test('malformed remote response preserves the existing identity', () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    final service = OnlineIdentityService(
      idGenerator: () => 'device-replacement',
    );

    final result = await service.deleteOnlineDataAndReset(
      deleteRemoteData: (_) async => throw const FormatException(),
      timeout: const Duration(seconds: 1),
    );

    expect(result, OnlineIdentityResetResult.remoteDeletionFailed);
    expect(await service.readExisting(), 'device-existing');
  });

  test('remote success does not overwrite an identity changed while waiting',
      () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    final deletionStarted = Completer<void>();
    final deletionFinished = Completer<void>();
    var generated = 0;
    final service = OnlineIdentityService(
      idGenerator: () => 'device-${++generated}',
    );

    final future = service.deleteOnlineDataAndReset(
      deleteRemoteData: (_) {
        deletionStarted.complete();
        return deletionFinished.future;
      },
      timeout: const Duration(seconds: 1),
    );
    await deletionStarted.future;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'online_anonymous_device_id',
      'device-newer',
    );
    deletionFinished.complete();

    expect(await future, OnlineIdentityResetResult.identityChanged);
    expect(await service.readExisting(), 'device-newer');
    expect(generated, 0);
  });

  test('concurrent deletion requests share one remote call and one reset',
      () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    final deletionStarted = Completer<void>();
    final deletionFinished = Completer<void>();
    var remoteCalls = 0;
    var generated = 0;
    final service = OnlineIdentityService(
      idGenerator: () => 'device-${++generated}',
    );
    Future<void> deleteRemoteData(String identity) {
      remoteCalls += 1;
      if (!deletionStarted.isCompleted) deletionStarted.complete();
      return deletionFinished.future;
    }

    final firstResult = service.deleteOnlineDataAndReset(
      deleteRemoteData: deleteRemoteData,
      timeout: const Duration(seconds: 1),
    );
    await deletionStarted.future;
    final secondResult = service.deleteOnlineDataAndReset(
      deleteRemoteData: deleteRemoteData,
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(remoteCalls, 1);
    deletionFinished.complete();

    expect(
      await Future.wait([firstResult, secondResult]),
      everyElement(OnlineIdentityResetResult.reset),
    );
    expect(remoteCalls, 1);
    expect(generated, 1);
    expect(await service.readExisting(), 'device-1');
  });

  test('default service instances share one remote deletion operation',
      () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    final deletionStarted = Completer<void>();
    final deletionFinished = Completer<void>();
    var remoteCalls = 0;
    var generated = 0;
    final first = OnlineIdentityService(
      idGenerator: () => 'device-${++generated}',
    );
    final second = OnlineIdentityService(
      idGenerator: () => 'device-${++generated}',
    );

    Future<void> deleteRemoteData(String identity) {
      remoteCalls += 1;
      if (!deletionStarted.isCompleted) deletionStarted.complete();
      return deletionFinished.future;
    }

    final firstResult = first.deleteOnlineDataAndReset(
      deleteRemoteData: deleteRemoteData,
      timeout: const Duration(seconds: 1),
    );
    await deletionStarted.future;
    final secondResult = second.deleteOnlineDataAndReset(
      deleteRemoteData: deleteRemoteData,
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);

    expect(remoteCalls, 1);
    deletionFinished.complete();
    expect(
      await Future.wait([firstResult, secondResult]),
      everyElement(OnlineIdentityResetResult.reset),
    );
    expect(generated, 1);
  });

  test('independent stores do not share remote deletion operations', () async {
    final firstPreferences = MockSharedPreferences();
    final secondPreferences = MockSharedPreferences();
    when(() => firstPreferences.getString(any())).thenReturn('device-first');
    when(() => secondPreferences.getString(any())).thenReturn('device-second');
    when(() => firstPreferences.setString(any(), any()))
        .thenAnswer((_) async => true);
    when(() => secondPreferences.setString(any(), any()))
        .thenAnswer((_) async => true);
    final firstDeletion = Completer<void>();
    final secondDeletion = Completer<void>();
    var remoteCalls = 0;
    final first = OnlineIdentityService(
      idGenerator: () => 'device-first-new',
      preferencesProvider: () async => firstPreferences,
    );
    final second = OnlineIdentityService(
      idGenerator: () => 'device-second-new',
      preferencesProvider: () async => secondPreferences,
    );

    final firstResult = first.deleteOnlineDataAndReset(
      deleteRemoteData: (_) {
        remoteCalls += 1;
        return firstDeletion.future;
      },
      timeout: const Duration(seconds: 1),
    );
    final secondResult = second.deleteOnlineDataAndReset(
      deleteRemoteData: (_) {
        remoteCalls += 1;
        return secondDeletion.future;
      },
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);

    expect(remoteCalls, 2);
    firstDeletion.complete();
    secondDeletion.complete();
    expect(
      await Future.wait([firstResult, secondResult]),
      everyElement(OnlineIdentityResetResult.reset),
    );
  });

  test('remote deletion cannot reuse the deleted identity', () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{
        'online_anonymous_device_id': 'device-existing',
      },
    );
    final service = OnlineIdentityService(
      idGenerator: () => 'device-existing',
    );

    final result = await service.deleteOnlineDataAndReset(
      deleteRemoteData: (_) async {},
      timeout: const Duration(seconds: 1),
    );

    expect(result, OnlineIdentityResetResult.persistenceFailed);
    expect(await service.readExisting(), 'device-existing');
  });

  test('replaces a persisted identity that the server cannot accept', () async {
    SharedPreferences.setMockInitialValues(
      const <String, Object>{'online_anonymous_device_id': 'bad value'},
    );
    final service = OnlineIdentityService(
      idGenerator: () => 'device-valid-1',
    );

    expect(await service.getOrCreate(), 'device-valid-1');
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('online_anonymous_device_id'),
      'device-valid-1',
    );
  });

  test('concurrent callers receive the same persisted identity', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    var generated = 0;
    String nextId() => 'device-${++generated}';
    final first = OnlineIdentityService(idGenerator: nextId);
    final second = OnlineIdentityService(idGenerator: nextId);

    final identities = await Future.wait([
      first.getOrCreate(),
      second.getOrCreate(),
      first.getOrCreate(),
    ]);

    expect(identities, everyElement('device-1'));
    expect(generated, 1);
  });

  test('does not return an identity when persistence fails', () async {
    final preferences = MockSharedPreferences();
    when(() => preferences.getString(any())).thenReturn(null);
    when(() => preferences.setString(any(), any()))
        .thenAnswer((_) async => false);
    final service = OnlineIdentityService(
      idGenerator: () => 'device-not-persisted',
      preferencesProvider: () async => preferences,
    );

    expect(
      service.getOrCreate,
      throwsA(isA<OnlineIdentityPersistenceException>()),
    );
  });

  test('failed replacement write after remote deletion keeps the old identity',
      () async {
    final preferences = MockSharedPreferences();
    var cachedIdentity = 'device-existing';
    when(() => preferences.getString(any())).thenAnswer((_) => cachedIdentity);
    when(() => preferences.setString(any(), any()))
        .thenAnswer((invocation) async {
      cachedIdentity = invocation.positionalArguments[1] as String;
      return cachedIdentity == 'device-existing';
    });
    final service = OnlineIdentityService(
      idGenerator: () => 'device-replacement',
      preferencesProvider: () async => preferences,
    );

    final result = await service.deleteOnlineDataAndReset(
      deleteRemoteData: (_) async {},
      timeout: const Duration(seconds: 1),
    );

    expect(result, OnlineIdentityResetResult.persistenceFailed);
    verify(() => preferences.setString(any(), 'device-replacement')).called(1);
    verify(() => preferences.setString(any(), 'device-existing')).called(1);
    expect(await service.readExisting(), 'device-existing');
  });
}

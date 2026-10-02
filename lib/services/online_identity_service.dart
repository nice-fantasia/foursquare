import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef OnlineIdentityGenerator = String Function();
typedef OnlinePreferencesProvider = Future<SharedPreferences> Function();
typedef OnlineRemoteDataDeletion = Future<void> Function(String identity);

enum OnlineIdentityPersistenceError { invalidGeneratedIdentity, writeFailed }

enum OnlineIdentityResetResult {
  noExistingIdentity,
  reset,
  remoteDeletionFailed,
  identityChanged,
  persistenceFailed,
}

class OnlineIdentityPersistenceException implements Exception {
  final OnlineIdentityPersistenceError error;

  const OnlineIdentityPersistenceException(this.error);

  @override
  String toString() => 'OnlineIdentityPersistenceException(${error.name})';
}

class OnlineIdentityResetCoordinator {
  Future<OnlineIdentityResetResult>? _inFlight;

  Future<OnlineIdentityResetResult> run(
    Future<OnlineIdentityResetResult> Function() operation,
  ) {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    late final Future<OnlineIdentityResetResult> result;
    result = operation().whenComplete(() {
      if (identical(_inFlight, result)) {
        _inFlight = null;
      }
    });
    _inFlight = result;
    return result;
  }
}

class OnlineIdentityService {
  OnlineIdentityService({
    OnlineIdentityGenerator? idGenerator,
    OnlinePreferencesProvider? preferencesProvider,
    OnlineIdentityResetCoordinator? resetCoordinator,
  })  : _idGenerator = idGenerator ?? (() => const Uuid().v4()),
        _preferencesProvider =
            preferencesProvider ?? SharedPreferences.getInstance,
        _resetCoordinator = resetCoordinator ??
            (preferencesProvider == null
                ? _defaultResetCoordinator
                : OnlineIdentityResetCoordinator());

  /// Shared with whole-app local reset so server-linked identity is preserved.
  static const String storageKey = 'online_anonymous_device_id';
  static Future<void> _operationChain = Future<void>.value();
  static final OnlineIdentityResetCoordinator _defaultResetCoordinator =
      OnlineIdentityResetCoordinator();

  final OnlineIdentityGenerator _idGenerator;
  final OnlinePreferencesProvider _preferencesProvider;
  final OnlineIdentityResetCoordinator _resetCoordinator;

  Future<String> getOrCreate() => _synchronized(_getOrCreate);

  /// Reads a usable persisted identity without creating or repairing one.
  Future<String?> readExisting() => _synchronized(_readExisting);

  /// Requests remote deletion and replaces the exact identity that was
  /// deleted only after the callback completes successfully.
  ///
  /// The callback must complete only after parsing an explicit server success.
  /// Transport errors, timeouts, rejected requests, and malformed responses
  /// must throw. Services that share a coordinator also share one operation.
  Future<OnlineIdentityResetResult> deleteOnlineDataAndReset({
    required OnlineRemoteDataDeletion deleteRemoteData,
    required Duration timeout,
  }) =>
      _resetCoordinator.run(
        () => _deleteOnlineDataAndReset(
          deleteRemoteData: deleteRemoteData,
          timeout: timeout,
        ),
      );

  Future<String> _getOrCreate() async {
    final SharedPreferences preferences = await _preferencesProvider();
    final String? existingIdentity = preferences.getString(storageKey);
    if (existingIdentity != null && _isValidIdentity(existingIdentity)) {
      return existingIdentity;
    }

    return _replaceIdentity(preferences);
  }

  Future<String?> _readExisting() async {
    final SharedPreferences preferences = await _preferencesProvider();
    final String? existingIdentity = preferences.getString(storageKey);
    return existingIdentity != null && _isValidIdentity(existingIdentity)
        ? existingIdentity
        : null;
  }

  Future<OnlineIdentityResetResult> _deleteOnlineDataAndReset({
    required OnlineRemoteDataDeletion deleteRemoteData,
    required Duration timeout,
  }) async {
    late final String? expectedIdentity;
    try {
      expectedIdentity = await readExisting();
    } catch (_) {
      return OnlineIdentityResetResult.persistenceFailed;
    }
    if (expectedIdentity == null) {
      return OnlineIdentityResetResult.noExistingIdentity;
    }

    try {
      await deleteRemoteData(expectedIdentity).timeout(timeout);
    } catch (_) {
      return OnlineIdentityResetResult.remoteDeletionFailed;
    }

    return _synchronized(() async {
      try {
        final SharedPreferences preferences = await _preferencesProvider();
        if (preferences.getString(storageKey) != expectedIdentity) {
          return OnlineIdentityResetResult.identityChanged;
        }
        await _replaceIdentity(preferences);
        return OnlineIdentityResetResult.reset;
      } catch (_) {
        return OnlineIdentityResetResult.persistenceFailed;
      }
    });
  }

  Future<String> _replaceIdentity(SharedPreferences preferences) async {
    final previousIdentity = preferences.getString(storageKey);
    final String identity = _idGenerator();
    if (!_isValidIdentity(identity) || identity == previousIdentity) {
      throw const OnlineIdentityPersistenceException(
        OnlineIdentityPersistenceError.invalidGeneratedIdentity,
      );
    }
    late final bool stored;
    try {
      stored = await preferences.setString(storageKey, identity);
    } catch (_) {
      await _restoreIdentity(preferences, previousIdentity);
      rethrow;
    }
    if (!stored) {
      await _restoreIdentity(preferences, previousIdentity);
      throw const OnlineIdentityPersistenceException(
        OnlineIdentityPersistenceError.writeFailed,
      );
    }
    return identity;
  }

  Future<void> _restoreIdentity(
    SharedPreferences preferences,
    String? previousIdentity,
  ) async {
    try {
      if (previousIdentity == null) {
        await preferences.remove(storageKey);
      } else {
        await preferences.setString(storageKey, previousIdentity);
      }
    } catch (_) {
      // Preserve the original replacement failure; callers can retry safely.
    }
  }

  static Future<T> _synchronized<T>(Future<T> Function() operation) {
    final Completer<T> completer = Completer<T>();
    _operationChain = _operationChain.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static bool _isValidIdentity(String value) =>
      value.length >= 8 &&
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}

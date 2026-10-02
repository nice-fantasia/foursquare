import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/ai/ai_player.dart';
import 'package:foursquare/meditation/meditation_session_controller.dart';
import 'package:foursquare/meditation/meditation_session_persistence.dart';
import 'package:foursquare/meditation/meditation_session_snapshot.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:hive/hive.dart';

void main() {
  final now = DateTime.utc(2026, 8, 1, 12);

  test('活跃会话 JSON 往返保留权威状态与剩余时间', () {
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      aiDifficulty: AIDifficulty.hard,
      now: () => now,
    )..completeOpening();
    controller.activateHumanPosition(const Position(0, 0));

    final snapshot = MeditationSessionSnapshot.capture(
      controller.session,
      now: now,
    );
    expect(snapshot.toJson(), isNot(contains('validMoves')));
    final decoded = MeditationSessionSnapshot.fromJson(snapshot.toJson());
    final restored = decoded.restoreController(now: () => now);

    expect(restored.session, controller.session);
    expect(
      restored.session.turnClock?.deadlineUtc,
      now.add(const Duration(seconds: 60)),
    );
  });

  test('活跃会话恢复时不消耗离线时间', () {
    var clock = now;
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => clock,
    )..completeOpening();
    clock = clock.add(const Duration(seconds: 23));
    final snapshot = MeditationSessionSnapshot.capture(
      controller.session,
      now: clock,
    );
    clock = clock.add(const Duration(days: 3));

    final restored = MeditationSessionSnapshot.fromJson(
      snapshot.toJson(),
    ).restoreController(now: () => clock);

    expect(
      restored.session.turnClock?.remainingAt(clock),
      const Duration(seconds: 37),
    );
  });

  test('暂停会话恢复后不消耗离线时间', () {
    var clock = now;
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => clock,
    )..completeOpening();
    clock = clock.add(const Duration(seconds: 17));
    controller.pause();

    final snapshot = MeditationSessionSnapshot.capture(
      controller.session,
      now: clock,
    );
    clock = clock.add(const Duration(days: 3));
    final restored = MeditationSessionSnapshot.fromJson(
      snapshot.toJson(),
    ).restoreController(now: () => clock);

    expect(restored.session.phase.name, 'paused');
    expect(
      restored.session.turnClock?.remainingAt(clock),
      const Duration(seconds: 43),
    );
  });

  test('剩余时间为零的活跃存档在恢复时立即结算超时', () {
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    )..completeOpening();
    final json = MeditationSessionSnapshot.capture(
      controller.session,
      now: now,
    ).toJson()
      ..['remainingMilliseconds'] = 0;

    final restored = MeditationSessionSnapshot.fromJson(
      json,
    ).restoreController(
      now: () => now.add(const Duration(days: 2)),
    );

    expect(restored.session.phase.name, 'completed');
    expect(restored.session.gameResult?.status.name, 'timeout');
  });

  test('解码对版本、枚举、坐标和时钟字段均失败关闭', () {
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    final valid = MeditationSessionSnapshot.capture(
      controller.session,
      now: now,
    ).toJson();

    expect(
      () => MeditationSessionSnapshot.fromJson({...valid, 'schemaVersion': 9}),
      throwsFormatException,
    );
    expect(
      () =>
          MeditationSessionSnapshot.fromJson({...valid, 'recordType': 'game'}),
      throwsFormatException,
    );
    expect(
      () => MeditationSessionSnapshot.fromJson({...valid, 'humanPlayer': 'x'}),
      throwsFormatException,
    );
    expect(
      () => MeditationSessionSnapshot.fromJson({
        ...valid,
        'selectedPosition': {'x': 9, 'y': 0},
      }),
      throwsFormatException,
    );
    expect(
      () => MeditationSessionSnapshot.fromJson({
        ...valid,
        'clockState': 'paused',
        'remainingMilliseconds': -1,
      }),
      throwsFormatException,
    );
  });

  test('逻辑被篡改的存档不能绕过严格恢复', () {
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    final json = MeditationSessionSnapshot.capture(
      controller.session,
      now: now,
    ).toJson();
    final board = Map<String, dynamic>.from(json['boardState'] as Map);
    final grid = (board['grid'] as List)
        .map((row) => List<String>.from(row as List))
        .toList();
    grid[1][1] = 'black';
    board['grid'] = grid;

    expect(
      () => MeditationSessionSnapshot.fromJson({
        ...json,
        'boardState': board,
      }),
      throwsFormatException,
    );
    // A structurally valid board still has to agree with its move history.
    grid[1][1] = 'empty';
    grid[0][0] = 'empty';
    grid[1][0] = 'black';
    board['blackPieces'] = [
      {'x': 0, 'y': 1},
      {'x': 1, 'y': 0},
      {'x': 2, 'y': 0},
      {'x': 3, 'y': 0},
    ];

    final decoded = MeditationSessionSnapshot.fromJson({
      ...json,
      'boardState': board,
    });
    expect(
      () => decoded.restoreController(now: () => now),
      throwsStateError,
    );
  });

  test('移动时间早于开局或倒序时恢复失败关闭', () {
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    )..completeOpening();
    controller.submitHumanMove(
      const Position(0, 0),
      const Position(0, 1),
    );
    controller.submitAiMove(
      const Position(0, 3),
      const Position(0, 2),
    );
    final valid = MeditationSessionSnapshot.capture(
      controller.session,
      now: now,
    ).toJson();
    final history = (valid['moveHistory'] as List)
        .map((move) => Map<String, dynamic>.from(move as Map))
        .toList();

    history.first['timestamp'] =
        now.subtract(const Duration(seconds: 1)).toIso8601String();
    var decoded = MeditationSessionSnapshot.fromJson({
      ...valid,
      'moveHistory': history,
    });
    expect(
      () => decoded.restoreController(now: () => now),
      throwsStateError,
    );

    history.first['timestamp'] = now.toIso8601String();
    history.last['timestamp'] =
        now.subtract(const Duration(milliseconds: 1)).toIso8601String();
    decoded = MeditationSessionSnapshot.fromJson({
      ...valid,
      'moveHistory': history,
    });
    expect(
      () => decoded.restoreController(now: () => now),
      throwsStateError,
    );
  });

  test('持久化协调器完成保存、恢复和删除闭环', () async {
    final repository = _MemoryRepository();
    final persistence = MeditationSessionPersistence(
      repository: repository,
      now: () => now,
    );
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    )..completeOpening();

    await persistence.save(controller.session);
    final restored = await persistence.restoreController();

    expect(restored?.session, controller.session);
    await persistence.clear();
    expect(await persistence.restoreController(), isNull);
  });

  test('Hive 适配器与普通对局存档隔离且损坏数据不伪装成空', () async {
    final temporaryDirectory =
        await Directory.systemTemp.createTemp('foursquare-meditation-');
    Hive.init(temporaryDirectory.path);
    final meditationBox = await Hive.openBox<dynamic>('meditation-test');
    final gameBox = await Hive.openBox<dynamic>('game-save-test');
    addTearDown(() async {
      await meditationBox.close();
      await gameBox.close();
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });
    await gameBox.put('current_game_save', {'id': 'ordinary-game'});
    final repository = HiveMeditationSessionRepository(meditationBox);
    final controller = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    );
    final openingSnapshot =
        MeditationSessionSnapshot.capture(controller.session, now: now);

    await repository.save(openingSnapshot);
    expect(
      (await repository.load())?.session.matchId,
      controller.session.matchId,
    );
    await repository.delete();
    expect(await repository.load(), isNull);
    expect(gameBox.get('current_game_save'), {'id': 'ordinary-game'});

    controller.completeOpening();
    await repository.save(
      MeditationSessionSnapshot.capture(controller.session, now: now),
    );
    expect(
      repository.save(openingSnapshot),
      throwsStateError,
    );
    final later = now.add(const Duration(seconds: 12));
    await repository.save(
      MeditationSessionSnapshot.capture(controller.session, now: later),
    );
    final rebased = (await repository.load())!.restoreController(
      now: () => later,
    );
    expect(
      rebased.session.turnClock?.remainingAt(later),
      const Duration(seconds: 48),
    );
    await repository.delete(matchId: 'another-match');
    expect(await repository.load(), isNotNull);
    await repository.delete(matchId: controller.session.matchId);
    expect(await repository.load(), isNull);

    final forkA = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    )..completeOpening();
    final forkB = MeditationSessionController.newGame(
      humanPlayer: PieceType.black,
      firstPlayer: PieceType.black,
      now: () => now,
    )..completeOpening();
    await repository.save(
      MeditationSessionSnapshot.capture(forkA.session, now: now),
    );
    forkA.activateHumanPosition(const Position(0, 0));
    forkB.activateHumanPosition(const Position(1, 0));
    final repositoryB = HiveMeditationSessionRepository(meditationBox);
    final writes = await Future.wait([
      repository
          .save(MeditationSessionSnapshot.capture(forkA.session, now: now))
          .then((_) => true)
          .catchError((_) => false),
      repositoryB
          .save(MeditationSessionSnapshot.capture(forkB.session, now: now))
          .then((_) => true)
          .catchError((_) => false),
    ]);
    expect(writes.where((succeeded) => succeeded), hasLength(1));
    expect(writes.where((succeeded) => !succeeded), hasLength(1));
    await repository.delete();

    await meditationBox.put(
      HiveMeditationSessionRepository.storageKey,
      42,
    );
    expect(repository.load, throwsFormatException);
  });
}

final class _MemoryRepository implements MeditationSessionRepository {
  MeditationSessionSnapshot? value;

  @override
  Future<void> delete({String? matchId}) async {
    if (matchId == null || value?.session.matchId == matchId) {
      value = null;
    }
  }

  @override
  Future<MeditationSessionSnapshot?> load() async => value;

  @override
  Future<void> save(MeditationSessionSnapshot snapshot) async {
    value = MeditationSessionSnapshot.fromJson(snapshot.toJson());
  }
}

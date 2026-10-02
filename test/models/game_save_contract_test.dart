import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/game_save.dart';
import 'package:foursquare/models/move.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';

void main() {
  test('正式存档往返保留规则状态和双吃记录', () {
    final move = Move(
      from: const Position(0, 1),
      to: const Position(1, 1),
      player: PieceType.black,
      capturedPieces: const [Position(3, 1), Position(1, 2)],
      timestamp: DateTime.utc(2026, 8, 1, 10, 30),
    );
    final save = GameSave(
      schemaVersion: 2,
      id: 'game-1',
      saveTime: DateTime.utc(2026, 8, 1, 10, 31),
      matchId: 'match-1',
      startedAt: DateTime.utc(2026, 8, 1, 10),
      boardState: BoardStateData.fromBoardState(BoardState.initial()),
      moveHistory: [MoveData.fromMove(move)],
      currentPlayer: 'white',
      startingPlayer: 'black',
      noCapturePlyCount: 17,
      turnRemainingMilliseconds: 42000,
      mode: 'pvp',
    );

    final restored = GameSave.fromJson(save.toJson());
    final restoredMove = restored.moveHistory.single.toMove();

    expect(restored.schemaVersion, 2);
    expect(restored.matchId, 'match-1');
    expect(restored.startedAt, DateTime.utc(2026, 8, 1, 10));
    expect(restored.startingPlayer, 'black');
    expect(restored.noCapturePlyCount, 17);
    expect(restored.turnRemainingMilliseconds, 42000);
    expect(
      restoredMove.capturedPieces,
      const [Position(3, 1), Position(1, 2)],
    );
    expect(restoredMove.player, PieceType.black);
    expect(restoredMove.timestamp, DateTime.utc(2026, 8, 1, 10, 30));
  });

  test('v1存档缺少新增字段时按既有兼容规则恢复', () {
    final json = <String, dynamic>{
      'id': 'legacy-game',
      'saveTime': '2026-08-01T10:31:00.000Z',
      'boardState':
          BoardStateData.fromBoardState(BoardState.initial()).toJson(),
      'moveHistory': <Map<String, dynamic>>[
        <String, dynamic>{
          'from': const PositionData(x: 0, y: 0).toJson(),
          'to': const PositionData(x: 0, y: 1).toJson(),
          'capturedPosition': const PositionData(x: 3, y: 3).toJson(),
          'capturedPiece': 'black',
        },
      ],
      'currentPlayer': 'white',
      'mode': 'pvp',
    };

    final restored = GameSave.fromJson(json);
    final restoredMove = restored.moveHistory.single.toMove();

    expect(restored.schemaVersion, 1);
    expect(restored.startingPlayer, 'black');
    expect(restored.noCapturePlyCount, 0);
    expect(restored.turnRemainingMilliseconds, 60000);
    expect(restoredMove.player, PieceType.black);
    expect(restoredMove.capturedPieces, const [Position(3, 3)]);
    expect(
      restoredMove.timestamp,
      DateTime.fromMillisecondsSinceEpoch(0),
    );
  });
}

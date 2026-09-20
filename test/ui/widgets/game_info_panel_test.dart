import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/models/move.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/ui/widgets/game_info_panel.dart';

void main() {
  testWidgets('显示60秒回合计时并启用可用的撤销重做操作', (tester) async {
    var undoCount = 0;
    var redoCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GameInfoPanel(
            currentPlayer: PieceType.black,
            blackPieceCount: 4,
            whitePieceCount: 4,
            moveHistory: const [],
            canUndo: true,
            canRedo: true,
            turnRemaining: const Duration(seconds: 42),
            onUndo: () => undoCount++,
            onRedo: () => redoCount++,
          ),
        ),
      ),
    );

    expect(find.text('墨方回合'), findsOneWidget);
    expect(find.text('42 秒'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.tap(find.text('重做'));
    expect(undoCount, 1);
    expect(redoCount, 1);
  });

  testWidgets('turn and controls are localized in English', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GameInfoPanel(
            currentPlayer: PieceType.white,
            blackPieceCount: 4,
            whitePieceCount: 4,
            moveHistory: [],
            canUndo: false,
            canRedo: false,
            turnRemaining: Duration(seconds: 9),
          ),
        ),
      ),
    );

    expect(find.text("Jade's turn"), findsOneWidget);
    expect(find.text('9 sec'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('move history uses localized one-based board coordinates', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GameInfoPanel(
            currentPlayer: PieceType.black,
            blackPieceCount: 4,
            whitePieceCount: 4,
            moveHistory: [
              Move(
                from: const Position(0, 0),
                to: const Position(0, 1),
                player: PieceType.black,
                timestamp: DateTime(2026),
              ),
            ],
            canUndo: false,
            canRedo: false,
          ),
        ),
      ),
    );

    expect(find.text('第 1 行，第 1 列 → 第 2 行，第 1 列'), findsOneWidget);
    expect(find.textContaining('Position('), findsNothing);
  });

  testWidgets('move history coordinates follow a flipped board',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GameInfoPanel(
            currentPlayer: PieceType.white,
            blackPieceCount: 4,
            whitePieceCount: 4,
            moveHistory: [
              Move(
                from: const Position(3, 3),
                to: const Position(3, 2),
                player: PieceType.white,
                timestamp: DateTime(2026),
              ),
            ],
            canUndo: false,
            canRedo: false,
            flipBoard: true,
          ),
        ),
      ),
    );

    expect(find.text('第 1 行，第 1 列 → 第 2 行，第 1 列'), findsOneWidget);
    expect(find.textContaining('Position('), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/models/move.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/ui/screens/game_replay_page.dart';

void main() {
  testWidgets('replay controls and guide use the selected locale',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GameReplayPage(moveHistory: []),
      ),
    );

    expect(find.text('Game replay'), findsOneWidget);
    expect(find.text('Initial'), findsOneWidget);

    await tester.tap(find.byTooltip('Replay guide'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Controls:'), findsOneWidget);
    expect(find.textContaining('read-only'), findsOneWidget);
  });

  testWidgets('replay move history uses localized board coordinates', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GameReplayPage(
          moveHistory: [
            Move(
              from: const Position(0, 0),
              to: const Position(0, 1),
              player: PieceType.black,
              timestamp: DateTime(2026),
            ),
          ],
        ),
      ),
    );

    expect(find.text('Row 1, column 1 → Row 2, column 1'), findsWidgets);
    expect(find.textContaining('Position('), findsNothing);
  });
}

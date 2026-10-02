import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/theme/packs/modern_eastern_theme_pack.dart';
import 'package:foursquare/ui/widgets/animated_board_widget.dart';
import 'package:foursquare/ui/widgets/board_painter.dart';
import 'package:foursquare/ui/widgets/themed_board_widget.dart';

void main() {
  for (final action in ['restart', 'undo', 'reduce', 'dispose']) {
    testWidgets('$action cancels queued presentation and stale completion',
        (tester) async {
      final initial = BoardState.initial();
      final first = initial
          .movePiece(const Position(0, 0), const Position(0, 1))
          .switchPlayer();
      final second = first
          .movePiece(const Position(0, 3), const Position(0, 2))
          .switchPlayer();
      final completions = <String>[];
      Widget view(int step, {String id = 'old', bool reduced = false}) =>
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: ThemedBoardWidget(
                presentationId: id,
                moveNumber: step,
                boardState: [initial, first, second][step],
                lastMoveFrom: step == 0
                    ? null
                    : (step == 1 ? const Position(0, 0) : const Position(0, 3)),
                lastMoveTo: step == 0
                    ? null
                    : (step == 1 ? const Position(0, 1) : const Position(0, 2)),
                size: 320,
                onPositionTapped: (_) {},
                onPresentationComplete: (move) => completions.add('$id:$move'),
              ),
            ),
          );
      await tester.pumpWidget(view(0));
      await tester.pumpWidget(view(1));
      await tester.pumpWidget(view(2));
      completions.clear();
      switch (action) {
        case 'restart':
          await tester.pumpWidget(view(0, id: 'new'));
        case 'undo':
          await tester.pumpWidget(view(0));
        case 'reduce':
          await tester.pumpWidget(view(2, reduced: true));
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
      }
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      if (action == 'dispose') {
        expect(completions, isEmpty);
      } else {
        final expected = action == 'reduce' ? second : initial;
        expect(
          tester
              .widget<AnimatedBoardWidget>(find.byType(AnimatedBoardWidget))
              .boardState,
          expected,
        );
        expect(completions, isNotEmpty);
        expect(
          completions.every(
            (value) =>
                value ==
                (action == 'restart'
                    ? 'new:0'
                    : action == 'reduce'
                        ? 'old:2'
                        : 'old:0'),
          ),
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a quick reply waits for the preceding capture presentation',
      (tester) async {
    final before = BoardState.initial()
        .setPiece(const Position(0, 1), PieceType.black)
        .setPiece(const Position(3, 1), PieceType.white);
    final capture = before
        .movePiece(const Position(0, 1), const Position(1, 1))
        .removePiece(const Position(3, 1))
        .switchPlayer();
    final reply = capture
        .movePiece(const Position(0, 3), const Position(0, 2))
        .switchPlayer();
    Widget view(int step) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ThemedBoardWidget(
            presentationId: 'game',
            moveNumber: step,
            boardState: [before, capture, reply][step],
            lastMoveFrom: step == 0
                ? null
                : (step == 1 ? const Position(0, 1) : const Position(0, 3)),
            lastMoveTo: step == 0
                ? null
                : (step == 1 ? const Position(1, 1) : const Position(0, 2)),
            capturedPiecePositions:
                step == 1 ? const [Position(3, 1)] : const [],
            size: 320,
            onPositionTapped: (_) {},
          ),
        );
    await tester.pumpWidget(view(0));
    await tester.pump();
    await tester.pumpWidget(view(1));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(view(2));
    expect(
      tester
          .widget<AnimatedBoardWidget>(find.byType(AnimatedBoardWidget))
          .boardState,
      capture,
    );
    expect(find.byKey(const ValueKey('captured-piece-3-1')), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<AnimatedBoardWidget>(find.byType(AnimatedBoardWidget))
          .boardState,
      reply,
    );
  });

  testWidgets('主题包注入且系统减少动态会关闭动画和粒子', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: ThemedBoardWidget(
            boardState: BoardState.initial(),
            themePack: modernEasternThemePack,
            size: 320,
            onPositionTapped: (_) {},
          ),
        ),
      ),
    );

    final animatedBoard = tester.widget<AnimatedBoardWidget>(
      find.byType(AnimatedBoardWidget),
    );
    expect(animatedBoard.animationEnabled, isFalse);
    expect(animatedBoard.particleEnabled, isFalse);
    final adapter = animatedBoard.theme! as ThemePackBoardThemeAdapter;
    expect(adapter.themePack, same(modernEasternThemePack));
  });

  testWidgets('主题棋盘会向动画棋盘传递全部被吃位置', (WidgetTester tester) async {
    const capturedPieces = [Position(1, 1), Position(2, 2)];

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ThemedBoardWidget(
          boardState: BoardState.initial(),
          capturedPiecePositions: capturedPieces,
          size: 320,
          onPositionTapped: (_) {},
        ),
      ),
    );

    final animatedBoard = tester.widget<AnimatedBoardWidget>(
      find.byType(AnimatedBoardWidget),
    );
    expect(animatedBoard.capturedPiecePositions, capturedPieces);
  });
}

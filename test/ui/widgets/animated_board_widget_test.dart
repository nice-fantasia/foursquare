import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/ui/widgets/animated_board_widget.dart';
import 'package:foursquare/ui/widgets/board_painter.dart';

void main() {
  Widget board({Position? selected, bool enabled = true}) => MaterialApp(
        home: AnimatedBoardWidget(
          boardState: BoardState.initial(),
          selectedPiece: selected,
          animationEnabled: enabled,
          vibrationEnabled: false,
          size: 320,
          onPositionTapped: (_) {},
        ),
      );

  testWidgets('an idle board settles without a perpetual selection ticker',
      (tester) async {
    await tester.pumpWidget(board());
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 1),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('selection pulse repaints and stops when deselected',
      (tester) async {
    await tester.pumpWidget(board(selected: const Position(0, 0)));
    BoardPainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<BoardPainter>()
        .single;
    final before = painter().selectionPulse!;
    await tester.pump(const Duration(milliseconds: 750));
    expect(painter().selectionPulse, greaterThan(before));
    await tester.pumpWidget(board());
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 1),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('disabling motion stops selected piece pulse immediately',
      (tester) async {
    await tester.pumpWidget(board(selected: const Position(0, 0)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester
        .pumpWidget(board(selected: const Position(0, 0), enabled: false));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 1),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('同时为本次移动的所有被吃棋子显示动画反馈', (WidgetTester tester) async {
    const horizontalCapture = Position(1, 1);
    const verticalCapture = Position(2, 2);
    final beforeCapture = BoardState.initial()
        .setPiece(horizontalCapture, PieceType.white)
        .setPiece(verticalCapture, PieceType.white);
    final afterCapture = beforeCapture
        .removePiece(horizontalCapture)
        .removePiece(verticalCapture);

    Widget buildBoard(
      BoardState boardState,
      List<Position> capturedPiecePositions,
    ) {
      return MaterialApp(
        home: AnimatedBoardWidget(
          boardState: boardState,
          capturedPiecePositions: capturedPiecePositions,
          vibrationEnabled: false,
          size: 320,
          onPositionTapped: (_) {},
        ),
      );
    }

    await tester.pumpWidget(buildBoard(beforeCapture, const []));
    await tester.pumpWidget(
      buildBoard(
        afterCapture,
        const [horizontalCapture, verticalCapture],
      ),
    );

    expect(
      find.byKey(const ValueKey('captured-piece-1-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('captured-piece-2-2')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 450));

    expect(
      find.byKey(const ValueKey('captured-piece-1-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('captured-piece-2-2')),
      findsNothing,
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/models/board_state.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/models/position.dart';
import 'package:foursquare/ui/widgets/animated_board_widget.dart';
import 'package:foursquare/ui/widgets/board_painter.dart';

void main() {
  testWidgets(
      'double capture has one haptic with animations off and respects vibration off',
      (tester) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const victims = [Position(3, 1), Position(1, 2)];
    final initial = BoardState.initial()
        .setPiece(const Position(0, 1), PieceType.black)
        .setPiece(victims[0], PieceType.white)
        .setPiece(victims[1], PieceType.white);
    final captured = initial
        .movePiece(const Position(0, 1), const Position(1, 1))
        .removePiece(victims[0])
        .removePiece(victims[1]);
    Widget view(bool moved, bool vibration) => MaterialApp(
          home: AnimatedBoardWidget(
            boardState: moved ? captured : initial,
            lastMoveFrom: moved ? const Position(0, 1) : null,
            lastMoveTo: moved ? const Position(1, 1) : null,
            capturedPiecePositions: moved ? victims : const [],
            animationEnabled: false,
            vibrationEnabled: vibration,
            onPositionTapped: (_) {},
            size: 320,
          ),
        );
    await tester.pumpWidget(view(false, true));
    await tester.pumpWidget(view(true, true));
    await tester.pumpWidget(view(true, true));
    expect(calls, ['HapticFeedbackType.mediumImpact']);
    await tester.pumpWidget(view(false, false));
    await tester.pumpWidget(view(true, false));
    expect(calls.length, 1);
  });

  testWidgets('captured piece stays visible until the moving piece arrives',
      (tester) async {
    const from = Position(0, 1);
    const to = Position(1, 1);
    const victim = Position(3, 1);
    final before = BoardState.initial()
        .setPiece(from, PieceType.black)
        .setPiece(victim, PieceType.white);
    final after = before.movePiece(from, to).removePiece(victim);
    Widget view(bool moved) => MaterialApp(
          home: AnimatedBoardWidget(
            boardState: moved ? after : before,
            lastMoveFrom: moved ? from : null,
            lastMoveTo: moved ? to : null,
            capturedPiecePositions: moved ? const [victim] : const [],
            vibrationEnabled: false,
            size: 320,
            onPositionTapped: (_) {},
          ),
        );
    await tester.pumpWidget(view(false));
    await tester.pumpWidget(view(true));
    final capture = find.byKey(const ValueKey('captured-piece-3-1'));
    double opacity() => tester
        .widget<Opacity>(
          find.descendant(of: capture, matching: find.byType(Opacity)),
        )
        .opacity;
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(), 1);
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(), greaterThan(0));
    expect(opacity(), lessThan(1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(capture, findsNothing);
  });

  testWidgets(
      'haptics follow accepted selection and moves with motion disabled',
      (tester) async {
    final feedback = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        feedback.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final before = BoardState.initial();
    final moved = before
        .movePiece(const Position(0, 0), const Position(0, 1))
        .switchPlayer();
    Widget view(
      BoardState state, {
      Position? selected,
      bool move = false,
      bool vibration = true,
    }) =>
        MaterialApp(
          home: AnimatedBoardWidget(
            boardState: state,
            selectedPiece: selected,
            lastMoveFrom: move ? const Position(0, 0) : null,
            lastMoveTo: move ? const Position(0, 1) : null,
            animationEnabled: false,
            vibrationEnabled: vibration,
            onPositionTapped: (_) {},
            size: 320,
          ),
        );
    await tester.pumpWidget(view(before));
    await tester.pumpWidget(view(before, selected: const Position(0, 0)));
    await tester.pumpWidget(view(moved, move: true));
    await tester.pumpWidget(view(moved, move: true));
    expect(feedback, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
    ]);
    await tester.pumpWidget(
      view(
        moved,
        move: true,
        selected: const Position(0, 3),
        vibration: false,
      ),
    );
    expect(feedback.length, 2);
  });

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

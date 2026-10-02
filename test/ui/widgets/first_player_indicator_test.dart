import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/ui/widgets/first_player_indicator.dart';

Widget _testApp({
  required Locale locale,
  required PieceType firstPlayer,
  bool reduceMotion = false,
  VoidCallback? completed,
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      body: FirstPlayerIndicator(
        firstPlayer: firstPlayer,
        duration: 10000,
        onAnimationComplete: completed,
      ),
    ),
  );
}

void main() {
  testWidgets('reduced motion keeps the announcement static until its deadline',
      (tester) async {
    var completed = 0;
    await tester.pumpWidget(
      _testApp(
        locale: const Locale('en'),
        firstPlayer: PieceType.black,
        reduceMotion: true,
        completed: () => completed++,
      ),
    );
    await tester.pump();
    final indicator = find.byType(FirstPlayerIndicator);
    final opacity = tester.widget<Opacity>(
      find.descendant(of: indicator, matching: find.byType(Opacity)),
    );
    final transform = tester.widget<Transform>(
      find.descendant(of: indicator, matching: find.byType(Transform)),
    );
    expect(opacity.opacity, 1);
    expect(transform.transform.getMaxScaleOnAxis(), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 9));
    expect(completed, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);
  });

  testWidgets('disposing a static announcement cancels its completion callback',
      (tester) async {
    var completed = 0;
    await tester.pumpWidget(
      _testApp(
        locale: const Locale('en'),
        firstPlayer: PieceType.black,
        reduceMotion: true,
        completed: () => completed++,
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
    expect(completed, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'changing motion preference preserves the original completion deadline',
      (tester) async {
    var completed = 0;
    Widget app(bool reduced) => _testApp(
          locale: const Locale('en'),
          firstPlayer: PieceType.black,
          reduceMotion: reduced,
          completed: () => completed++,
        );
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(seconds: 6));
    expect(completed, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);
  });

  testWidgets('shows and announces the English first player message', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _testApp(
        locale: const Locale('en'),
        firstPlayer: PieceType.black,
      ),
    );

    expect(find.text('Ink moves first'), findsOneWidget);
    expect(find.text('The game is about to begin'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Ink moves first. The game is about to begin',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('游戏即将开始'), findsNothing);
    semantics.dispose();
  });

  testWidgets('shows and announces the Japanese first player message', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _testApp(
        locale: const Locale('ja'),
        firstPlayer: PieceType.white,
      ),
    );

    expect(find.text('玉方が先手'), findsOneWidget);
    expect(find.text('まもなく対局開始'), findsOneWidget);
    expect(
      find.bySemanticsLabel('玉方が先手。まもなく対局開始'),
      findsOneWidget,
    );
    expect(find.textContaining('游戏即将开始'), findsNothing);
    semantics.dispose();
  });
}

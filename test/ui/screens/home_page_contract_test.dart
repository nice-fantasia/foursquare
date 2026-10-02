import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/ui/screens/home_page.dart';

void main() {
  Widget app({
    required Future<bool> Function() hasSavedGame,
    Locale locale = const Locale('zh'),
  }) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomePage(
        hasSavedGame: hasSavedGame,
        enableResourceWarmup: false,
      ),
    );
  }

  testWidgets('一期首页有存档时显示继续游戏且不暴露后续阶段入口', (tester) async {
    await tester.pumpWidget(app(hasSavedGame: () async => true));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('continue_game_button')), findsOneWidget);
    expect(find.text('继续游戏'), findsOneWidget);
    expect(find.text('冥想模式'), findsNothing);
    expect(find.text('在线对战'), findsNothing);
  });

  testWidgets('一期首页无存档时不显示继续游戏', (tester) async {
    await tester.pumpWidget(app(hasSavedGame: () async => false));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('continue_game_button')), findsNothing);
  });

  testWidgets(
      'home presents the same phase-one actions in English and Japanese', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(hasSavedGame: () async => true, locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('LAN Game'), findsOneWidget);

    await tester.pumpWidget(
      app(hasSavedGame: () async => true, locale: const Locale('ja')),
    );
    await tester.pumpAndSettle();
    expect(find.text('続きから'), findsOneWidget);
    expect(find.text('LAN 対戦'), findsOneWidget);
  });

  testWidgets('一期首页在窄屏和两倍文字下仍可滚动及操作', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(app(hasSavedGame: () async => true));
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.byKey(const Key('continue_game_button')), findsOneWidget);
    expect(find.text('双人对战'), findsOneWidget);
    expect(find.text('人机对战'), findsOneWidget);
    expect(find.text('局域网对战'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^双人对战，')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^人机对战，')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('一期首页在宽屏使用两列布局且保持完整', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(hasSavedGame: () async => true));
    await tester.pumpAndSettle();

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byKey(const Key('continue_game_button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

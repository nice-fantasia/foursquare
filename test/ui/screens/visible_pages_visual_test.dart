import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/bloc/lan_lobby_bloc.dart';
import 'package:foursquare/bloc/lan_lobby_event.dart';
import 'package:foursquare/bloc/lan_lobby_state.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/theme/packs/modern_eastern_theme_pack.dart';
import 'package:foursquare/ui/screens/lan/lan_lobby_page.dart';
import 'package:foursquare/ui/screens/onboarding_page.dart';

class _MockLanLobbyBloc extends MockBloc<LanLobbyEvent, LanLobbyState>
    implements LanLobbyBloc {}

void main() {
  testWidgets('onboarding 五个分页均可在窄屏独立滚动', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: modernEasternThemePack.themeData,
        home: const OnboardingPage(),
      ),
    );

    expect(find.widgetWithText(FilledButton, '下一页'), findsOneWidget);
    for (var page = 0; page < 5; page++) {
      expect(
        find.descendant(
          of: find.byType(PageView),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      if (page < 4) {
        await tester.drag(find.byType(PageView), const Offset(-300, 0));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('onboarding 横屏为可滚动内容显示常驻滚动提示', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: modernEasternThemePack.themeData,
        home: const OnboardingPage(),
      ),
    );
    await tester.pump();

    final pageScrollView = find
        .descendant(
          of: find.byType(PageView),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    final pageScrollable = find
        .descendant(
          of: pageScrollView,
          matching: find.byType(Scrollable),
        )
        .first;
    final scrollPosition =
        tester.state<ScrollableState>(pageScrollable).position;

    expect(scrollPosition.maxScrollExtent, greaterThan(0));
    final scrollbarFinder = find.descendant(
      of: find.byType(PageView),
      matching: find.byType(Scrollbar),
    );
    expect(scrollbarFinder, findsWidgets);
    expect(
      tester.widget<Scrollbar>(scrollbarFinder.first).thumbVisibility,
      isTrue,
    );

    await tester.drag(pageScrollView, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(scrollPosition.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('LAN 创建页在窄屏可滚动且主操作至少 48px', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bloc = _MockLanLobbyBloc();
    whenListen(
      bloc,
      const Stream<LanLobbyState>.empty(),
      initialState: const LanLobbyState(),
    );
    addTearDown(bloc.close);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: modernEasternThemePack.themeData,
        home: BlocProvider<LanLobbyBloc>.value(
          value: bloc,
          child: const LanLobbyView(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final createButton = find.byKey(const Key('lan_create_room_button'));
    expect(createButton, findsOneWidget);
    expect(tester.getSize(createButton).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('LAN failure category is presented as localized safe copy', (
    WidgetTester tester,
  ) async {
    final bloc = _MockLanLobbyBloc();
    whenListen(
      bloc,
      Stream.value(
        const LanLobbyState(
          status: LanLobbyStatus.failure,
          failure: LanLobbyFailure.discovery,
        ),
      ),
      initialState: const LanLobbyState(),
    );
    addTearDown(bloc.close);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ja'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: modernEasternThemePack.themeData,
        home: BlocProvider<LanLobbyBloc>.value(
          value: bloc,
          child: const LanLobbyView(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('近くの部屋を検索できません'), findsOneWidget);
  });
}

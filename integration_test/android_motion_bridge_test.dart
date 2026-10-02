import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:foursquare/l10n/app_localizations.dart';
import 'package:foursquare/models/piece_type.dart';
import 'package:foursquare/ui/widgets/first_player_indicator.dart';

// Run only on a dedicated Android AVD after setting all three system animation
// scales to zero. The executor restores them after this bounded test.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android reduced-motion bridge renders a stationary announcement',
    (tester) async {
      expect(
        binding.platformDispatcher.accessibilityFeatures.disableAnimations,
        isTrue,
      );
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: FirstPlayerIndicator(
              firstPlayer: PieceType.black,
              duration: 10000,
              onAnimationComplete: () => completed++,
            ),
          ),
        ),
      );
      await tester.pump();
      final indicator = find.byType(FirstPlayerIndicator);
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: indicator,
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      double scale() => tester
          .widget<Transform>(
            find.descendant(
              of: indicator,
              matching: find.byType(Transform),
            ),
          )
          .transform
          .getMaxScaleOnAxis();
      expect(
        MediaQuery.of(tester.element(indicator)).disableAnimations,
        isTrue,
      );
      expect(opacity(), 1);
      expect(scale(), 1);
      await tester.pump(const Duration(milliseconds: 750));
      expect(opacity(), 1);
      expect(scale(), 1);
      expect(completed, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}

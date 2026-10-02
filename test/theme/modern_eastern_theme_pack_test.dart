import 'package:flutter_test/flutter_test.dart';
import 'package:foursquare/theme/packs/modern_eastern_theme_pack.dart';
import 'package:foursquare/theme/theme_pack.dart';

void main() {
  test('modern eastern is a production theme with the agreed identity', () {
    final pack = modernEasternThemePack;

    expect(pack.id, 'modern_eastern');
    expect(pack.schemaVersion, 1);
    expect(pack.displayName, '现代东方棋艺');
    expect(pack.themeData.useMaterial3, isTrue);
    expect(pack.colors.paperBase.toARGB32(), 0xFFF3EBDD);
    expect(pack.colors.inkPrimary.toARGB32(), 0xFF1F2621);
    expect(pack.colors.cinnabar.toARGB32(), 0xFFB44737);
  });

  test('board and pieces remain distinguishable without color', () {
    final pack = modernEasternThemePack;

    expect(pack.board.gridLineWidth, greaterThan(0));
    expect(pack.board.frameLineWidth, greaterThan(pack.board.gridLineWidth));
    expect(pack.board.selectionMarker, BoardMarkerShape.doubleCorners);
    expect(pack.board.validMoveMarker, BoardMarkerShape.dotAndTick);
    expect(pack.pieces.inkSide.marker, PieceMarkerShape.fourPointSeal);
    expect(pack.pieces.jadeSide.marker, PieceMarkerShape.concentricRing);
    expect(
      pack.pieces.inkSide.marker,
      isNot(pack.pieces.jadeSide.marker),
    );
  });

  test('reduced motion removes nonessential animation but keeps audio mapped',
      () {
    final pack = modernEasternThemePack;
    final reduced = pack.motion.resolve(reduceMotion: true);

    expect(pack.motion.moveDuration, const Duration(milliseconds: 320));
    expect(pack.motion.captureDuration, const Duration(milliseconds: 680));
    expect(reduced.pageTransitionDuration, Duration.zero);
    expect(reduced.moveDuration, Duration.zero);
    expect(reduced.captureDuration, Duration.zero);
    expect(reduced.selectionPulseEnabled, isFalse);
    expect(reduced.particlesEnabled, isFalse);
    expect(pack.audio.move, 'assets/sounds/move.wav');
    expect(pack.audio.capture, 'assets/sounds/capture.wav');
    expect(pack.audio.gameplayMusic, 'assets/sounds/music/gameplay.wav');
  });

  test('theme data and layout tokens form one coherent application identity',
      () {
    final pack = modernEasternThemePack;

    expect(pack.typography.displayFontFamily, 'LXGWWenKaiScreen');
    expect(pack.typography.bodyFontFamily, 'NotoSansSC');
    expect(
      pack.themeData.textTheme.displayLarge?.fontFamily,
      pack.typography.displayFontFamily,
    );
    expect(
      pack.themeData.textTheme.bodyMedium?.fontFamily,
      pack.typography.bodyFontFamily,
    );
    expect(pack.themeData.scaffoldBackgroundColor, pack.colors.paperBase);
    expect(pack.themeData.colorScheme.primary, pack.colors.jade);
    expect(pack.spacing.minimumTapTarget, 48);
    expect(pack.shapes.controlRadius, 12);
  });
}

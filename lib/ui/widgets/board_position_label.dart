import '../../constants/game_constants.dart';
import '../../l10n/app_localizations.dart';
import '../../models/position.dart';

String formatBoardPositionLabel(
  AppLocalizations l10n,
  Position position, {
  bool flipBoard = false,
}) {
  final displayX =
      flipBoard ? GameConstants.boardSize - position.x - 1 : position.x;
  final displayY =
      flipBoard ? GameConstants.boardSize - position.y - 1 : position.y;
  return l10n.boardCellPosition(displayY + 1, displayX + 1);
}

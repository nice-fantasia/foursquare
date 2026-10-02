import 'package:foursquare/models/board_state.dart';

/// Benchmark-only position recurrence; it never adjudicates a game result.
class PositionRepetitionDiagnostics {
  final Map<String, int> _visits = {};
  final Map<String, int> _lastSeen = {};
  int _observations = 0;
  int _revisits = 0;
  int _maxVisits = 0;
  int? _shortestCycle;

  int get revisits => _revisits;
  int get maxVisits => _maxVisits;
  int? get shortestCycle => _shortestCycle;

  void observe(BoardState board) {
    // Ignore piece-list ordering; recurrence means the grid and side to move.
    final key = '${board.grid}:${board.currentPlayer}';
    final visits = (_visits[key] ?? 0) + 1;
    _visits[key] = visits;
    if (visits > 1) _revisits++;
    if (visits > _maxVisits) _maxVisits = visits;
    final previous = _lastSeen[key];
    if (previous != null) {
      final gap = _observations - previous;
      if (_shortestCycle == null || gap < _shortestCycle!) _shortestCycle = gap;
    }
    _lastSeen[key] = _observations++;
  }
}

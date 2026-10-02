import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';

import '../../constants/ui_constants.dart';
import '../../models/board_state.dart';
import '../../models/position.dart';
import '../../services/storage_service.dart';
import '../../theme/theme_pack.dart';
import '../../theme/theme_pack_registry.dart';
import 'animated_board_widget.dart';
import 'board_painter.dart';
import 'board_widget.dart';

class ThemedBoardWidget extends StatefulWidget {
  const ThemedBoardWidget({
    super.key,
    required this.boardState,
    required this.onPositionTapped,
    this.selectedPiece,
    this.validMoves = const [],
    this.lastMoveFrom,
    this.lastMoveTo,
    this.capturedPiecePositions = const [],
    this.size,
    this.flipBoard = false,
    this.themePack,
    this.moveNumber,
    this.presentationId,
    this.onPresentationComplete,
    this.interactive = true,
  });

  final BoardState boardState;
  final Position? selectedPiece;
  final List<Position> validMoves;
  final Position? lastMoveFrom;
  final Position? lastMoveTo;
  final List<Position> capturedPiecePositions;
  final ValueChanged<Position> onPositionTapped;
  final double? size;
  final bool flipBoard;

  /// Optional injection seam used by previews, tests and future theme packs.
  /// The phase-one registry supplies modern eastern when omitted.
  final ThemePack? themePack;
  final int? moveNumber;
  final Object? presentationId;
  final ValueChanged<int?>? onPresentationComplete;
  final bool interactive;

  @override
  State<ThemedBoardWidget> createState() => _ThemedBoardWidgetState();
}

class _ThemedBoardWidgetState extends State<ThemedBoardWidget> {
  final StorageService _storageService = StorageService();
  final ThemePackRegistry _themeRegistry = ThemePackRegistry.phaseOne();
  bool _animationEnabled = true;
  bool _particleEnabled = true;
  bool _vibrationEnabled = true;
  late ThemedBoardWidget _presented;
  final Queue<ThemedBoardWidget> _pending = Queue();
  Timer? _settleTimer;
  bool _presenting = false;
  bool _systemReduceMotion = false;
  bool _feedbackEnabled = true;
  int _presentationGeneration = 0;

  ThemePack get _themePack => widget.themePack ?? _themeRegistry.defaultPack;

  @override
  void initState() {
    super.initState();
    _presented = widget;
    _notifyComplete();
    _loadSettings();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduced != _systemReduceMotion) {
      _systemReduceMotion = reduced;
      if (reduced) _resetPresentation();
    }
  }

  @override
  void didUpdateWidget(ThemedBoardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final forward = widget.presentationId == oldWidget.presentationId &&
        widget.moveNumber != null &&
        oldWidget.moveNumber != null &&
        widget.moveNumber == oldWidget.moveNumber! + 1;
    if (forward &&
        _animationEnabled &&
        !_systemReduceMotion &&
        _themePack.motion.moveDuration > Duration.zero) {
      if (_presenting) {
        _pending.add(widget);
      } else {
        _startPresentation(widget);
      }
    } else if (widget.presentationId != oldWidget.presentationId ||
        widget.moveNumber != oldWidget.moveNumber ||
        (widget.boardState != oldWidget.boardState && !forward)) {
      _resetPresentation(feedbackEnabled: forward || widget.moveNumber == null);
    } else if (_presented.moveNumber == widget.moveNumber) {
      _presented = widget;
      _feedbackEnabled = true;
      if (!_presenting) _notifyComplete();
    }
  }

  void _startPresentation(ThemedBoardWidget frame) {
    _presentationGeneration++;
    _presented = frame;
    _feedbackEnabled = true;
    _presenting = true;
  }

  void _onMoveCompleted(ThemedBoardWidget frame) {
    if (!_presenting || !identical(frame, _presented) || _settleTimer != null) {
      return;
    }
    _settleTimer = Timer(_themePack.motion.stateChangeDuration, () {
      if (!mounted) return;
      _settleTimer = null;
      setState(() {
        _presenting = false;
        if (_pending.isNotEmpty) {
          _startPresentation(_pending.removeFirst());
        } else {
          _presented = widget;
          _notifyComplete();
        }
      });
    });
  }

  void _resetPresentation({bool feedbackEnabled = false}) {
    _presentationGeneration++;
    _settleTimer?.cancel();
    _settleTimer = null;
    _pending.clear();
    _presenting = false;
    _presented = widget;
    _feedbackEnabled = feedbackEnabled;
    _notifyComplete();
  }

  void _notifyComplete() {
    final generation = _presentationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_presenting && generation == _presentationGeneration) {
        widget.onPresentationComplete?.call(_presented.moveNumber);
      }
    });
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _pending.clear();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settings = await _storageService.loadSettings();
    if (!mounted) return;
    setState(() {
      _animationEnabled = settings.animationEnabled;
      _particleEnabled = settings.particleEnabled;
      _vibrationEnabled = settings.vibrationEnabled;
      if (!_animationEnabled) _resetPresentation();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    final systemReduceMotion = mediaQuery?.disableAnimations ?? false;
    final reduceMotion = systemReduceMotion || !_animationEnabled;
    final effectiveMotion = _themePack.motion.resolve(
      reduceMotion: reduceMotion,
    );
    final boardSize = widget.size ?? _calculateBoardSize(context);
    final frame = _presented;

    return IgnorePointer(
      ignoring: _presenting || !widget.interactive,
      child: SizedBox.square(
        dimension: boardSize,
        child: Stack(
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: AnimatedBoardWidget(
                  key: ValueKey(widget.presentationId),
                  boardState: frame.boardState,
                  selectedPiece: frame.selectedPiece,
                  validMoves: frame.validMoves,
                  lastMoveFrom: frame.lastMoveFrom,
                  lastMoveTo: frame.lastMoveTo,
                  capturedPiecePositions: frame.capturedPiecePositions,
                  feedbackEnabled: _feedbackEnabled,
                  onMoveCompleted: () => _onMoveCompleted(frame),
                  onPositionTapped: widget.onPositionTapped,
                  size: boardSize,
                  vibrationEnabled: _vibrationEnabled,
                  animationEnabled:
                      effectiveMotion.moveDuration != Duration.zero,
                  moveDuration: effectiveMotion.moveDuration,
                  captureDuration: effectiveMotion.captureDuration,
                  moveCurve: effectiveMotion.moveCurve,
                  captureCurve: effectiveMotion.captureCurve,
                  particleEnabled:
                      _particleEnabled && effectiveMotion.particlesEnabled,
                  flipBoard: frame.flipBoard,
                  theme: ThemePackBoardThemeAdapter(_themePack),
                ),
              ),
            ),
            Positioned.fill(
              child: BoardSemanticsOverlay(
                boardState: frame.boardState,
                selectedPiece: frame.selectedPiece,
                validMoves: frame.validMoves,
                lastMoveFrom: frame.lastMoveFrom,
                lastMoveTo: frame.lastMoveTo,
                flipBoard: frame.flipBoard,
                onPositionTapped: widget.onPositionTapped,
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _calculateBoardSize(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final shortestSide = screenSize.shortestSide;
    return (shortestSide * UIConstants.boardScreenRatio).clamp(
      UIConstants.boardMinSize,
      UIConstants.boardMaxSize,
    );
  }
}

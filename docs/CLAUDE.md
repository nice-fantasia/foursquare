# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Four Square Chess** (四子游戏) - A cross-platform strategy board game built with Flutter. Players compete on a 4×4 grid, moving pieces to form three-in-a-row patterns that capture opponent pieces. The game features AI opponents with multiple difficulty levels, local and online multiplayer, game replay, statistics tracking, and customizable themes.

**Tech Stack**: Flutter 3.35+, Dart 3.9+, BLoC pattern, Hive database, audioplayers, WebSocket

## Development Commands

### Setup & Installation
```bash
# Install dependencies
flutter pub get

# Check Flutter environment
flutter doctor

# List connected devices
flutter devices
```

### Running the Application
```bash
# Run on connected device
flutter run

# Run on Chrome (web)
flutter run -d chrome

# Run on specific device
flutter run -d [device_id]

# Run with hot reload enabled (default)
# Press 'r' for hot reload, 'R' for hot restart
```

### Testing
```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/bloc/game_bloc_test.dart

# Run tests with coverage report
flutter test --coverage

# Generate HTML coverage report (after running with --coverage)
genhtml coverage/lcov.info -o coverage/html
```

### Code Quality
```bash
# Analyze code for issues
flutter analyze

# Format code
dart format .

# Apply automated fixes
dart fix --apply
```

### Building
```bash
# Android APK (release)
flutter build apk --release

# Android App Bundle (for Play Store)
flutter build appbundle --release

# iOS (release)
flutter build ios --release

# Web (release)
flutter build web --release
```

## Architecture

The project uses **BLoC (Business Logic Component) architecture** with clear layer separation:

```
┌─────────────────────────────────────┐
│  UI Layer (lib/ui/)                 │
│  - Screens: HomePage, GamePage, etc │
│  - Widgets: BoardWidget, etc        │
└─────────────────┬───────────────────┘
                  │ Events
┌─────────────────▼───────────────────┐
│  BLoC Layer (lib/bloc/)             │
│  - GameBloc: State management       │
│  - Events & States                  │
└─────────────────┬───────────────────┘
                  │ Business Logic
┌─────────────────▼───────────────────┐
│  Engine Layer (lib/engine/)         │
│  - GameEngine: Core logic           │
│  - MoveValidator: Move validation   │
│  - CaptureDetector: Capture logic   │
└─────────────────┬───────────────────┘
                  │ Data Operations
┌─────────────────▼───────────────────┐
│  Model Layer (lib/models/)          │
│  - BoardState, Move, Position, etc  │
└─────────────────────────────────────┘
```

### Core Components

**1. GameEngine** (`lib/engine/game_engine.dart`)
- Executes moves and validates game rules
- Detects captures and checks win conditions
- Provides `simulateMove()` for AI to evaluate positions
- Maintains move history and game duration
- Key methods: `executeMove()`, `checkGameOver()`, `getPossibleMoves()`

**2. GameBloc** (`lib/bloc/game_bloc.dart`)
- Central state management hub for the game
- Handles events: `NewGameEvent`, `MovePieceEvent`, `AIPlayEvent`, `UndoMoveEvent`, etc.
- Coordinates services: audio, music, storage
- Manages AI turn execution with progress callbacks
- Implements undo/redo with stack management (max 10 steps)

**3. AI System** (`lib/ai/`)
- **MinimaxAI**: Implements minimax algorithm with alpha-beta pruning, transposition table caching, move ordering, iterative deepening, and dynamic depth adjustment
- **BoardEvaluator**: Position evaluation considering piece count, mobility, center control, capture threats, and positional value
- **Difficulty levels**: Easy (base depth 2, 30% random), Medium (base depth 4), Hard (base depth 8)
- Dynamic depth: Increases depth in endgame for precise calculation

**4. Services Layer** (`lib/services/`)
- **StorageService**: Hive-based persistence for game saves, statistics, and settings
- **AudioService**: Sound effect management (move, capture, win, lose, click, select)
- **MusicService**: Background music system with 5 themes (menu, gameplay, classic, night, relaxed)
- **GameReplayService**: Complete game replay with step navigation
- **WebSocketService**: Online multiplayer communication

**5. Move Validation Flow**
```dart
1. User taps piece → SelectPieceEvent
2. GameBloc validates ownership and calculates valid moves
3. User taps destination → MovePieceEvent
4. MoveValidator checks if move is legal (adjacent, empty)
5. GameEngine executes move and updates BoardState
6. CaptureDetector checks for three-in-a-row patterns
7. If capture exists, remove opponent piece
8. Check game over conditions
9. Switch player turn if game continues
```

### Game Rules Implementation

**Movement**: Only orthogonal (horizontal/vertical) moves to adjacent empty cells
- See: `lib/engine/move_validator.dart:isValidMove()`

**Capture Logic**: Forms "own-own-enemy" pattern horizontally or vertically
- The moved piece must participate in the line
- Only the farthest enemy piece is captured
- See: `lib/engine/capture_detector.dart:detectCapture()`

**Win Conditions**:
- Opponent has ≤ 1 piece remaining
- Opponent has no legal moves
- See: `lib/engine/game_engine.dart:checkGameOver()`

## Key Development Patterns

### State Management with BLoC
```dart
// Events trigger state changes
bloc.add(MovePieceEvent(from: Position(0,0), to: Position(0,1)));

// State updates trigger UI rebuilds
BlocBuilder<GameBloc, GameState>(
  builder: (context, state) {
    if (state is GamePlaying) {
      // Render game board
    }
  }
)
```

### Service Integration
All services are injected into GameBloc and accessed through events:
- Audio feedback: Automatic on move/capture events
- Music themes: Change based on game state (menu/gameplay/victory)
- Storage: Save game on `SaveGameEvent`, load on `LoadGameEvent`

### AI Integration
AI thinking is asynchronous to avoid blocking UI:
```dart
// AI reports progress during computation
ai.setProgressCallback((progress, status) {
  emit(state.copyWith(aiThinkingProgress: progress));
});

// GameBloc triggers AI move
add(AIPlayEvent()); // When white's turn in PvE mode
```

### Undo/Redo System
- Undo rebuilds board from initial state + move history
- PvE mode: Undo removes 2 moves (player + AI)
- PvP mode: Undo removes configurable steps
- Max 10 steps in undo stack to limit memory

## Important Notes for Development

### Adding New Features
1. Define models in `lib/models/` if new data structures needed
2. Add game logic to `lib/engine/` if core rules change
3. Create new events/states in `lib/bloc/` for state changes
4. Update UI in `lib/ui/screens/` or `lib/ui/widgets/`
5. Write tests in corresponding `test/` directory

### Testing Strategy
- **Unit tests**: Models, Engine, AI evaluation (target >80% coverage)
- **BLoC tests**: Use `bloc_test` package for event-state verification
- **Widget tests**: UI components with `flutter_test`
- Use `mocktail` for mocking services in tests

### Performance Considerations
- Board rendering uses `CustomPainter` for efficiency (`board_painter.dart`)
- AI computation runs asynchronously to prevent UI blocking
- Transposition table in AI limited to 10,000 entries to control memory
- Move history limited to prevent unbounded growth

### Internationalization
- All user-facing text uses `AppLocalizations`
- Supported: Chinese (zh), English (en), Japanese (ja)
- Files: `lib/l10n/app_localizations_*.dart`
- Auto-generated from ARB files via `flutter gen-l10n`

### Storage Architecture
- **Hive**: Complex objects (GameSave, GameStatistics)
- **SharedPreferences**: Simple settings (sound enabled, theme name)
- All operations abstracted through `StorageService`
- Initialize storage before runApp: `await storageService.initialize()`

## Common Issues & Solutions

### AI Too Slow
- Reduce depth in `MinimaxAI._getDepthForDifficulty()`
- Check transposition table size (may need clearing)
- Profile with `--profile` flag to identify bottlenecks

### Game Logic Bugs
- Add unit tests to `test/engine/` to verify rules
- Use `GameEngine.simulateMove()` to test without side effects
- Check `CaptureDetector` logic for edge cases

### State Not Updating
- Verify event is added to bloc: `bloc.add(YourEvent())`
- Ensure state classes implement `Equatable` correctly
- Use BLoC observer for debugging state transitions

### Build Failures
- Run `flutter clean && flutter pub get`
- Check `pubspec.yaml` for dependency conflicts
- Verify Flutter/Dart SDK versions match `pubspec.yaml`

## Project-Specific Conventions

- **Code attribution**: Files generated by AI include header comments with model and task info
- **Trailing commas**: Required by linter for better formatting
- **Constants**: Centralized in `lib/constants/` (game, UI, network, storage)
- **Error handling**: Use `LoggerService` for structured logging
- **Async operations**: Prefer `async/await` over `.then()` chains

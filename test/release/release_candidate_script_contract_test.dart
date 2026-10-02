import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory projectRoot;
  late File verificationScript;
  late File scriptsReadme;
  late File testStrategy;

  setUpAll(() {
    projectRoot = _findProjectRoot();
    verificationScript = File(
      _projectPath(
        projectRoot,
        const ['scripts', 'verify_release_candidate.ps1'],
      ),
    );
    scriptsReadme = File(
      _projectPath(projectRoot, const ['scripts', 'README.md']),
    );
    testStrategy = File(
      _projectPath(projectRoot, const ['docs', 'TEST_STRATEGY.md']),
    );
  });

  group('release-candidate verification script contract', () {
    test('provides the repository verification entry point', () {
      expect(
        verificationScript.existsSync(),
        isTrue,
        reason: 'scripts/verify_release_candidate.ps1 must exist',
      );
    });

    test('runs only cached checks and keeps destructive smoke opt-in', () {
      final source = _readRequired(verificationScript);

      expect(source, contains("\$ErrorActionPreference = 'Stop'"));
      expect(source, contains(r'[switch]$IncludeAndroidSmoke'));
      expect(source, contains('run_android_phase1_smoke.ps1'));
      expect(source, contains('--no-pub'));
      expect(source, contains('dart'));
      expect(source, contains('format'));
      expect(source, contains('flutter'));
      expect(source, contains('analyze'));
      expect(source, contains('test'));
      expect(source, contains('npm'));
      expect(source, contains('build'));
      expect(source, contains('apk'));
      expect(source, contains('--debug'));

      for (final forbidden in <RegExp>[
        RegExp(r'flutter\s+pub\s+get', caseSensitive: false),
        RegExp(r'npm\s+(ci|install)\b', caseSensitive: false),
        RegExp(r'sdkmanager[^\r\n]*--install', caseSensitive: false),
        RegExp(r'\bwinget\b', caseSensitive: false),
        RegExp(r'\bchoco\b', caseSensitive: false),
        RegExp(
          r'flutter\s+test\s+integration_test(?:\s|$)',
          caseSensitive: false,
        ),
      ]) {
        expect(source, isNot(matches(forbidden)));
      }
    });

    test('records reproducible evidence without changing global settings', () {
      final source = _readRequired(verificationScript);

      expect(source, contains(r'build\verification'));
      expect(source, contains('Get-FileHash'));
      expect(source, contains('SHA256'));
      expect(source, contains('git'));
      expect(source, contains('rev-parse'));
      expect(source, contains('status'));
      expect(source, contains('durationMilliseconds'));
      expect(source, contains('testCounts'));
      expect(source, contains('summary.json'));
      expect(source, contains('summary.md'));
      expect(source, contains(r'$originalNoProxy'));
      expect(source, contains(r'$env:NO_PROXY = $originalNoProxy'));
      expect(source, contains('loopbackNoProxyApplied'));
      expect(source, isNot(contains('noProxyOriginal =')));
      expect(source, isNot(contains('noProxyEffective =')));
      expect(source, contains(r'if ($null -eq $event)'));
      expect(source, contains(r'$summaryWritten'));
      expect(source, contains('failureType'));
      expect(source, contains(r'[switch]$Strict'));
    });

    test('machine-result parsing ignores JSON events without a type field', () {
      final source = _readRequired(verificationScript);

      expect(source, contains(r"$event.PSObject.Properties['type']"));
      expect(source, contains(r"$event.PSObject.Properties['hidden']"));
      expect(source, contains(r"$event.PSObject.Properties['skipped']"));
    });

    test('documents the safe primary and optional Android commands', () {
      final readme = scriptsReadme.readAsStringSync();
      final strategy = testStrategy.readAsStringSync();

      expect(readme, contains('verify_release_candidate.ps1'));
      expect(readme, contains('-IncludeAndroidSmoke'));
      expect(strategy, contains('verify_release_candidate.ps1'));
      expect(strategy, contains('-IncludeAndroidSmoke'));
      expect(
        strategy,
        isNot(
          matches(
            RegExp(
              r'^flutter\s+test\s+integration_test\s*$',
              caseSensitive: false,
              multiLine: true,
            ),
          ),
        ),
      );
    });
  });
}

Directory _findProjectRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File(_projectPath(directory, const ['pubspec.yaml'])).existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not locate project root');
    }
    directory = parent;
  }
}

String _projectPath(Directory root, List<String> segments) =>
    <String>[root.path, ...segments].join(Platform.pathSeparator);

String _readRequired(File file) {
  expect(file.existsSync(), isTrue, reason: '${file.path} must exist');
  return file.readAsStringSync();
}

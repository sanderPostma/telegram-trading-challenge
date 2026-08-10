import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/patterns/default_patterns.dart';

/// The pattern rules exist in two places: `config/telegram_patterns.yaml` (the
/// single source, embedded into Rust with `include_str!` and served from the
/// remote host) and [embeddedTelegramPatternsYaml] (the Dart fallback used when
/// the remote host is unreachable at first launch). Only the prose headers
/// differ; the rules themselves must not. Drift here is silent — the app keeps
/// working and simply misreads a signal shape whenever it falls back.
void main() {
  /// The `patterns:` block with comments and blank lines removed.
  ///
  /// Line endings are normalized first: a Windows checkout rewrites the YAML
  /// on disk to CRLF while the Dart string literal keeps LF, so comparing raw
  /// lines fails there and nowhere else.
  List<String> ruleLines(String yaml) => yaml
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.isNotEmpty && !line.trimLeft().startsWith('#'))
      .toList();

  test('the Dart fallback carries the same rules as the source YAML', () {
    final source = File('config/telegram_patterns.yaml').readAsStringSync();
    expect(
      ruleLines(embeddedTelegramPatternsYaml),
      ruleLines(source),
      reason: 'lib/src/patterns/default_patterns.dart has drifted from '
          'config/telegram_patterns.yaml — copy the rules across',
    );
  });

  test('the comparison does not depend on the checkout line endings', () {
    // Guards the check itself: on a Windows runner the YAML arrives as CRLF
    // and the Dart literal as LF, which failed the comparison above for a
    // reason that had nothing to do with drift.
    final source = File('config/telegram_patterns.yaml').readAsStringSync();
    final asCrlf = source.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
    expect(ruleLines(asCrlf), ruleLines(source));
  });
}

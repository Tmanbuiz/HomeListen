import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_listen/core/smart_home_settings.dart';

void main() {
  test('displayed app version matches the release version', () {
    final manifest = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version: ([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+$',
      multiLine: true,
    ).firstMatch(manifest);
    expect(version, isNotNull);
    expect(homeListenVersion, version!.group(1));
  });
}

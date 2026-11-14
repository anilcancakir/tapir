import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// Guards the claims in the `post_install` message of `install.yaml`.
///
/// The message is the first thing a consumer reads after `plugin:install`, and
/// nothing compiles it: a stale field count or startup figure stays in place
/// until someone reads it against the code. The Wind contract has seven keys
/// (`className`, `breakpoint`, `brightness`, `platform`, `states`, `bgColor`,
/// `textColor`), and one startup figure is quoted for the fast wrapper.
void main() {
  group('install.yaml post_install message', () {
    late String message;

    setUp(() {
      final YamlMap manifest =
          loadYaml(File('install.yaml').readAsStringSync()) as YamlMap;
      message = (manifest['post_install'] as YamlMap)['message'] as String;
    });

    test('counts the seven keys of the Wind contract', () {
      expect(message, contains('7 contract fields'));
      expect(message, contains('className'));
      expect(message, isNot(contains('6 core fields')));
    });

    test('lists the Magic enrichers as examples, not as a closed list', () {
      expect(message, contains('for example'));
    });

    test('quotes the one measured startup figure of the fast wrapper', () {
      expect(message, contains('about 0.2 s'));
      expect(message, isNot(contains('110ms')));
    });
  });
}

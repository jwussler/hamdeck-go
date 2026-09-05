import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamdeck_panel/ptt.dart';
// ⚠️ The same conversions HotKey itself uses - and the same ones it null-asserts.
import 'package:uni_platform/uni_platform.dart';

/// Every key the PTT chooser offers must survive being turned into a hotkey.
///
/// ⚠️ THIS IS THE CRASH JOE HIT. Choosing F13 killed the app. `HotKey` converts
/// between physical and logical keys with a NULL ASSERT - `physicalKey.logicalKey!`
/// - and Flutter's tables do not map every key both ways. A key with no
/// counterpart therefore does not fail to register, it throws where nothing is
/// catching, and the window goes away.
///
/// A chooser must never offer a key that cannot be used. This runs on any
/// machine, needs no Windows, and would have caught it before it shipped.
void main() {
  test('every offered key maps both ways, so none of them can crash', () {
    final broken = <String>[];
    for (final (name, _) in GlobalPtt.choices) {
      if (name == 'Off') continue;
      final key = GlobalPtt.keyFor(name);
      expect(key, isNotNull, reason: '$name is offered but has no key behind it');
      // Both directions, because HotKey uses whichever one the platform wants
      // and asserts non-null on the conversion.
      final physical = key is PhysicalKeyboardKey
          ? key
          : (key as LogicalKeyboardKey).physicalKey;
      final logical =
          key is LogicalKeyboardKey ? key : (key as PhysicalKeyboardKey).logicalKey;
      // ignore: avoid_print
      print('$name  physical=$physical  logical=$logical');
      if (physical == null || logical == null) {
        broken.add('$name (physical=$physical logical=$logical)');
      }
    }
    expect(broken, isEmpty,
        reason: 'these keys would throw inside HotKey rather than fail to '
            'register, and take the app down with them: ${broken.join(", ")}');
  });

  test('the chooser explains what each key costs', () {
    for (final (name, why) in GlobalPtt.choices) {
      expect(why.trim(), isNotEmpty,
          reason: '$name is offered with no note about what taking it costs');
    }
  });
}

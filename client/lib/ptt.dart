import 'dart:async';


import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// The system-wide push-to-talk key.
///
/// ⚠️ THIS IS THE FEATURE THE PANEL WAS MISSING, and it is not a convenience.
/// Key down keys the transmitter, key up unkeys it, WHETHER OR NOT the panel has
/// focus — because the operator is looking at a logger, a cluster, or nothing at
/// all. A remote panel you have to click into before you can talk is a panel you
/// stop using.
///
/// ⚠️ AND IT MUST NEVER LEAVE A CARRIER UP. That is the one failure that
/// matters, and every rule below exists for it:
///
///  - **The panel names the mode that is actually armed.** Hold and toggle are
///    different contracts and a PTT that silently becomes a latch is a stuck
///    transmitter waiting to happen. It is never inferred by the operator.
///  - **A hold limit, deliberately longer than any real over and shorter than
///    the host's watchdog** — 150 s against 180 s. A lost key-up and a long
///    transmission look identical from here: audio still flows, the link is
///    fine, the operator is simply talking. Anything cleverer eventually cuts
///    somebody off mid-sentence, which is worse than the bug. This exists only
///    so the operator is told which safeguard fired; the host's watchdog is what
///    actually protects the transmitter.
///  - **The press count is shown.** A key another application swallowed reads as
///    zero presses, which is the difference between "my PTT is broken" and "my
///    PTT is bound to something else".
///
/// ⚠️ A KEY REGISTERED SYSTEM-WIDE IS TAKEN FROM EVERY OTHER APPLICATION on the
/// machine, for as long as this runs. F13/F14/F15 collide with nothing because
/// no physical keyboard sends them — they are what a footswitch or a programmable
/// key should be mapped to. Pause and Scroll Lock are pressable and nearly
/// unused. F9 and F12 are pressable and commonly bound: taking those WILL break
/// them elsewhere, so the chooser says so rather than letting it be discovered.
class GlobalPtt {
  GlobalPtt({required this.onDown, required this.onUp, required this.onChanged});

  /// Called on the down edge, and on a toggle-on.
  final Future<void> Function() onDown;

  /// Called on the up edge, on a toggle-off, and when the hold limit fires.
  final Future<void> Function(String why) onUp;

  /// Something the panel should redraw: the armed mode, the count, the state.
  final VoidCallback onChanged;

  static const holdLimit = Duration(seconds: 150);

  /// The keys offered, and what each one costs.
  ///
  /// ⚠️ The cost is IN THE LIST. A chooser that offers F9 beside F13 with no
  /// warning is a chooser that will break somebody's logger.
  static const choices = <(String, String)>[
    ('Off', 'no system-wide key'),
    ('F13', 'nothing else uses it — needs a footswitch or a programmable key'),
    ('F14', 'nothing else uses it'),
    ('F15', 'nothing else uses it'),
    ('Pause', 'pressable, and almost nothing else wants it'),
    ('ScrollLock', 'pressable, and almost nothing else wants it'),
    ('F9', '⚠ commonly bound — this WILL stop F9 working in other apps'),
    ('F12', '⚠ commonly bound — this WILL stop F12 working in other apps'),
  ];

  static final _keys = <String, PhysicalKeyboardKey>{
    'F13': PhysicalKeyboardKey.f13,
    'F14': PhysicalKeyboardKey.f14,
    'F15': PhysicalKeyboardKey.f15,
    'Pause': PhysicalKeyboardKey.pause,
    'ScrollLock': PhysicalKeyboardKey.scrollLock,
    'F9': PhysicalKeyboardKey.f9,
    'F12': PhysicalKeyboardKey.f12,
  };

  HotKey? _registered;
  String _keyName = 'Off';
  bool _hold = true;
  bool _down = false;
  int _presses = 0;
  String _status = 'no system-wide key';
  Timer? _limit;

  String get keyName => _keyName;
  bool get down => _down;
  int get presses => _presses;

  /// What is ARMED, in words, never inferred. Drawn in the panel as-is.
  String get status => _status;

  bool get active => _registered != null;

  /// Register, or move to, a key. "Off" unregisters.
  Future<void> use(String name, {required bool hold}) async {
    _hold = hold;
    await unregister();
    _keyName = name;
    if (name == 'Off' || !_keys.containsKey(name)) {
      _status = 'no system-wide key — the panel must have focus';
      onChanged();
      return;
    }
    final hk = HotKey(
      key: _keys[name]!,
      scope: HotKeyScope.system,
      // ⚠️ No auto-repeat. A key held down repeats at the OS rate, and a repeat
      // that reaches the rig flaps the transmitter.
      identifier: 'hamdeck-ptt',
    );
    try {
      await hotKeyManager.register(
        hk,
        keyDownHandler: (_) => _pressed(),
        keyUpHandler: _hold ? (_) => _released('key released') : null,
      );
      _registered = hk;
      _status = _hold
          ? 'system-wide, hold — $name works with any window focused'
          : 'system-wide, toggle — press $name to key, press again to unkey';
    } catch (e) {
      // ⚠️ Registration is REFUSED when another application already owns the
      // key. Say which, and say what the panel can still do - a status line that
      // claims a key it does not have is how an operator finds out mid-net.
      _registered = null;
      _status = '$name is already taken by another application — '
          'the panel must have focus, or choose another key';
    }
    onChanged();
  }

  Future<void> unregister() async {
    _limit?.cancel();
    _limit = null;
    if (_registered != null) {
      await hotKeyManager.unregister(_registered!);
      _registered = null;
    }
    if (_down) {
      _down = false;
      await onUp('the key was released');
    }
  }

  Future<void> _pressed() async {
    _presses++;
    if (!_hold) {
      // Toggle: this press is whichever edge the last one was not.
      if (_down) {
        await _released('pressed again');
      } else {
        _down = true;
        _arm();
        onChanged();
        await onDown();
      }
      return;
    }
    if (_down) return; // repeat suppression, belt and braces
    _down = true;
    _arm();
    onChanged();
    await onDown();
  }

  void _arm() {
    _limit?.cancel();
    _limit = Timer(holdLimit, () {
      // ⚠️ The panel says it was THIS limit, not the host's. Two safeguards that
      // both say "unkeyed" leave the operator unable to tell which fired, and
      // therefore unable to tell a lost key-up from a long over.
      _released('the panel\'s 150 s hold limit fired — '
          'a key release may have been lost');
    });
  }

  Future<void> _released(String why) async {
    _limit?.cancel();
    _limit = null;
    if (!_down) return;
    _down = false;
    onChanged();
    await onUp(why);
  }

  /// Only state 3 - focused-only - unkeys when the window loses focus.
  ///
  /// ⚠️ UNDER A SYSTEM-WIDE KEY THAT BEHAVIOUR IS EXACTLY WRONG: looking at the
  /// logger while transmitting is the entire point of the feature.
  bool get unkeyOnFocusLoss => !active;
}

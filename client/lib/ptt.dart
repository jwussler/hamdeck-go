import 'dart:async';


import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'keystate/keystate.dart';

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

  /// The key behind a name, for the chooser and for the test that proves none
  /// of them can crash.
  static KeyboardKey? keyFor(String name) => _keys[name];

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
  // ⚠️ WHAT THE PLATFORM HAS ACTUALLY BEEN TOLD, tracked here rather than
  // inferred. The Windows plugin unregisters with `hotkey_id_map_.at(id)` -
  // std::map::at THROWS when the id is absent, and an uncaught C++ exception in
  // a Flutter plugin takes the whole app down. Unregistering twice, or
  // unregistering something that never registered, is therefore a crash, and
  // this app could do both: startup restore racing the chooser, and dispose
  // racing quit-from-tray.
  bool _platformHolds = false;
  // Serialises use()/unregister(), because the same race is what produced the
  // double unregister in the first place.
  Future<void> _work = Future<void>.value();
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

  /// Has a press actually arrived? See use(): registration can fail silently on
  /// both desktop platforms, so this is the only proof the key is really ours.
  bool _confirmed = false;
  bool get confirmed => _confirmed;

  String get _mode {
    if (_hold) {
      return (defaultTargetPlatform == TargetPlatform.macOS)
          ? 'hold — works with any window focused'
          : 'hold — release detected by key-state polling';
    }
    return canHold
        ? 'toggle — press to key, press again to unkey'
        : 'toggle — this platform sends no key release, so hold is not offered';
  }

  void _restate() {
    if (_registered == null) return;
    _status = _confirmed
        ? 'system-wide, $_mode'
        : '$_keyName claimed, $_mode  ·  PRESS IT ONCE TO CONFIRM — '
            'registration can fail silently and this panel will not claim it works';
  }

  /// Can this platform tell us when the key is RELEASED?
  ///
  /// ⚠️ macOS delivers a real key-up event. Windows does not - its plugin emits
  /// only onKeyDown - so hold there is built on GetAsyncKeyState polling
  /// instead. Linux delivers neither, so it gets toggle and is told so. A panel
  /// that offers hold where no release can arrive is a stuck transmitter with a
  /// friendly label.
  bool get canHold => (defaultTargetPlatform == TargetPlatform.macOS) || KeyState.instance.available;

  /// Register, or move to, a key. "Off" unregisters.
  Future<void> use(String name, {required bool hold}) =>
      _work = _work.then((_) => _use(name, hold: hold));

  Future<void> _use(String name, {required bool hold}) async {
    // ⚠️ Hold is only ever armed where a release can actually reach us.
    _hold = hold && canHold;
    await _unregister();
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
        // ⚠️ Only where the platform sends one. Windows never does.
        keyUpHandler:
            (_hold && (defaultTargetPlatform == TargetPlatform.macOS)) ? (_) => _released('key released') : null,
      );
      _registered = hk;
      _platformHolds = true;
      // ⚠️ CLAIMED, NOT CONFIRMED - AND THE PANEL SAYS WHICH.
      //
      // Registration failing does not always throw. On Linux the plugin logs
      // "Binding 'F13' failed!" and returns normally; on Windows the native
      // code calls RegisterHotKey and NEVER CHECKS ITS RETURN VALUE, so a key
      // another application already owns is recorded as registered and then
      // never fires. Either way this side is told nothing.
      //
      // So the status stays "claimed" until a press actually arrives. The
      // difference matters at exactly the wrong moment: an operator who
      // believes their PTT is armed, and finds out mid-net that it is not.
      _confirmed = false;
      _restate();
    } catch (e) {
      // ⚠️ Registration is REFUSED when another application already owns the
      // key. Say which, and say what the panel can still do - a status line that
      // claims a key it does not have is how an operator finds out mid-net.
      _registered = null;
      _platformHolds = false;
      _status = '$name is already taken by another application — '
          'the panel must have focus, or choose another key';
    }
    onChanged();
  }

  Future<void> unregister() => _work = _work.then((_) => _unregister());

  Future<void> _unregister() async {
    _limit?.cancel();
    _limit = null;
    _poll?.cancel();
    _poll = null;
    final hk = _registered;
    // ⚠️ CLEARED BEFORE THE AWAIT, and only unregistered if the platform is
    // actually holding it. Two calls that both see a non-null field and both
    // reach the plugin is the std::out_of_range crash.
    _registered = null;
    if (hk != null && _platformHolds) {
      _platformHolds = false;
      try {
        await hotKeyManager.unregister(hk);
      } catch (_) {
        // Already gone. Not a fault, and never worth taking the app down for.
      }
    }
    if (_down) {
      _down = false;
      await onUp('the key was released');
    }
  }

  Future<void> _pressed() async {
    _presses++;
    if (!_confirmed) {
      // ⚠️ The first press is the proof, and it is the only one there is.
      _confirmed = true;
      _restate();
    }
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

  Timer? _poll;

  /// ⚠️ THE RELEASE, WHERE THE PLATFORM WILL NOT SEND ONE. 25 ms is fast enough
  /// that the tail of an over is not clipped and slow enough to cost nothing.
  /// It asks about ONE key - the one the operator nominated - and can learn
  /// nothing else about the keyboard.
  void _watchForRelease() {
    _poll?.cancel();
    if (!_hold || (defaultTargetPlatform == TargetPlatform.macOS) || !KeyState.instance.available) return;
    _poll = Timer.periodic(const Duration(milliseconds: 25), (t) {
      final down = KeyState.instance.isDown(_keyName);
      if (down == false) {
        t.cancel();
        _released('key released');
      }
    });
  }

  void _arm() {
    _watchForRelease();
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

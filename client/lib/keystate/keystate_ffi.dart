import 'dart:ffi';
import 'dart:io';


/// Is one nominated key still held down, right now?
///
/// ⚠️ THIS EXISTS BECAUSE THE WINDOWS HOTKEY PLUGIN HAS NO KEY-UP. Its native
/// code emits `onKeyDown` and nothing else, so hold-to-talk built on it would
/// key the transmitter and never release it — the carrier would stay up until
/// the panel's 150 s limit or the host's 180 s watchdog. That is not a
/// push-to-talk, it is a latch with extra steps.
///
/// ⚠️ AND THE FIX IS THE ONE THE DESIGN DOC ALREADY NAMED: `RegisterHotKey`
/// gives the down edge, and `GetAsyncKeyState` then answers "is that ONE key
/// still down?" on a short timer. Down edge plus a state poll is hold-to-talk,
/// system-wide, **with no keyboard hook and no keylogging surface** — this can
/// only ever learn about the single key the operator nominated, which is why it
/// is acceptable where a low-level hook is not.
///
/// Everywhere else this answers null, and the caller falls back to the mode the
/// platform can actually deliver rather than claiming one it cannot.
class KeyState {
  KeyState._();

  static final KeyState instance = KeyState._();

  /// Windows virtual-key codes for the keys the chooser offers.
  ///
  /// ⚠️ Transcribed, not derived. A VK code guessed from a neighbour polls a
  /// key the operator never pressed, which reads as "my PTT sticks".
  static const _vk = <String, int>{
    'F9': 0x78,
    'F12': 0x7B,
    'F13': 0x7C,
    'F14': 0x7D,
    'F15': 0x7E,
    'Pause': 0x13,
    'ScrollLock': 0x91,
  };

  int Function(int)? _getAsyncKeyState;
  bool _tried = false;

  /// Is this one of the keys this probe can actually poll?
  ///
  /// ⚠️ Asked BEFORE anything is armed. On Windows the whole PTT key is driven
  /// by polling now, so a key that is not in the table below has no mechanism at
  /// all - and silently arming nothing is the failure this app keeps having.
  bool knows(String keyName) => _vk.containsKey(keyName);

  bool get available {
    if (!Platform.isWindows) return false;
    _load();
    return _getAsyncKeyState != null;
  }

  void _load() {
    if (_tried) return;
    _tried = true;
    if (!Platform.isWindows) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      _getAsyncKeyState = user32
          .lookupFunction<Int16 Function(Int32), int Function(int)>(
              'GetAsyncKeyState');
    } catch (_) {
      // ⚠️ Left null on purpose: the caller then offers toggle and says so,
      // rather than offering a hold whose release will never arrive.
      _getAsyncKeyState = null;
    }
  }

  /// True while the named key is physically down. Null when this platform
  /// cannot answer, which is not the same as "the key is up".
  bool? isDown(String keyName) {
    if (!available) return null;
    final vk = _vk[keyName];
    if (vk == null) return null;
    // The high bit is "currently down"; the low bit is "pressed since last
    // call" and is deliberately ignored - it would report a key that has
    // already been released.
    return (_getAsyncKeyState!(vk) & 0x8000) != 0;
  }
}

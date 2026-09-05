import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// The tray icon, and the hazard it exists to answer.
///
/// ⚠️ A HIDDEN PANEL STILL HOLDS THE TRANSMITTER. Close the window and the
/// transmit socket, the routing (MOD SOURCE=REAR) and the claim on the radio all
/// persist — which is CORRECT, because keying from the logger is the whole point
/// of a system-wide PTT. But it means the operator can close the window
/// believing they have finished, walk to the radio, and find the hand mic dead
/// because the rig is still on REAR for a client they cannot see.
///
/// So, three rules, none optional:
///
///  1. **The icon carries the state, not just the app.** Idle, armed and ON AIR
///     are three different icons, and ON AIR is unmistakable at 16 px.
///  2. **The tooltip says it in words** — an icon alone is a colour somebody has
///     to remember the meaning of.
///  3. **Quit always releases**: disarm, unkey, close the socket. The host then
///     restores the power cap and puts MOD SOURCE back to MIC — and that
///     safeguard lives next to the radio precisely because this can be killed.
///
/// ⚠️ AND THE FIRST HIDE SAYS SO. An app that vanishes silently is one the
/// operator assumes has stopped.
class StationTray with TrayListener {
  StationTray({required this.onShow, required this.onQuit});

  final VoidCallback onShow;
  final Future<void> Function() onQuit;

  bool _started = false;
  bool _warned = false;

  /// Linux desktops without a tray must not silently swallow the window.
  bool get available => _started;

  Future<void> start() async {
    if (kIsWeb) return;
    try {
      await trayManager.setIcon(_iconFor(false, false));
      await trayManager.setToolTip('HamDeck — idle');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show HamDeck'),
        MenuItem.separator(),
        // ⚠️ Named for what it does to the radio, not just to the app.
        MenuItem(key: 'quit', label: 'Quit (releases the transmitter)'),
      ]));
      trayManager.addListener(this);
      _started = true;
    } catch (_) {
      // ⚠️ A bare GNOME has no tray. Say so by staying false: the window close
      // handler then QUITS rather than hiding the app into nothing.
      _started = false;
    }
  }

  /// Reflect what the station is doing. Called on every state change.
  Future<void> update({required bool armed, required bool onAir}) async {
    if (!_started) return;
    await trayManager.setIcon(_iconFor(armed, onAir));
    await trayManager.setToolTip(onAir
        ? 'HamDeck — ON AIR'
        : (armed
            ? 'HamDeck — ARMED, the radio is on REAR/USB'
            : 'HamDeck — idle'));
  }

  /// ⚠️ Once, and only on the first hide.
  bool takeFirstHideWarning() {
    if (_warned) return false;
    _warned = true;
    return true;
  }

  String _iconFor(bool armed, bool onAir) {
    final name = onAir ? 'tray_onair' : (armed ? 'tray_armed' : 'tray_idle');
    // Windows insists on .ico; the others take a png.
    return Platform.isWindows
        ? 'assets/tray/$name.ico'
        : 'assets/tray/$name.png';
  }

  @override
  void onTrayIconMouseDown() => onShow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      onShow();
      return;
    }
    if (menuItem.key == 'quit') {
      // ⚠️ Release FIRST, then leave. The order is the whole rule.
      onQuit().then((_) => windowManager.destroy());
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    trayManager.removeListener(this);
    await trayManager.destroy();
    _started = false;
  }
}

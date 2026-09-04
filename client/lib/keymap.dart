import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'theme.dart';

/// Every operating action, with the key that does it.
///
/// ⚠️ KEYBOARD-COMPLETE IS THE CLEAREST OPEN GOAL IN REMOTE RADIO SOFTWARE, and
/// it is an accessibility failure, not a convenience one. From the Handiham
/// manual written for blind operators about the leading remote package: "You
/// cannot adjust any of the slider controls or change the CW speed or adjust
/// many of the other knobs", and "there does not appear any way of actually
/// changing any of these settings with keyboard shortcuts."
///
/// So every action here is reachable without a mouse, every control carries a
/// label a screen reader can read, and the things that MATTER - transmitting,
/// and a microphone that is sending silence - are ANNOUNCED rather than shown.
/// An operator who cannot see the ON AIR bar has to be told they are on the air.
///
/// It also happens to make the panel faster for everyone else.
class Key {
  const Key(this.keys, this.what);
  final String keys;
  final String what;
}

const keyMap = <String, List<Key>>{
  'TUNING': [
    Key('↑  ↓', 'tune up / down by the current step'),
    Key('shift ↑  ↓', 'ten steps at once'),
    Key('←  →', 'make the step smaller / larger'),
    Key('F', 'type a frequency'),
  ],
  'BAND AND MODE': [
    Key('1 … 9, 0, -', '160 · 80 · 60 · 40 · 30 · 20 · 17 · 15 · 12 · 10 · 6'),
    Key('L  U  C  A  D', 'LSB · USB · CW · AM · DATA'),
  ],
  'VFO': [
    Key('V', 'swap A and B'),
    Key('S', 'split on / off'),
    Key('K', 'lock the VFO'),
  ],
  'RECEIVER': [
    Key('G', 'cycle AGC'),
    Key('P', 'cycle the preamp'),
    Key('N', 'notch on / off'),
    Key('[  ]', 'volume down / up'),
    Key('R  shift R', 'RIT down / up'),
    Key('0 (zero) twice', 'clear RIT'),
  ],
  'TRANSMIT': [
    // ⚠️ A TOGGLE, NOT HOLD-TO-TALK, AND THE TEXT SAYS SO. This line described a
    // key that does not exist: space flips PTT on each press. Worse, hold-to-talk
    // over a network is the wrong shape - a key-up lost to a dropped link, a
    // window losing focus mid-over or a browser tab going to the background all
    // leave the carrier UP, and the operator's release never arrives. Escape and
    // the host's watchdog are what stop a transmission here.
    Key('space', 'start / stop transmitting'),
    Key('escape', 'STOP TRANSMITTING — works from anywhere, always'),
    Key('E', 'arm / disarm the microphone'),
    Key('T', 'tune the antenna tuner'),
  ],
  'PANEL': [
    Key('tab', 'move between controls'),
    Key('?', 'show or hide this list'),
  ],
};

/// The help overlay. ⚠️ Not modal - it must not be able to cover or disable the
/// transmit controls, and escape must still stop a transmission while it is up.
class KeyMapSheet extends StatelessWidget {
  const KeyMapSheet({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Keyboard shortcuts',
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: T.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: T.cyan)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text('KEYBOARD', style: T.silk()),
              const Spacer(),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18, color: T.dim),
                tooltip: 'Close',
              ),
            ]),
            const SizedBox(height: 4),
            const Text(
                'Every operating action has a key. Escape always stops a transmission.',
                style: TextStyle(fontFamily: T.mono, fontSize: 10, color: T.dim)),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final group in keyMap.entries) ...[
                      Text(group.key, style: T.silk()),
                      const SizedBox(height: 5),
                      for (final k in group.value)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(children: [
                            SizedBox(
                              width: 118,
                              child: Text(k.keys,
                                  style: const TextStyle(
                                      fontFamily: T.mono,
                                      fontSize: 11,
                                      color: T.cyan)),
                            ),
                            Expanded(
                              child: Text(k.what,
                                  style: const TextStyle(
                                      fontFamily: T.mono,
                                      fontSize: 11,
                                      color: T.text)),
                            ),
                          ]),
                        ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ),
          ]),
        ),
      );
}

/// announce says something out loud to a screen reader.
///
/// ⚠️ USED ONLY FOR THINGS THAT CHANGE WHETHER YOU ARE ON THE AIR, or that mean
/// the transmission is going nowhere. Announcing every frequency nudge would
/// bury the one message that matters under a hundred that do not.
void announce(BuildContext context, String message, {bool urgent = false}) {
  // ⚠️ sendAnnouncement, not the deprecated announce(): the old one cannot cope
  // with multiple windows, and this is the one call in the panel a blind
  // operator depends on to know they are transmitting.
  //
  // ⚠️ ASSERTIVE for anything about being on the air. A polite announcement
  // waits its turn behind whatever the screen reader is already saying, and
  // "you are transmitting" is not a message that can queue.
  SemanticsService.sendAnnouncement(
    View.of(context),
    message,
    TextDirection.ltr,
    assertiveness: urgent ? Assertiveness.assertive : Assertiveness.polite,
  );
}

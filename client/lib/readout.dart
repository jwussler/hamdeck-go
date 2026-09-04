import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// The frequency readout, which is also the tuning control.
///
/// ⚠️ THE READOUT IS HOW YOU TUNE. This is the single biggest thing the first
/// version of this panel got wrong: it could change band and step in fixed
/// jumps, and there was no way to actually tune the radio - the one thing an
/// operator does more than anything else. Every real product in this space makes
/// the readout itself the control, and they all landed on the same gestures:
///
///   wheel over a digit   move by that digit's weight
///   click upper half     up one step of that digit
///   click lower half     down one step
///   shift-click a digit  zero everything below it
///   right-click          the keypad, to type a frequency
///
/// (Yaesu's SCU-LAN10 manual, "Frequency change operation" - the same scheme on
/// the MHz, kHz and Hz digits.) An operator who has used any of them already
/// knows how this works, which is worth more than anything novel.
class Readout extends StatefulWidget {
  const Readout({
    super.key,
    required this.hz,
    required this.stale,
    required this.tx,
    required this.onSet,
    required this.onKeypad,
  });

  final int hz;
  final bool stale;
  final bool tx;

  /// Absolute, in Hz. ⚠️ Absolute rather than a delta: the radio is the truth
  /// and two clicks arriving out of order must not compound.
  final void Function(int hz) onSet;
  final VoidCallback onKeypad;

  @override
  State<Readout> createState() => _ReadoutState();
}

class _ReadoutState extends State<Readout> {
  int? _hover;

  // Digit weights for a 9-digit readout: 100 MHz down to 1 Hz.
  static const _weights = [
    100000000, 10000000, 1000000, 100000, 10000, 1000, 100, 10, 1
  ];

  void _nudge(int index, int dir) {
    final w = _weights[index];
    // ⚠️ CLAMPED TO THE BANDS THE HOST WILL ACCEPT, so a wheel spin at the top
    // of the readout cannot walk the radio somewhere it refuses to go and leave
    // the panel showing a frequency the rig never took.
    var next = widget.hz + dir * w;
    if (next < 1800000) next = 1800000;
    if (next > 54000000) next = 54000000;
    widget.onSet(next);
  }

  void _zeroBelow(int index) {
    final w = _weights[index];
    widget.onSet((widget.hz ~/ w) * w);
  }

  @override
  Widget build(BuildContext context) {
    final digits = widget.hz.toString().padLeft(9, '0');
    // ⚠️ LEADING ZEROS ARE INVISIBLE BUT STILL THERE. No radio displays
    // "007.188.600" - it reads as a fault before it reads as a frequency. They
    // cannot simply be dropped either: the digit positions must not move as the
    // frequency changes, or the digit you are pointing at slides out from under
    // the cursor mid-tune. So they keep their space and are drawn transparent,
    // and they still tune - putting the cursor left of the leading digit and
    // spinning is how you get from 7 MHz to 14.
    var leading = true;
    final children = <Widget>[];
    for (var i = 0; i < 9; i++) {
      if (digits[i] != '0') leading = false;
      final isLeading = leading && i < 6;
      children.add(_digit(i, digits[i], isLeading));
      if (i == 2 || i == 5) {
        // The separator before a run of blank leading digits is blank too.
        final blank = leading && i < 5;
        children.add(Text('.',
            style: TextStyle(
                fontSize: 44,
                fontFamily: T.mono,
                color: blank
                    ? Colors.transparent
                    : (widget.stale ? T.amberDim : T.amber))));
      }
    }
    return GestureDetector(
      onSecondaryTap: widget.onKeypad,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _digit(int i, String ch, bool dim) {
    final active = _hover == i;
    final Color colour;
    if (dim) {
      // Visible only while the cursor is on it, so the operator can see there
      // is something there to spin.
      colour = active ? T.amberDim : Colors.transparent;
    } else {
      colour = widget.stale ? T.amberDim : (widget.tx ? T.txRed : T.amber);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hover = i),
      onExit: (_) => setState(() => _hover = null),
      child: Listener(
        onPointerSignal: (s) {
          if (s is PointerScrollEvent) {
            _nudge(i, s.scrollDelta.dy < 0 ? 1 : -1);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (HardwareKeyboard.instance.isShiftPressed) {
              _zeroBelow(i);
              return;
            }
            // Upper half up, lower half down - the same halves every product in
            // this space uses, so the gesture transfers.
            final h = context.size?.height ?? 60;
            _nudge(i, d.localPosition.dy < h / 2 ? 1 : -1);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              // ⚠️ The digit under the cursor is marked, because "which digit
              // am I about to move" is the whole question this control asks.
              border: Border(
                  bottom: BorderSide(
                      color: active ? T.cyan : Colors.transparent, width: 2)),
              color: active ? T.cyanFill.withValues(alpha: 0.35) : null,
            ),
            child: Text(ch,
                style: TextStyle(
                    fontSize: 44,
                    height: 1.1,
                    fontFamily: T.mono,
                    fontWeight: FontWeight.w500,
                    color: colour)),
          ),
        ),
      ),
    );
  }
}

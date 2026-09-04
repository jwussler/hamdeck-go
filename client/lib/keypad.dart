import 'package:flutter/material.dart';

import 'theme.dart';

/// The frequency keypad, as a popover on the readout.
///
/// ⚠️ IT IS NOT MODAL, AND THAT IS A SAFETY RULE, NOT A PREFERENCE. A modal
/// popup greys out everything behind it, which would include the transmit bar -
/// so with the keypad open the operator could not stop transmitting. Stopping is
/// always one action away, from every screen and every state.
class Keypad extends StatefulWidget {
  const Keypad({super.key, required this.onEnter});
  final void Function(int hz) onEnter;

  @override
  State<Keypad> createState() => _KeypadState();
}

class _KeypadState extends State<Keypad> {
  String _buf = '';

  // ⚠️ Typed in MHz, the way an operator says a frequency out loud: "seven one
  // nine five" is 7.195 MHz. Asking for 7195000 is asking them to translate.
  String get _pretty => _buf.isEmpty ? '—' : '$_buf MHz';

  int? get _hz {
    if (_buf.isEmpty) return null;
    final mhz = double.tryParse(_buf);
    if (mhz == null) return null;
    final hz = (mhz * 1000000).round();
    if (hz < 1800000 || hz > 54000000) return null;
    return hz;
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: T.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: T.cyan)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 220,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(
                color: T.ground, borderRadius: BorderRadius.circular(5)),
            child: Text(_pretty,
                style: TextStyle(
                    fontFamily: T.mono,
                    fontSize: 20,
                    // ⚠️ Out-of-band shows RED WHILE TYPING rather than being
                    // rejected at the end. Finding out after you press enter
                    // that 71.95 was never going to work wastes the whole entry.
                    color: _buf.isEmpty
                        ? T.dim
                        : (_hz == null ? T.txRed : T.amber))),
          ),
          const SizedBox(height: 10),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['.', '0', '⌫'],
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final k in row) _key(k),
              ]),
            ),
          const SizedBox(height: 4),
          SizedBox(
            width: 220,
            height: 40,
            child: FilledButton(
              // ⚠️ A DISABLED BUTTON STILL HAS TO LOOK LIKE A BUTTON. Dim text
              // on the panel colour made it disappear into the popover's
              // background - so the keypad looked like it had no way to submit
              // until you had already typed something, which is exactly
              // backwards from what a first-time user needs.
              style: FilledButton.styleFrom(
                  backgroundColor: _hz == null ? T.panelDeep : T.cyanFill,
                  foregroundColor: _hz == null ? T.dim : T.cyan,
                  disabledBackgroundColor: T.panelDeep,
                  disabledForegroundColor: T.dim,
                  side: BorderSide(color: _hz == null ? T.line : T.cyan),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5))),
              onPressed: _hz == null ? null : () => widget.onEnter(_hz!),
              child: Text(
                  _buf.isEmpty ? 'TYPE A FREQUENCY' : (_hz == null ? 'OUT OF RANGE' : 'GO'),
                  style: const TextStyle(letterSpacing: 2, fontSize: 12)),
            ),
          ),
        ]),
      );

  Widget _key(String k) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: SizedBox(
          width: 68,
          height: 44,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                backgroundColor: T.panelDeep,
                foregroundColor: T.text,
                side: const BorderSide(color: T.line),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
            onPressed: () => setState(() {
              if (k == '⌫') {
                if (_buf.isNotEmpty) _buf = _buf.substring(0, _buf.length - 1);
              } else if (k == '.') {
                if (!_buf.contains('.')) _buf += '.';
              } else {
                _buf += k;
              }
            }),
            child: Text(k,
                style: const TextStyle(fontFamily: T.mono, fontSize: 17)),
          ),
        ),
      );
}

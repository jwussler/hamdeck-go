import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'audio/audio.dart';
import 'theme.dart';

void main() => runApp(const HamDeckApp());

class HamDeckApp extends StatelessWidget {
  const HamDeckApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HamDeck',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(scaffoldBackgroundColor: T.ground, useMaterial3: true),
        home: const Panel(),
      );
}

class Panel extends StatefulWidget {
  const Panel({super.key});
  @override
  State<Panel> createState() => _PanelState();
}

class _PanelState extends State<Panel> {
  // ⚠️ NO DEFAULT HOST, EVER. A hostname compiled into a published client points
  // every install at one person's station - the same rule as the C++ client.
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  Api? _api;
  // ⚠️ The platform implementation is chosen at COMPILE time - a desktop
  // build never sees Web Audio, and a web build never sees dart:io.
  final _rx = makeRxPlayer();
  final _tx = makeTxCapture();
  Map<String, dynamic>? _rig;
  String? _error;
  Timer? _poll;
  List<MicDevice> _mics = const [];
  DateTime? _lastGood;

  @override
  void dispose() {
    _poll?.cancel();
    _rx.stop();
    _tx.stop();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // ⚠️ SERVED BY THE HOST, SO IT ALREADY KNOWS WHERE IT IS - IN A BROWSER.
    // Asking the operator to type the address of the machine that just sent them
    // the page is a question with one possible answer, and getting it slightly
    // wrong (http:// typed on an https:// page) is a mixed-content block the
    // browser reports as a network error with no clue what to fix.
    //
    // ⚠️ AND ON A DESKTOP THERE IS NO ORIGIN AT ALL. Uri.base is a file:// path
    // there and .origin THROWS - "Origin is only applicable schemes http and
    // https" - which crashed the Linux app on its first frame, before anything
    // was drawn. The web fix broke the desktop build, and only launching it
    // showed that. There is deliberately no default host on desktop: a hostname
    // compiled into a published client points every install at one station.
    final base = Uri.base;
    if (base.scheme == 'http' || base.scheme == 'https') {
      _host.text = base.origin;
    }
  }

  Future<void> _connect() async {
    var typed = _host.text.trim();
    if (typed.isEmpty && (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
      typed = Uri.base.origin;
    }
    if (typed.isEmpty) {
      setState(() => _error = 'enter the host address, e.g. radio.example.com:5102');
      return;
    }
    // ⚠️ Inherit the PAGE's scheme when none was typed. Defaulting to http on an
    // https page is the same block, arrived at politely.
    final scheme = (Uri.base.scheme == 'https') ? 'https' : 'http';
    final base = typed.startsWith('http') ? typed : '$scheme://$typed';
    final api = Api(base);
    final err = await api.login(_user.text.trim(), _pass.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    // The password has been used; it is not kept in a field afterwards.
    _pass.clear();
    setState(() {
      _api = api;
      _error = null;
    });
    // ⚠️ THE RECEIVER STARTS WITH THE SESSION. An operator who logs into a radio
    // panel wants to HEAR the radio; making them find a second button to turn on
    // the thing they came for is a menu, not a feature.
    _rx.start(api.base, api.token ?? '');

    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final s = await _api!.status();
      if (!mounted) return;
      setState(() {
        // the audio meters are updated by their own callbacks; this repaint is
        // what makes them visible
        if (s != null) {
          _rig = s;
          _lastGood = DateTime.now();
        }
      });
    });
  }

  // ⚠️ A READING THAT HAS STOPPED ARRIVING IS NOT A READING. The panel greys and
  // says how old it is rather than showing a frequency that may have moved.
  bool get _stale =>
      _lastGood == null || DateTime.now().difference(_lastGood!).inSeconds >= 3;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: SafeArea(child: _api == null ? _connectScreen() : _panel()));

  Widget _connectScreen() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            RichText(
              text: const TextSpan(children: [
                TextSpan(
                    text: 'HAM',
                    style: TextStyle(
                        color: T.text, fontSize: 34, fontWeight: FontWeight.bold)),
                TextSpan(
                    text: 'DECK',
                    style: TextStyle(
                        color: T.cyan, fontSize: 34, fontWeight: FontWeight.bold)),
              ]),
            ),
            const SizedBox(height: 6),
            Text('Go host · Flutter panel', style: T.silk()),
            const SizedBox(height: 22),
            _field('HOST', _host, hint: 'address:5102'),
            _field('USERNAME', _user),
            _field('PASSWORD', _pass, obscure: true, onSubmit: _connect),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: T.cyanFill,
                    foregroundColor: T.cyan,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: const BorderSide(color: T.cyan))),
                onPressed: _connect,
                child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('CONNECT', style: TextStyle(letterSpacing: 1.4))),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: T.txRed, fontSize: 13)),
            ],
          ]),
        ),
      );

  Widget _field(String label, TextEditingController c,
          {bool obscure = false, String? hint, VoidCallback? onSubmit}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: T.silk()),
          const SizedBox(height: 4),
          TextField(
            controller: c,
            obscureText: obscure,
            onSubmitted: (_) => onSubmit?.call(),
            style: const TextStyle(color: T.text, fontFamily: T.mono),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: T.dim),
              filled: true,
              fillColor: T.ground,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: T.line)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: T.cyan)),
            ),
          ),
        ]),
      );

  String _freqText() {
    final hz = (_rig?['freq'] as num?)?.toInt() ?? 0;
    if (hz <= 0) return '—.———.———';
    final s = hz.toString().padLeft(9, '0');
    return '${int.parse(s.substring(0, s.length - 6))}'
        '.${s.substring(s.length - 6, s.length - 3)}'
        '.${s.substring(s.length - 3)}';
  }


  // ⚠️ SILENCE IS A FAULT, AND IT MUST SHOUT. 1098 packets of perfect silence
  // went to the transmitter with ON AIR lit and every counter healthy, because
  // "mic 0%" is six quiet characters next to a big red bar. A muted microphone,
  // a webcam picked as the system default and a working operator all produce
  // frames at exactly the right rate; the LEVEL is the only thing that tells
  // them apart, so the level is what gets the loud treatment.
  Future<void> _loadMics() async {
    final list = await _tx.devices();
    if (!mounted) return;
    setState(() => _mics = list);
    // Meter the microphone straight away. Nothing is sent and the radio is not
    // touched - it just means a dead microphone is visible before it matters.
    if (!_tx.running) await _tx.startMonitor();
  }

  bool get _sendingSilence =>
      _tx.running && _tx.packets > 40 && _tx.level == 0;

  Widget _micStatus() {
    final bad = _sendingSilence || _tx.radioRouting.startsWith('⚠');
    final String line;
    if (!_tx.running) {
      line = 'not armed — the radio keeps its own microphone';
    } else if (_sendingSilence) {
      line = '⚠ THE MICROPHONE IS SENDING SILENCE — nothing is going out\n'
          '${_tx.packets} packets, all of them empty. Check the microphone below.';
    } else {
      line = '${_tx.radioRouting}\nmic ${_tx.level}% · ${_tx.packets} packets';
    }
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
          color: _sendingSilence ? T.txRed.withValues(alpha: 0.18) : T.ground,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: bad ? T.txRed : T.line)),
      child: Text(line,
          style: TextStyle(
              fontFamily: T.mono,
              fontSize: 10,
              color: bad ? T.txRed : T.dim)),
    );
  }

  // ⚠️ The operator picks the microphone, and can see it working BEFORE keying.
  // Taking whatever the operating system calls "default" is what put silence on
  // the air: on a Windows desktop the default input is very often a webcam, a
  // monitor, or nothing at all.
  Widget _micPicker() => Padding(
        padding: const EdgeInsets.only(left: 10, right: 10, bottom: 6),
        child: Row(children: [
          Text('MIC', style: T.silk()),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                  color: T.ground,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: T.line)),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _tx.device?.id ?? '',
                  dropdownColor: T.panel,
                  style: const TextStyle(
                      color: T.text, fontFamily: T.mono, fontSize: 11),
                  items: [
                    const DropdownMenuItem(
                        value: '', child: Text('system default')),
                    for (final d in _mics)
                      DropdownMenuItem(value: d.id, child: Text(d.label)),
                  ],
                  onChanged: (v) async {
                    _tx.device = (v == null || v.isEmpty)
                        ? null
                        : _mics.firstWhere((d) => d.id == v);
                    // ⚠️ Restart the capture so the choice takes effect NOW.
                    // A picker that only applies at the next arm looks broken,
                    // and the operator finds out mid-over.
                    if (_tx.running) {
                      await _tx.stop();
                      await _tx.start(_api!.base, _api!.token ?? '');
                    }
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // A live level, so the microphone can be proved before keying.
          SizedBox(
            width: 90,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _tx.level / 100.0,
                minHeight: 10,
                backgroundColor: T.ground,
                valueColor: AlwaysStoppedAnimation(
                    _sendingSilence ? T.txRed : T.okGreen),
              ),
            ),
          ),
        ]),
      );

  Widget _panel() {
    final tx = _rig?['tx'] == true;
    return Column(children: [
      Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
            color: T.ground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tx ? T.txRed : T.line)),
        child: Column(children: [
          Text(_freqText(),
              style: TextStyle(
                  // ⚠️ Greyed when stale rather than hidden: an operator must be
                  // able to see WHAT it last was and that it is old.
                  color: _stale ? T.amberDim : T.amber,
                  fontSize: 46,
                  fontFamily: T.mono,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _stat('MODE', '${_rig?['mode'] ?? '—'}'),
            _stat('VFO', '${_rig?['vfo'] ?? '—'}'),
            _stat('POWER', '${_rig?['power'] ?? '—'} W'),
          ]),
        ]),
      ),
      _meter(),
      const SizedBox(height: 6),
      _audioBar(),
      const SizedBox(height: 8),
      _keys('MODE', const ['LSB', 'USB', 'CW', 'AM', 'FM', 'DATA'],
          (m) => '/api/mode/$m', selected: '${_rig?['mode']}'),
      const Spacer(),
      // ⚠️ ARM AND PTT ARE SEPARATE, and that is not a UI preference. Arming
      // claims the audio path and points the RADIO at it; PTT keys the
      // transmitter. Rolling them into one control means connecting can land you
      // at the start of an over.
      Padding(
        padding: const EdgeInsets.only(left: 10, right: 10, bottom: 4),
        child: Row(children: [
          SizedBox(
            width: 110,
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: _tx.running ? T.cyanFill : T.panel,
                  foregroundColor: _tx.running ? T.cyan : T.text,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: BorderSide(color: _tx.running ? T.cyan : T.line))),
              onPressed: () async {
                if (_tx.running) {
                  await _tx.stop();
                } else {
                  await _tx.start(_api!.base, _api!.token ?? '');
                }
                if (mounted) setState(() {});
              },
              child: Text(_tx.running ? 'ARMED' : 'ARM',
                  style: const TextStyle(letterSpacing: 1.4)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _micStatus()),
        ]),
      ),
      _micPicker(),
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: 62,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: tx ? T.txRed : T.panel,
                    foregroundColor: tx ? Colors.white : T.text,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: BorderSide(color: tx ? T.txRed : T.line))),
                // ⚠️ Reads the RIG's tx state, never its own click - and sends
                // the opposite of what the radio says it is doing.
                onPressed: () async {
                  await _api!.send(tx ? '/api/ptt/off' : '/api/ptt/on');
                  final s = await _api!.status();
                  if (mounted && s != null) setState(() => _rig = s);
                },
                child: Text(tx ? 'ON AIR' : 'PTT',
                    style: const TextStyle(letterSpacing: 2, fontSize: 16)),
              ),
            ),
          ),
        ]),
      ),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: T.ground,
        child: Text(
          _stale
              ? '⚠ no reply from the host — showing the last reading'
              : 'audio: ${_rx.status} · ${_rx.packets} packets · level ${_rx.level}%',
          style: TextStyle(
              color: _stale ? T.amber : T.dim, fontSize: 11, fontFamily: T.mono),
        ),
      ),
    ]);
  }

  /// ⚠️ THE CLIENT'S OWN MEASUREMENT OF WHAT IT PLAYED, not the host's of what it
  /// captured. The two can disagree, and the disagreement is the interesting
  /// case: audio that left the radio and never reached the operator. Nothing
  /// else in this panel can tell you that.
  Widget _audioBar() {
    final lvl = _rx.level / 100.0;
    final dead = _rx.playing && _rx.level == 0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: T.ground,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: dead ? T.amber : T.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(dead ? 'RECEIVER · ARRIVING SILENT' : 'RECEIVER', style: T.silk()),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: lvl,
            minHeight: 14,
            backgroundColor: T.panelDeep,
            valueColor: AlwaysStoppedAnimation(dead ? T.amber : T.cyan),
          ),
        ),
      ]),
    );
  }

  Widget _stat(String k, String v) => Column(children: [
        Text(k, style: T.silk()),
        Text(v,
            style: const TextStyle(
                color: T.text, fontSize: 18, fontFamily: T.mono)),
      ]);

  Widget _meter() {
    final raw = ((_rig?['s_meter'] as num?)?.toInt() ?? 0) / 255.0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: T.ground,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SIGNAL', style: T.silk()),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: _stale ? 0 : raw,
            minHeight: 14,
            backgroundColor: T.panelDeep,
            valueColor: AlwaysStoppedAnimation(_stale ? T.amberDim : T.okGreen),
          ),
        ),
      ]),
    );
  }

  Widget _keys(String title, List<String> labels, String Function(String) path,
      {String? selected}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: T.panel,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: T.silk()),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: labels.map((l) {
            final on = selected == l;
            return SizedBox(
              width: 92,
              height: 44,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    backgroundColor: on ? T.cyanFill : T.panelDeep,
                    foregroundColor: on ? T.cyan : T.text,
                    side: BorderSide(color: on ? T.cyan : T.line),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5))),
                onPressed: () async {
                  await _api!.send(path(l.toLowerCase()));
                  final s = await _api!.status();
                  if (mounted && s != null) setState(() => _rig = s);
                },
                child: Text(l, style: const TextStyle(letterSpacing: 1)),
              ),
            );
          }).toList(),
        ),
      ]),
    );
  }
}

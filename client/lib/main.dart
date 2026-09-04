import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'audio/audio.dart';
import 'keypad.dart';
import 'readout.dart';
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
  bool _tuning = false;
  Map<String, dynamic>? _meters;
  Map<String, dynamic>? _rec;
  String _tunerMsg = '';
  DateTime? _lastGood;

  // ── The operating surface ──────────────────────────────────────────────
  //
  // ⚠️ TWO SURFACES, NOT ONE SCROLL. The first version put 97 controls in one
  // scrolling column at equal visual weight, so the things you touch every over
  // and the things you set once a year were the same size and in the same list -
  // and the operator hunts. If you set it once a year it is not on the operating
  // surface. Nothing is removed; things move.
  int _surface = 0; // 0 OPERATE, 1 SETUP
  bool _keypad = false;

  // ⚠️ SHOW THE LINK, NOT JUST THE RIG. Remote operating fails at the link far
  // more often than at the radio, and every other program in this space leaves
  // the operator guessing - a panel that looks identical on a healthy and a
  // jittering link is lying by omission. Jitter matters more than latency:
  // steady 250 ms is workable, 40 ms that keeps moving is not.
  final List<int> _rtt = [];
  int get _rttMs => _rtt.isEmpty ? 0 : _rtt.reduce((a, b) => a + b) ~/ _rtt.length;
  int get _jitterMs {
    if (_rtt.length < 2) return 0;
    final mean = _rttMs;
    var sum = 0;
    for (final v in _rtt) {
      sum += (v - mean).abs();
    }
    return sum ~/ _rtt.length;
  }

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

    // ⚠️ AND THE MICROPHONE IS LISTED AND METERED IMMEDIATELY. This call was
    // written and never wired up, so the picker only ever offered "system
    // default" and the level bar never moved - which is precisely the fault it
    // was written to catch. Nothing is transmitted and the radio is not touched;
    // it just means a dead input is visible before it matters.
    _loadMics();

    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final t0 = DateTime.now();
      final s = await _api!.status();
      if (s != null) {
        _rtt.add(DateTime.now().difference(t0).inMilliseconds);
        // A short window: what the link is doing NOW, not its history.
        if (_rtt.length > 12) _rtt.removeAt(0);
      }
      // ⚠️ The tune state comes from the HOST, not from the button. The client
      // that started the tune can be closed, crash, or be a different machine
      // entirely, and the carrier is still on the air - so the panel asks who
      // actually knows rather than remembering what it did.
      final t = await _api!.send('/api/tune/tgxl/status');
      final m = await _api!.send('/api/meters');
      final rc = await _api!.send('/api/record/status');
      if (!mounted) return;
      setState(() {
        if (m != null) _meters = m;
        if (rc != null) _rec = rc;
        if (t != null) {
          _tuning = t['tuning'] == true;
          // ⚠️ Say WHEN the message is from. The host keeps the last tune's
          // result, so a failure from ten minutes ago was being drawn next to an
          // idle button as though it were happening now - a stale message
          // presented as current is the same fault as a stale meter reading.
          final msg = t['message'] as String? ?? '';
          _tunerMsg = (t['available'] == false)
              ? 'no tuner configured on this host'
              : (_tuning || msg.isEmpty ? msg : 'last tune: $msg');
        }
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

  // ⚠️ THE SHAPE OF THE WHOLE THING, and every line of it is a rule from
  // docs/internal/UI-DESIGN.md in the C++ repo - which was researched, argued
  // and then never built. The first Flutter panel reproduced the exact fault
  // that document was written about.
  //
  //   head        readout + meters + the LINK, always visible
  //   surface     OPERATE or SETUP, scrolls
  //   transmit    PINNED, on both surfaces, never behind a scroll
  Widget _panel() => Stack(children: [
        Column(children: [
          _head(),
          Expanded(
            child: SingleChildScrollView(
              child: _surface == 0 ? _operate() : _setup(),
            ),
          ),
          // ⚠️ PINNED, AND ON BOTH SURFACES. Stopping a transmission is never
          // behind a scroll, a tab or a popup. A control operator has to be able
          // to end a transmission immediately; a panel where PTT scrolled off
          // the bottom failed that outright, and it did.
          _transmitBar(),
        ]),
        // The keypad floats OVER the panel, deliberately not modal - a modal
        // popup would grey out the transmit bar behind it.
        if (_keypad)
          Positioned(
            top: 96,
            left: 24,
            child: Keypad(onEnter: (hz) async {
              setState(() => _keypad = false);
              await _api!.send('/api/freq/set/$hz');
              final st = await _api!.status();
              if (mounted && st != null) setState(() => _rig = st);
            }),
          ),
      ]);

  // ── The head: what the station is doing, and whether we can trust it ──────
  Widget _head() {
    final tx = _rig?['tx'] == true;
    final hz = (_rig?['freq'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
          color: T.panelDeep,
          border: Border(bottom: BorderSide(color: tx ? T.txRed : T.line, width: tx ? 2 : 1))),
      child: Column(children: [
        Row(children: [
          _tab('OPERATE', 0),
          const SizedBox(width: 6),
          _tab('SETUP', 1),
          const Spacer(),
          _linkPill(),
        ]),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          // Band and mode sit left of the readout, the way they do on a rig.
          SizedBox(
            width: 92,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_bandName(hz),
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 17, color: T.text)),
              Text('${_rig?['mode'] ?? '—'}',
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 15, color: T.dim)),
            ]),
          ),
          Expanded(
            child: Center(
              child: Readout(
                hz: hz,
                stale: _stale,
                tx: tx,
                onSet: (v) async {
                  await _api!.send('/api/freq/set/$v');
                  final st = await _api!.status();
                  if (mounted && st != null) setState(() => _rig = st);
                },
                onKeypad: () => setState(() => _keypad = !_keypad),
              ),
            ),
          ),
          SizedBox(
            width: 118,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('VFO ${_rig?['vfo'] ?? '—'}',
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 14, color: T.dim)),
              Text('${_rig?['power'] ?? '—'} W',
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 17, color: T.text)),
              if (_rig?['split'] == true)
                Text('SPLIT ${_fmt((_rig?['freq_b'] as num?)?.toInt() ?? 0)}',
                    style: const TextStyle(
                        fontFamily: T.mono, fontSize: 11, color: T.amber)),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        // ⚠️ A hint, once, where the gesture lives. The readout being the tuning
        // control is the single most useful thing here and the least guessable.
        const Text('wheel or click a digit to tune  ·  shift-click zeroes below  ·  right-click for the keypad',
            style: TextStyle(fontFamily: T.mono, fontSize: 9, color: T.dim)),
        const SizedBox(height: 8),
        _meter(),
      ]),
    );
  }

  Widget _tab(String label, int i) {
    final on = _surface == i;
    return GestureDetector(
      onTap: () => setState(() => _surface = i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
            color: on ? T.cyanFill : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: on ? T.cyan : T.line)),
        child: Text(label,
            style: TextStyle(
                fontFamily: T.mono,
                fontSize: 11,
                letterSpacing: 1.4,
                color: on ? T.cyan : T.dim)),
      ),
    );
  }

  /// ⚠️ A NUMBER AND A COLOUR. The colour reads at a glance, the number is the
  /// evidence behind it. And a STALE RIG OUTRANKS A FAST LINK: 12 ms to a host
  /// that cannot hear the radio is not a healthy station, so staleness wins the
  /// colour whatever the round-trip says.
  Widget _linkPill() {
    final Color c;
    final String text;
    if (_api == null) {
      c = T.dim;
      text = 'not connected';
    } else if (_stale) {
      c = T.txRed;
      text = 'RIG STALE · the host is not hearing the radio';
    } else if (_rtt.isEmpty) {
      c = T.dim;
      text = 'measuring the link';
    } else {
      final bad = _rttMs > 400 || _jitterMs > 60;
      final warn = _rttMs > 200 || _jitterMs > 25;
      c = bad ? T.txRed : (warn ? T.amber : T.okGreen);
      text = 'link ${_rttMs} ms · jitter ${_jitterMs} ms';
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(text,
          style: TextStyle(fontFamily: T.mono, fontSize: 10, color: c)),
    ]);
  }

  String _bandName(int hz) {
    if (hz <= 0) return '—';
    const bands = {
      '160': [1800000, 2000000], '80': [3500000, 4000000],
      '60': [5300000, 5500000], '40': [7000000, 7300000],
      '30': [10100000, 10150000], '20': [14000000, 14350000],
      '17': [18068000, 18168000], '15': [21000000, 21450000],
      '12': [24890000, 24990000], '10': [28000000, 29700000],
      '6': [50000000, 54000000],
    };
    for (final e in bands.entries) {
      if (hz >= e.value[0] && hz <= e.value[1]) return '${e.key}M';
    }
    // ⚠️ Out of band says so rather than picking the nearest. "Which band am I
    // on" answered with a guess is worse than answered with a warning.
    return 'OUT OF BAND';
  }

  String _fmt(int hz) {
    if (hz <= 0) return '—';
    final s = hz.toString().padLeft(9, '0');
    return '${int.parse(s.substring(0, 3))}.${s.substring(3, 6)}.${s.substring(6)}';
  }

  // ── OPERATE: everything reached during a contact, one click deep ──────────
  Widget _operate() => Column(children: [
        const SizedBox(height: 8),
        // ⚠️ BAND GETS ITS OWN FULL-WIDTH ROW. Squeezed into a column beside
        // the VFO block it wrapped to two ragged rows and pushed MODE into a
        // narrow indented strip that looked like a rendering fault. Eleven bands
        // is a row; that is what the row is for.
        _keys('BAND', const ['160', '80', '60', '40', '30', '20', '17',
            '15', '12', '10', '6'], (b) => '/api/band/$b',
            selected: _bandName((_rig?['freq'] as num?)?.toInt() ?? 0)
                .replaceAll('M', '')),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _keys('MODE', const ['LSB', 'USB', 'CW', 'AM', 'FM', 'DATA'],
                (m) => '/api/mode/$m', selected: '${_rig?['mode']}'),
          ),
          Expanded(
            child: _group('VFO', [
              _btn('A', () => _api!.send('/api/vfo/a')),
              _btn('B', () => _api!.send('/api/vfo/b')),
              _btn('SWAP', () => _api!.send('/api/vfo/swap')),
              _btn('A▸B', () => _api!.send('/api/vfo-copy/a2b')),
              _btn('B▸A', () => _api!.send('/api/vfo-copy/b2a')),
              _btn('SPLIT', () => _api!.send('/api/split/toggle'),
                  on: _rig?['split'] == true),
              _btn('QUICK', () => _api!.send('/api/quick-split')),
              _btn('LOCK', () => _api!.send('/api/toggle/lock'),
                  on: _rig?['vfo_locked'] == true),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        _group('RECEIVER', [
          _btn('AGC', () => _api!.send('/api/agc/cycle')),
          _btn('PRE', () => _api!.send('/api/preamp/cycle')),
          _btn('ANT', () => _api!.send('/api/ant/toggle')),
          _btn('NOTCH', () => _api!.send('/api/notch/toggle')),
          _btn('MON', () => _api!.send('/api/mon/toggle')),
          _btn('COMP', () => _api!.send('/api/comp/toggle')),
          _btn('NARROW', () => _api!.send('/api/width/narrow')),
          _btn('MED', () => _api!.send('/api/width/medium')),
          _btn('WIDE', () => _api!.send('/api/width/wide')),
          _btn('VOL −', () => _api!.send('/api/volume/down')),
          _btn('VOL +', () => _api!.send('/api/volume/up')),
        ]),
        const SizedBox(height: 8),
        // ⚠️ RIT IS PINNED HERE, not in Setup. Chasing a station that is
        // drifting is a mid-contact job; a control you need mid-over does not
        // live behind a tab.
        _group('RIT  ·  STEP', [
          _btn('RIT −', () => _api!.send('/api/rit/down')),
          _btn('RIT +', () => _api!.send('/api/rit/up')),
          _btn('CLR', () => _api!.send('/api/rit/clear')),
          _btn('−1 k', () => _step(1000, 'down')),
          _btn('+1 k', () => _step(1000, 'up')),
          _btn('−100', () => _step(100, 'down')),
          _btn('+100', () => _step(100, 'up')),
        ]),
        const SizedBox(height: 8),
        _powerRow(),
        const SizedBox(height: 10),
      ]);

  // ── SETUP: nothing here is touched during a contact ───────────────────────
  Widget _setup() => Column(children: [
        const SizedBox(height: 8),
        _micPicker(),
        _recRow(),
        const SizedBox(height: 8),
        _group('THIS STATION', [], note: ''),
        const SizedBox(height: 10),
      ]);


  // ── The transmit bar: pinned, on every surface ───────────────────────────
  //
  // ⚠️ THE ONE PLACE NOTHING MAY EVER SCROLL AWAY FROM. Remote control means
  // being able to end a transmission immediately, and the first version of this
  // panel put PTT below the fold on a short window - an armed transmitter you
  // could not unkey from the panel. It is fixed here, on both surfaces, and the
  // keypad floats over the rest of the screen rather than covering it.
  //
  // ⚠️ IT GIVES WAY IN A FIXED ORDER when the window is narrow: the meters go
  // first, then the status text, then the tuner labels shorten. PTT is the last
  // thing to shrink, because the key that goes off the edge of a transmit bar is
  // the one somebody needs in a hurry.
  Widget _transmitBar() {
    final tx = _rig?['tx'] == true;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
          // Opaque. A transparent bar let the panel scroll visibly underneath
          // the transmit keys, which reads as the keys moving.
          color: T.panelDeep,
          border: Border(top: BorderSide(color: tx ? T.txRed : T.line, width: tx ? 2 : 1))),
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth > 900;
        final medium = box.maxWidth > 640;
        return Column(children: [
          if (_sendingSilence) ...[
            _silenceAlarm(),
            const SizedBox(height: 6),
          ],
          Row(children: [
            SizedBox(
              width: 92,
              height: 46,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: _tx.running ? T.cyanFill : T.panel,
                    foregroundColor: _tx.running ? T.cyan : T.text,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                        side: BorderSide(color: _tx.running ? T.cyan : T.line))),
                onPressed: () async {
                  if (_tx.running) {
                    await _tx.stop();
                    await _tx.startMonitor();
                  } else {
                    await _tx.start(_api!.base, _api!.token ?? '');
                  }
                  if (mounted) setState(() {});
                },
                child: Text(_tx.running ? 'ARMED' : 'ARM',
                    style: const TextStyle(letterSpacing: 1.2, fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            // PTT: the widest thing in the bar, and the last to give way.
            Expanded(
              flex: 3,
              child: SizedBox(
                height: 46,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: tx ? T.txRed : T.panel,
                      foregroundColor: tx ? Colors.white : T.text,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                          side: BorderSide(color: tx ? T.txRed : T.line))),
                  onPressed: () async {
                    await _api!.send(tx ? '/api/ptt/off' : '/api/ptt/on');
                    final st = await _api!.status();
                    if (mounted && st != null) setState(() => _rig = st);
                  },
                  child: Text(tx ? 'ON AIR  —  TAP TO STOP' : 'PTT',
                      style: const TextStyle(letterSpacing: 2, fontSize: 14)),
                ),
              ),
            ),
            if (medium) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: wide ? 128 : 96,
                height: 46,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      backgroundColor: _tuning ? T.amber : T.panel,
                      foregroundColor: _tuning ? T.ground : T.text,
                      side: BorderSide(color: _tuning ? T.amber : T.line),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5))),
                  onPressed: _tuning ? null : () async {
                    await _api!.send('/api/tune/tgxl');
                    if (mounted) setState(() => _tuning = true);
                  },
                  child: Text(_tuning ? 'TUNING…' : (wide ? 'TUNE TG-XL' : 'TUNE'),
                      style: const TextStyle(letterSpacing: 1, fontSize: 11)),
                ),
              ),
            ],
            if (wide) ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 88,
                height: 46,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      backgroundColor: T.panel,
                      foregroundColor: T.text,
                      side: const BorderSide(color: T.line),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5))),
                  onPressed: _tuning ? null : () => _api!.send('/api/tune'),
                  child: const Text('RIG ATU',
                      style: TextStyle(letterSpacing: 1, fontSize: 11)),
                ),
              ),
            ],
            if (wide) ...[
              const SizedBox(width: 10),
              // ⚠️ MIC AND RECEIVE LEVEL LIVE HERE, next to the key. Setting
              // drive means watching a level while you talk, and the level was
              // three scrolls away from the button that puts you on the air.
              SizedBox(
                width: 150,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  _levelStrip('MIC', _tx.level, _sendingSilence ? T.txRed : T.okGreen),
                  const SizedBox(height: 4),
                  _levelStrip('RX', _rx.level, T.cyan),
                ]),
              ),
            ],
          ]),
          if (!wide) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: _levelStrip('MIC', _tx.level,
                  _sendingSilence ? T.txRed : T.okGreen)),
              const SizedBox(width: 8),
              Expanded(child: _levelStrip('RX', _rx.level, T.cyan)),
            ]),
          ],
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: Text(
                  _tx.running ? _tx.radioRouting : 'not armed — the radio keeps its own microphone',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: T.mono,
                      fontSize: 9,
                      color: _tx.radioRouting.startsWith('⚠') ? T.txRed : T.dim)),
            ),
            if (_tunerMsg.isNotEmpty)
              Text(_tunerMsg,
                  style: TextStyle(
                      fontFamily: T.mono,
                      fontSize: 9,
                      color: _tuning ? T.amber : T.dim)),
          ]),
        ]);
      }),
    );
  }

  Widget _levelStrip(String label, int pct, Color c) => Row(children: [
        SizedBox(
            width: 26,
            child: Text(label,
                style: const TextStyle(
                    fontFamily: T.mono, fontSize: 9, color: T.dim))),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (pct / 100.0).clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: T.ground,
              valueColor: AlwaysStoppedAnimation(c),
            ),
          ),
        ),
      ]);

  // ⚠️ SILENCE IS A FAULT AND IT MUST SHOUT. 1098 packets of perfect silence
  // went to the transmitter under a lit ON AIR bar, because "mic 0%" is six
  // quiet characters. A muted microphone, a webcam picked as the system default
  // and a working operator all produce frames at exactly the right rate.
  Widget _silenceAlarm() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: T.txRed.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: T.txRed)),
        child: Text(
            '⚠  THE MICROPHONE IS SENDING SILENCE — ${_tx.packets} packets, all empty. '
            'Pick a different microphone in SETUP.',
            style: const TextStyle(
                fontFamily: T.mono, fontSize: 10, color: T.txRed)),
      );

  Widget _meter() {
    // ⚠️ THE S-METER IS NOT LINEAR AND S9 IS NOT TWO-THIRDS OF THE WAY UP. This
    // drew raw/255, which is what the C++ host wrote down as wrong: raw 160 is
    // S9 and the whole top third of the raw range is the 60 dB above it, so a
    // genuine S9 sat at 63% and an S3 at a fifth. The bar now runs on the
    // calibrated dB the host derives, and the number beside it is what an
    // operator would actually say out loud.
    final db = (_meters?['s_meter_db'] as num?)?.toInt();
    final unit = _meters?['s_unit'] as String? ?? '';
    final frac = db == null ? 0.0 : ((db + 60) / 120.0).clamp(0.0, 1.0);
    final tx = _rig?['tx'] == true;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: T.ground,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: tx ? T.txRed : T.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(tx ? 'TRANSMIT' : 'SIGNAL', style: T.silk()),
          const Spacer(),
          // ⚠️ Blank, not "S0", when the host could not read the meter. An S0
          // that was never measured looks exactly like a dead band.
          Text(_stale || db == null ? '—' : unit,
              style: TextStyle(
                  fontFamily: T.mono,
                  fontSize: 13,
                  color: _stale ? T.amberDim : T.okGreen)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: _stale ? 0 : frac,
            minHeight: 14,
            backgroundColor: T.panelDeep,
            valueColor: AlwaysStoppedAnimation(_stale ? T.amberDim : T.okGreen),
          ),
        ),
        // ⚠️ THE TRANSMIT METERS ONLY EXIST WHILE KEYED. Drawing SWR while
        // receiving shows a flat 1.0 as though it had been measured - a perfect
        // match reported by a radio that is not transmitting.
        if (tx) ...[
          const SizedBox(height: 8),
          Row(children: [
            _txMeter('SWR',
                (_meters?['swr_ratio'] as num?)?.toDouble().toStringAsFixed(1) ?? '—',
                // SWR 1.0 is the left end and 5.0 the right; ?? binds looser
                // than -, so the parentheses are load-bearing.
                ((((_meters?['swr_ratio'] as num?)?.toDouble()) ?? 1.0) - 1.0) / 4.0),
            const SizedBox(width: 10),
            _txMeter('ALC', '${_meters?['alc_pct'] ?? '—'}%',
                ((_meters?['alc_pct'] as num?)?.toDouble() ?? 0) / 100.0),
            const SizedBox(width: 10),
            _txMeter('PWR', '${_meters?['power_pct'] ?? '—'}%',
                ((_meters?['power_pct'] as num?)?.toDouble() ?? 0) / 100.0),
          ]),
        ],
      ]),
    );
  }

  Widget _txMeter(String label, String value, double frac) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: T.silk()),
            const Spacer(),
            Text(value,
                style: const TextStyle(
                    fontFamily: T.mono, fontSize: 11, color: T.amber)),
          ]),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: frac.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: T.panelDeep,
              valueColor: const AlwaysStoppedAnimation(T.amber),
            ),
          ),
        ]),
      );

  Widget _powerRow() {
    final w = (_rig?['power'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: T.panel,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.line)),
      child: Row(children: [
        Text('POWER', style: T.silk()),
        const SizedBox(width: 12),
        SizedBox(
          width: 62,
          child: Text('$w W',
              style: const TextStyle(
                  fontFamily: T.mono, fontSize: 16, color: T.amber)),
        ),
        Expanded(
          child: Slider(
            value: w.clamp(0, 100).toDouble(),
            max: 100,
            divisions: 20,
            activeColor: T.amber,
            inactiveColor: T.line,
            label: '$w W',
            // ⚠️ Sent on RELEASE, not on every drag frame. A slider that fires
            // per frame puts a hundred CAT writes on a serial port that answers
            // one at a time, and the radio ends up wherever the queue drained
            // to rather than where the operator let go.
            onChanged: (v) => setState(
                () => _rig = {...?_rig, 'power': v.round()}),
            onChangeEnd: (v) async {
              await _api!.send('/api/power/set/${v.round()}');
              final st = await _api!.status();
              if (mounted && st != null) setState(() => _rig = st);
            },
          ),
        ),
      ]),
    );
  }


  // ── VFO, RIT and the receiver controls ──────────────────────────────────
  //
  Widget _recRow() {
    final on = _rec?['recording'] == true;
    final avail = _rec?['available'] == true;
    return _group('RECORDING', [
      _btn(on ? 'STOP' : 'RECORD',
          avail ? () => _api!.send('/api/record/toggle') : null,
          on: on),
      _btn('SAVE LAST ${_rec?['replay_seconds'] ?? 0}s',
          avail ? () => _api!.send('/api/record/replay') : null),
    ], note: avail
        ? (on ? 'recording · ${_rec?['seconds'] ?? 0}s' : (_rec?['message'] as String? ?? ''))
        : (_rec?['message'] as String? ?? 'not available on this host'));
  }

  Future<void> _step(int hz, String dir) async {
    await _api!.send('/api/step/$hz/$dir');
    final s = await _api!.status();
    if (mounted && s != null) setState(() => _rig = s);
  }

  Widget _group(String title, List<Widget> children, {String note = ''}) =>
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: T.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: T.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title, style: T.silk()),
            const Spacer(),
            if (note.isNotEmpty)
              Text(note,
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 10, color: T.dim)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ]),
      );

  // ⚠️ A null onPressed DISABLES the button rather than hiding it. A control
  // that vanishes when a feature is unavailable leaves the operator wondering
  // whether they misremembered where it was.
  // ⚠️ SIZED TO ITS TEXT, with a floor. A fixed 92 px broke "PREAMP" into
  // "PREA MP" and "NOTCH" into "NOTC H" - a control panel whose labels are cut
  // in half mid-word reads as broken before anybody presses anything, and the
  // widths are not knowable in advance because they change with the label.
  Widget _btn(String label, VoidCallback? tap, {bool on = false}) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 78, minHeight: 40, maxHeight: 40),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
              backgroundColor: on ? T.cyanFill : T.panelDeep,
              foregroundColor: on ? T.cyan : T.text,
              side: BorderSide(color: on ? T.cyan : T.line),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
          onPressed: tap == null ? null : () async {
            tap();
            final s = await _api!.status();
            if (mounted && s != null) setState(() => _rig = s);
          },
          child: Text(label,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(letterSpacing: 0.6, fontSize: 12)),
        ),
      );

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

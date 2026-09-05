import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'api.dart';
import 'audio/audio.dart';
import 'keymap.dart';
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
  // ⚠️ A SETTING, NOT PART OF THE ADDRESS. Blank means the standard port, which
  // is what a station behind a name uses. It lives under ADVANCED because
  // needing it at all means the host is not behind a proper name yet.
  final _port = TextEditingController();
  bool _advanced = false;

  // Receiver levels, read from the radio at connect and after every change.
  // ⚠️ NOT in the 2 Hz poll: every read is a CAT exchange on a serial line that
  // answers one question at a time, and the panel already asks it five things.
  int _af = 0;
  int _rf = 0;

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
  bool _showKeys = false;
  final _keyFocus = FocusNode(debugLabel: 'panel');

  // The tuning step the arrow keys move by. ⚠️ Shown on screen AND announced
  // when it changes: an operator who cannot see it has no other way to know how
  // far the next key press will move the radio.
  int _step = 100;
  static const _steps = [10, 100, 1000, 10000];

  // ⚠️ Remembered so the panel can ANNOUNCE the change rather than only draw it.
  // A blind operator has no ON AIR bar; being told is the only signal there is.
  bool _wasTx = false;
  bool _wasSilent = false;

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
    _keyFocus.dispose();
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
      // ⚠️ THE NAME, NOT THE ORIGIN. Filling this with "https://station.example.com"
      // teaches the operator that a scheme belongs in the box; it does not.
      // The port only appears when it is not the standard one - which is the
      // same rule the address bar uses.
      _host.text = base.host;
      if (base.hasPort && base.port != 443 && base.port != 80) {
        _port.text = '${base.port}';
        _advanced = true;
      }
    }
  }

  Future<void> _connect() async {
    if (_host.text.trim().isEmpty &&
        !(Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
      setState(() => _error = 'enter your station address');
      return;
    }
    final base = buildStationBase(_host.text, _port.text, Uri.base);
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
    _loadLevels();

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
        // ⚠️ SAY IT OUT LOUD. Transmit state and a microphone sending silence
        // are the two things that cannot be left to a colour on a bar.
        final nowTx = s?['tx'] == true;
        if (nowTx != _wasTx) {
          _wasTx = nowTx;
          announce(context, nowTx ? 'Transmitting' : 'Receiving', urgent: true);
        }
        final nowSilent = _sendingSilence;
        if (nowSilent && !_wasSilent) {
          announce(context,
              'Warning. The microphone is sending silence. Nothing is going out.',
              urgent: true);
        }
        _wasSilent = nowSilent;
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
            // ⚠️ A NAME, AND NOTHING ELSE. No scheme, no port: https is implied
            // and the port is under ADVANCED for the case where a host has no
            // name yet.
            //
            // ⚠️ AND NO EXAMPLE THAT IS SOMEBODY'S REAL STATION. A placeholder
            // naming one operator's host is a default host wearing a hat: it
            // ships in a public client, it gets typed by people who have their
            // own radio, and it points them at a station that is not theirs.
            // ⚠️ FOCUS STARTS WHERE THERE IS SOMETHING TO TYPE. Served by the
            // host, the address is already filled in, so the cursor belongs in
            // USERNAME - otherwise the first keystroke lands in a field that
            // was already correct and quietly breaks it.
            _field('STATION', _host,
                hint: 'hostname or IP address', autofocus: _host.text.isEmpty),
            _field('USERNAME', _user, autofocus: _host.text.isNotEmpty),
            _field('PASSWORD', _pass, obscure: true, onSubmit: _connect),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _advanced = !_advanced),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Text(_advanced ? 'hide advanced' : 'advanced',
                    style: const TextStyle(
                        fontFamily: T.mono, fontSize: 10, color: T.dim)),
              ),
            ),
            if (_advanced) ...[
              const SizedBox(height: 6),
              _field('PORT', _port, hint: 'blank = standard (443)'),
            ],
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
          {bool obscure = false, String? hint, VoidCallback? onSubmit,
          bool autofocus = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: T.silk()),
          const SizedBox(height: 4),
          TextField(
            controller: c,
            obscureText: obscure,
            autofocus: autofocus,
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

  /// ⚠️ Reads what the RADIO is set to rather than assuming a starting value -
  /// a slider drawn at 0 when the rig is at 88 is a control that lies until it
  /// is touched, and touching it is what an operator does to fix the lie.
  Future<void> _loadLevels() async {
    final af = await _api?.send('/api/volume/get');
    final rf = await _api?.send('/api/rf-gain/get');
    if (!mounted) return;
    setState(() {
      if (af?['read'] == true) _af = (af?['volume'] as num?)?.toInt() ?? _af;
      if (rf?['read'] == true) _rf = (rf?['rf_gain'] as num?)?.toInt() ?? _rf;
    });
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

  // ── Keyboard ──────────────────────────────────────────────────────────────
  //
  // ⚠️ ESCAPE STOPS TRANSMITTING, FROM ANYWHERE, ALWAYS - with the keypad open,
  // with the help sheet up, on either surface, whatever has focus. It is the
  // only shortcut that is unconditional, and it is the reason the overlays in
  // this panel are not modal.
  Future<void> _stopTransmitting() async {
    await _api?.send('/api/ptt/off');
    if (_tx.running) await _tx.stop();
    if (mounted) {
      announce(context, 'Stopped transmitting', urgent: true);
      setState(() {});
    }
  }

  Future<void> _tuneBy(int multiple) async {
    final hz = (_rig?['freq'] as num?)?.toInt() ?? 0;
    final next = hz + _step * multiple;
    if (next < 1800000 || next > 54000000) {
      announce(context, 'That would leave the band');
      return;
    }
    await _api!.send('/api/freq/set/$next');
    final st = await _api!.status();
    if (mounted && st != null) setState(() => _rig = st);
  }

  void _changeStep(int dir) {
    final i = (_steps.indexOf(_step) + dir).clamp(0, _steps.length - 1);
    setState(() => _step = _steps[i]);
    announce(context, _step >= 1000 ? '${_step ~/ 1000} kilohertz step' : '$_step hertz step');
  }

  Map<ShortcutActivator, VoidCallback> get _bindings => {
        // Transmit. ⚠️ Escape first, because order in this map is the order a
        // reader of this code learns them in.
        const SingleActivator(LogicalKeyboardKey.escape): () { _stopTransmitting(); },
        const SingleActivator(LogicalKeyboardKey.space): () async {
          final tx = _rig?['tx'] == true;
          await _api!.send(tx ? '/api/ptt/off' : '/api/ptt/on');
          final st = await _api!.status();
          if (mounted && st != null) setState(() => _rig = st);
        },
        const SingleActivator(LogicalKeyboardKey.keyE): () async {
          if (_tx.running) {
            await _tx.stop();
            await _tx.startMonitor();
          } else {
            await _tx.start(_api!.base, _api!.token ?? '');
          }
          if (mounted) setState(() {});
        },
        const SingleActivator(LogicalKeyboardKey.keyT): () {
          if (!_tuning) {
            _api!.send('/api/tune/tgxl');
            setState(() => _tuning = true);
          }
        },

        // Tuning.
        const SingleActivator(LogicalKeyboardKey.arrowUp): () { _tuneBy(1); },
        const SingleActivator(LogicalKeyboardKey.arrowDown): () { _tuneBy(-1); },
        const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () { _tuneBy(10); },
        const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () { _tuneBy(-10); },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _changeStep(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _changeStep(-1),
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            setState(() => _keypad = !_keypad),

        // Mode.
        const SingleActivator(LogicalKeyboardKey.keyL): () => _api!.send('/api/mode/lsb'),
        const SingleActivator(LogicalKeyboardKey.keyU): () => _api!.send('/api/mode/usb'),
        const SingleActivator(LogicalKeyboardKey.keyC): () => _api!.send('/api/mode/cw'),
        const SingleActivator(LogicalKeyboardKey.keyA): () => _api!.send('/api/mode/am'),
        const SingleActivator(LogicalKeyboardKey.keyD): () => _api!.send('/api/mode/data'),

        // VFO and receiver.
        const SingleActivator(LogicalKeyboardKey.keyV): () => _api!.send('/api/vfo/swap'),
        const SingleActivator(LogicalKeyboardKey.keyS): () => _api!.send('/api/split/toggle'),
        const SingleActivator(LogicalKeyboardKey.keyK): () => _api!.send('/api/toggle/lock'),
        const SingleActivator(LogicalKeyboardKey.keyG): () => _api!.send('/api/agc/cycle'),
        const SingleActivator(LogicalKeyboardKey.keyP): () => _api!.send('/api/preamp/cycle'),
        const SingleActivator(LogicalKeyboardKey.keyN): () => _api!.send('/api/notch/toggle'),
        const SingleActivator(LogicalKeyboardKey.bracketLeft): () => _api!.send('/api/volume/down'),
        const SingleActivator(LogicalKeyboardKey.bracketRight): () => _api!.send('/api/volume/up'),
        const SingleActivator(LogicalKeyboardKey.keyR): () => _api!.send('/api/rit/down'),
        const SingleActivator(LogicalKeyboardKey.keyR, shift: true): () => _api!.send('/api/rit/up'),

        // Bands, in the order they sit on the panel.
        for (final e in <LogicalKeyboardKey, String>{
          LogicalKeyboardKey.digit1: '160', LogicalKeyboardKey.digit2: '80',
          LogicalKeyboardKey.digit3: '60', LogicalKeyboardKey.digit4: '40',
          LogicalKeyboardKey.digit5: '30', LogicalKeyboardKey.digit6: '20',
          LogicalKeyboardKey.digit7: '17', LogicalKeyboardKey.digit8: '15',
          LogicalKeyboardKey.digit9: '12', LogicalKeyboardKey.digit0: '10',
          LogicalKeyboardKey.minus: '6',
        }.entries)
          SingleActivator(e.key): () async {
            await _api!.send('/api/band/${e.value}');
            final st = await _api!.status();
            if (mounted && st != null) setState(() => _rig = st);
          },

        // ⚠️ BOTH SPELLINGS OF "?". Depending on the platform and the keyboard
        // layout, the shifted slash arrives either as slash-with-shift or as
        // its own "question" logical key - and binding only one means the help
        // key silently does nothing on somebody else's keyboard.
        const SingleActivator(LogicalKeyboardKey.slash, shift: true): () =>
            setState(() => _showKeys = !_showKeys),
        const SingleActivator(LogicalKeyboardKey.question): () =>
            setState(() => _showKeys = !_showKeys),
        const SingleActivator(LogicalKeyboardKey.question, shift: true): () =>
            setState(() => _showKeys = !_showKeys),
      };

  Widget _panel() => CallbackShortcuts(
        bindings: _bindings,
        child: Focus(
          focusNode: _keyFocus,
          autofocus: true,
          child: _panelBody(),
        ),
      );
  // ── The shape of the panel ────────────────────────────────────────────
  //
  //   head        band/mode · frequency · power, then ONE meter
  //   surface     OPERATE (three columns) or SETUP
  //   audio       receive and microphone levels, and the recorder
  //   transmit    ARM · PTT · TUNE · ATU, pinned, never behind a scroll
  //
  // ⚠️ EVERY ROW HERE IS A REAL ROW, not a stack of overlays. The previous
  // layout pinned the transmit bar over a scrolling column, and when the bar
  // grew during a tune it sliced the RIT controls in half - the controls were
  // covered at exactly the moment the transmitter was keyed.
  Widget _panelBody() => Stack(children: [
        Column(children: [
          _head(),
          // ⚠️ FILL THE HEIGHT, THEN SCROLL IF IT WILL NOT FIT. Laid out as a
          // plain scroll view the cards hugged their content and left a void
          // above the audio strip - the same wasted space the old full-width
          // rows produced, just moved. minHeight hands the leftover to the
          // cards; the scroll view still takes over on a short window.
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                      child: _surface == 0 ? _operate() : _setup()),
                ),
              );
            }),
          ),
          _audioStrip(),
          _transmitBar(),
        ]),
        if (_showKeys)
          Positioned(
            top: 90,
            right: 20,
            child: KeyMapSheet(onClose: () => setState(() => _showKeys = false)),
          ),
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

  // ── The head ──────────────────────────────────────────────────────────
  Widget _head() {
    final tx = _rig?['tx'] == true;
    final hz = (_rig?['freq'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
          color: T.panelDeep,
          border: Border(
              bottom: BorderSide(
                  color: tx ? T.txRed : T.line, width: tx ? 2 : 1))),
      child: Column(children: [
        Row(children: [
          _tab('OPERATE', 0),
          const SizedBox(width: 6),
          _tab('SETUP', 1),
          const Spacer(),
          _linkPill(),
        ]),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // Band and mode sit left of the readout, the way they do on a rig.
          SizedBox(
            width: 140,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_bandName(hz),
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 24, color: T.text)),
              Text('${_rig?['mode'] ?? '—'}',
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 15, color: T.amber)),
            ]),
          ),
          Expanded(
            child: Column(children: [
              Readout(
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
              const SizedBox(height: 7),
              // ⚠️ Clear of the digits. This line used to sit tight under them
              // and collided with the digit the cursor was marking.
              Text(
                  'scroll or click a digit to tune  ·  ← → step '
                  '${_step >= 1000 ? "${_step ~/ 1000} kHz" : "$_step Hz"}'
                  '  ·  F keypad  ·  ? keys',
                  style: const TextStyle(
                      fontFamily: T.mono, fontSize: 9, color: T.dim)),
            ]),
          ),
          SizedBox(
            width: 140,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              RichText(
                text: TextSpan(children: [
                  TextSpan(
                      text: '${_rig?['power'] ?? '—'}',
                      style: const TextStyle(
                          fontFamily: T.mono, fontSize: 24, color: T.text)),
                  const TextSpan(
                      text: ' W',
                      style: TextStyle(
                          fontFamily: T.mono, fontSize: 13, color: T.dim)),
                ]),
              ),
              Text(
                  'VFO ${_rig?['vfo'] ?? '—'}'
                  '${_rig?['split'] == true ? " · SPLIT" : ""}',
                  style: TextStyle(
                      fontFamily: T.mono,
                      fontSize: 11,
                      color: _rig?['split'] == true ? T.amber : T.dim)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        _meterCard(),
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
      text = 'link $_rttMs ms · jitter $_jitterMs ms';
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(fontFamily: T.mono, fontSize: 10, color: c)),
    ]);
  }

  // ── ONE METER, IN ONE PLACE, WITH TWO ROLES ───────────────────────────
  //
  // ⚠️ RECEIVE SHOWS SIGNAL, TRANSMIT SHOWS THE TRANSMITTER, and they share the
  // same strip of screen. Two meters means an operator checking "am I putting
  // out power" looks at the one that is not live; wfview settled on this and it
  // is right.
  //
  // ⚠️ AND IT CARRIES A SCALE. The bar was drawn with no ticks at all, so a
  // reading could only be judged by the number beside it - which makes the bar
  // decoration. The S-scale is NOT linear: raw 160 is S9 and the top third of
  // the range is the 60 dB above it, so the ticks are placed on the calibrated
  // dB the host derives, never on raw.
  Widget _meterCard() {
    final tx = _rig?['tx'] == true;
    final db = (_meters?['s_meter_db'] as num?)?.toInt();
    final unit = _meters?['s_unit'] as String? ?? '';
    final pwrPct = (_meters?['power_pct'] as num?)?.toDouble() ?? 0;
    final swr = (_meters?['swr_ratio'] as num?)?.toDouble();
    final alc = (_meters?['alc_pct'] as num?)?.toInt();

    final double frac;
    final String heading;
    final String value;
    final Color colour;
    final List<(double, String)> ticks;

    if (tx) {
      heading = 'TRANSMIT';
      frac = (pwrPct / 100).clamp(0.0, 1.0);
      // ⚠️ PERCENT OF RATED OUTPUT, which is what the host actually derives -
      // not watts. Multiplying it out would put a number on screen the radio
      // never reported.
      value = 'PWR ${pwrPct.round()}%'
          '${swr != null ? "   SWR ${swr.toStringAsFixed(1)}" : ""}'
          '${alc != null ? "   ALC $alc%" : ""}';
      colour = T.amber;
      ticks = const [(0.0, '0'), (0.25, '25'), (0.5, '50%'), (0.75, '75'), (1.0, '100')];
    } else {
      heading = 'SIGNAL';
      frac = db == null ? 0 : ((db + 60) / 120.0).clamp(0.0, 1.0);
      // ⚠️ Blank, not "S0", when the host could not read the meter. An S0 that
      // was never measured looks exactly like a dead band.
      value = (_stale || db == null) ? '—' : '$unit   $db dB';
      colour = _stale ? T.amberDim : T.okGreen;
      // ⚠️ THE TICKS SIT WHERE THE dB PUTS THEM. The bar runs -60..+60 dB
      // relative to S9, and each S-unit is 6 dB: S1 is -48 dB, which is a tenth
      // of the way along, NOT the left edge. Ticks drawn at even spacing would
      // make the scale itself a lie, which is worse than no scale.
      ticks = const [
        (0.10, 'S1'), (0.20, '3'), (0.30, '5'), (0.40, '7'),
        (0.50, 'S9'), (0.667, '+20'), (0.833, '+40'), (1.0, '+60'),
      ];
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
      decoration: BoxDecoration(
          color: T.ground,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: tx ? T.txRed : T.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(heading, style: T.silk()),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  fontFamily: T.mono, fontSize: 14, color: colour)),
        ]),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: _stale && !tx ? 0 : frac,
            minHeight: 20,
            backgroundColor: T.panelDeep,
            valueColor: AlwaysStoppedAnimation(colour),
          ),
        ),
        const SizedBox(height: 3),
        SizedBox(height: 12, child: _scale(ticks)),
      ]),
    );
  }

  /// The tick marks under the meter. ⚠️ Inset at both ends, or the first and
  /// last labels are half off the edge of the card.
  Widget _scale(List<(double, String)> ticks) => LayoutBuilder(
        builder: (context, box) {
          const inset = 10.0;
          final span = box.maxWidth - inset * 2;
          return Stack(clipBehavior: Clip.none, children: [
            for (final (frac, label) in ticks)
              Positioned(
                left: inset + span * frac - 14,
                width: 28,
                child: Column(children: [
                  Container(width: 1, height: 3, color: T.line),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontFamily: T.mono, fontSize: 8, color: T.dim)),
                ]),
              ),
          ]);
        },
      );

  // ── OPERATE ───────────────────────────────────────────────────────────
  //
  // ⚠️ COLUMNS, NOT FULL-WIDTH ROWS. Every group used to span the whole window
  // with its buttons crammed to the left, which wasted two thirds of a wide
  // screen and pushed the rest below the fold. The count comes from the width,
  // so the same code is a three-column desk panel and a one-column tablet.
  Widget _operate() => LayoutBuilder(builder: (context, box) {
        final columns = box.maxWidth >= 1150 ? 3 : (box.maxWidth >= 780 ? 2 : 1);
        final a = _colFrequency();
        final b = _colVfo();
        final c = _colReceiver();
        if (columns == 3) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(flex: 135, child: a),
              const SizedBox(width: 10),
              Expanded(flex: 100, child: b),
              const SizedBox(width: 10),
              Expanded(flex: 115, child: c),
            ]),
          );
        }
        if (columns == 2) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: a),
              const SizedBox(width: 10),
              Expanded(child: Column(children: [b, const SizedBox(height: 10), c])),
            ]),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Column(children: [
            a, const SizedBox(height: 10), b, const SizedBox(height: 10), c,
          ]),
        );
      });

  Widget _colFrequency() => _card([
        _group('BAND'),
        _grid(6, [
          for (final b in const ['160', '80', '60', '40', '30', '20',
            '17', '15', '12', '10', '6'])
            _key(b, () => _send('/api/band/$b'),
                on: _bandName((_rig?['freq'] as num?)?.toInt() ?? 0)
                    .replaceAll('M', '') == b),
        ]),
        _group('MODE'),
        _grid(6, [
          for (final m in const ['LSB', 'USB', 'CW', 'AM', 'FM', 'DATA'])
            _key(m, () => _send('/api/mode/${m.toLowerCase()}'),
                on: '${_rig?['mode']}' == m),
        ]),
        _group('FILTER'),
        // ⚠️ No selected state. The host does not report the current filter, and
        // lighting one up would be a guess drawn as a reading.
        _grid(3, [
          _key('NARROW', () => _send('/api/width/narrow'), small: true),
          _key('MED', () => _send('/api/width/medium'), small: true),
          _key('WIDE', () => _send('/api/width/wide'), small: true),
        ]),
      ]);

  Widget _colVfo() => _card([
        _group('VFO'),
        _grid(4, [
          _key('A', () => _send('/api/vfo/a'), on: _rig?['vfo'] == 'A'),
          _key('B', () => _send('/api/vfo/b'), on: _rig?['vfo'] == 'B'),
          _key('SWAP', () => _send('/api/vfo/swap')),
          _key('SPLIT', () => _send('/api/split/toggle'),
              on: _rig?['split'] == true),
          _key('A▸B', () => _send('/api/vfo-copy/a2b'), small: true),
          _key('B▸A', () => _send('/api/vfo-copy/b2a'), small: true),
          _key('QUICK', () => _send('/api/quick-split'), small: true),
          _key('LOCK', () => _send('/api/toggle/lock'),
              small: true, on: _rig?['vfo_locked'] == true),
        ]),
        _group('RIT'),
        _grid(3, [
          _key('−100', () => _send('/api/rit/down'), small: true),
          _key('CLEAR', () => _send('/api/rit/clear'), small: true),
          _key('+100', () => _send('/api/rit/up'), small: true),
        ]),
        // ⚠️ The step the ARROW KEYS move by, shown as a control rather than
        // only as text - an operator who cannot see the hint line still has to
        // know how far the next press goes.
        _group('TUNING STEP'),
        _grid(4, [
          for (final s in const [10, 100, 1000, 10000])
            _key(s >= 1000 ? '${s ~/ 1000} k' : '$s',
                () => setState(() => _step = s),
                small: true, on: _step == s),
        ]),
      ]);

  Widget _colReceiver() => _card([
        _group('RECEIVER'),
        _grid(4, [
          _key('AGC', () => _send('/api/agc/cycle'), small: true),
          _key('PRE', () => _send('/api/preamp/cycle'), small: true),
          _key('ANT', () => _send('/api/ant/toggle'), small: true),
          _key('NOTCH', () => _send('/api/notch/toggle'), small: true),
        ]),
        const SizedBox(height: 2),
        _levelSlider('AF', _af, 255, (v) => _send('/api/volume/set/$v'),
            (v) => setState(() => _af = v)),
        _levelSlider('RF', _rf, 255, (v) => _send('/api/rf-gain/set/$v'),
            (v) => setState(() => _rf = v)),
        _group('TRANSMIT'),
        _levelSlider('PWR', (_rig?['power'] as num?)?.toInt() ?? 0, 100,
            (v) => _send('/api/power/set/$v'),
            (v) => setState(() => _rig = {...?_rig, 'power': v}),
            colour: T.amber),
        _grid(3, [
          _key('MON', () => _send('/api/mon/toggle'), small: true),
          _key('COMP', () => _send('/api/comp/toggle'), small: true),
          _key('MIC…', () => setState(() => _surface = 1), small: true),
        ]),
      ]);

  // ── SETUP: nothing here is touched during a contact ───────────────────
  Widget _setup() => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: Column(children: [
          _card([
            _group('MICROPHONE'),
            _micPicker(),
            const SizedBox(height: 4),
            Text(
                _tx.status.isEmpty ? 'not started' : _tx.status,
                style: const TextStyle(
                    fontFamily: T.mono, fontSize: 10, color: T.dim)),
          ]),
          const SizedBox(height: 10),
          _card([
            _group('THIS STATION'),
            Text(
                'host ${_api?.base ?? "—"}\n'
                'receive ${_rx.status}\n'
                'transmit routing: '
                '${_tx.radioRouting.isEmpty ? "not armed" : _tx.radioRouting}',
                style: const TextStyle(
                    fontFamily: T.mono, fontSize: 11, color: T.dim, height: 1.6)),
          ]),
        ]),
      );

  // ── Audio and the recorder ────────────────────────────────────────────
  //
  // ⚠️ THE LEVELS ARE THE POINT, SO THEY GET ROOM. They were 8 px slivers in a
  // corner - and the level is the ONLY thing that tells a working microphone
  // from a muted one, because a muted mic sends perfectly formed silence at
  // exactly the right rate and every counter reads healthy.
  //
  // ⚠️ The recorder lives here and the microphone CHOOSER lives in SETUP: one
  // is reached during a contact, the other is set once.
  Widget _audioStrip() {
    final recOn = _rec?['recording'] == true;
    final recOK = _rec?['available'] == true;
    final replay = _rec?['replay_seconds'] ?? 0;
    // ⚠️ IT MUST NOT LOOK LIKE A CARD. On a narrow window this sits directly
    // under the last scrolling card, and with the same fill and radius the two
    // merged into one shape - so a strip that never scrolls read as part of the
    // content that does.
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
          color: T.ground,
          border: Border(
              top: BorderSide(color: _sendingSilence ? T.txRed : T.line))),
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth > 820;
        final meters = [
          _bigLevel('RECEIVE', _rx.level, T.cyan,
              _rx.playing ? null : 'not playing'),
          _bigLevel('MICROPHONE', _tx.level,
              _sendingSilence ? T.txRed : T.okGreen,
              _tx.running ? (_sendingSilence ? 'SILENT' : null) : 'not armed'),
        ];
        final keys = [
          _key(recOn ? '■ STOP' : '● RECORD',
              recOK ? () => _send('/api/record/toggle') : null,
              small: true, on: recOn, width: 118),
          const SizedBox(width: 8),
          _key('SAVE LAST ${replay}s',
              recOK ? () => _send('/api/record/replay') : null,
              small: true, width: 150),
        ];
        if (wide) {
          return Row(children: [
            Expanded(child: meters[0]),
            const SizedBox(width: 18),
            Expanded(child: meters[1]),
            const SizedBox(width: 18),
            ...keys,
          ]);
        }
        return Column(children: [
          meters[0],
          const SizedBox(height: 6),
          meters[1],
          const SizedBox(height: 8),
          Row(children: keys),
        ]);
      }),
    );
  }

  Widget _bigLevel(String label, int pct, Color c, String? note) => Row(children: [
        SizedBox(
            width: 92,
            child: Text(label, style: T.silk())),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (pct / 100.0).clamp(0.0, 1.0),
              minHeight: 14,
              backgroundColor: T.ground,
              valueColor: AlwaysStoppedAnimation(c),
            ),
          ),
        ),
        SizedBox(
          width: 74,
          child: Text(note ?? '$pct%',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontFamily: T.mono,
                  fontSize: 11,
                  color: note == 'SILENT' ? T.txRed : (note == null ? c : T.dim))),
        ),
      ]);

  // ── The transmit bar ──────────────────────────────────────────────────
  //
  // ⚠️ NOTHING HERE LOOKS LIKE ANYTHING ABOVE IT. ARM puts the operator's
  // microphone on the air and used to be the same dark rounded rectangle as
  // VOL+; in a wall of identical keys the one that matters is the one you hunt
  // for. ARM states what it has done, PTT dominates, and each tuner names the
  // box it keys and at what power.
  Widget _transmitBar() {
    final tx = _rig?['tx'] == true;
    final armed = _tx.running;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 8),
      decoration: BoxDecoration(
          color: T.panelDeep,
          border: Border(
              top: BorderSide(color: tx ? T.txRed : T.line, width: 2))),
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth > 900;
        final medium = box.maxWidth > 640;
        return Column(children: [
          if (_sendingSilence) ...[
            _silenceAlarm(),
            const SizedBox(height: 6),
          ],
          SizedBox(
            height: 56,
            child: Row(children: [
              _stackedButton(
                width: 118,
                title: armed ? 'ARMED' : 'ARM',
                sub: armed ? 'MIC LIVE' : 'MIC OFF AIR',
                on: armed,
                onTap: () async {
                  if (_tx.running) {
                    await _tx.stop();
                    await _tx.startMonitor();
                  } else {
                    await _tx.start(_api!.base, _api!.token ?? '');
                  }
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: tx ? T.txRed : T.panel,
                      foregroundColor: tx ? Colors.white : T.text,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: BorderSide(color: tx ? T.txRed : T.line))),
                  onPressed: () async {
                    await _api!.send(tx ? '/api/ptt/off' : '/api/ptt/on');
                    final st = await _api!.status();
                    if (mounted && st != null) setState(() => _rig = st);
                  },
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(tx ? 'ON AIR' : 'PTT',
                            style: const TextStyle(
                                fontFamily: T.mono,
                                fontSize: 21,
                                letterSpacing: 4)),
                        const SizedBox(width: 12),
                        Text(tx ? 'ESC OR SPACE TO STOP' : 'SPACE',
                            style: TextStyle(
                                fontFamily: T.mono,
                                fontSize: 10,
                                letterSpacing: 1,
                                color: tx ? Colors.white70 : T.dim)),
                      ]),
                ),
              ),
              if (medium) ...[
                const SizedBox(width: 10),
                _stackedButton(
                  width: 132,
                  title: _tuning ? 'TUNING…' : 'TUNE',
                  sub: 'TG-XL · 15 W',
                  amber: _tuning,
                  onTap: _tuning
                      ? null
                      : () async {
                          await _api!.send('/api/tune/tgxl');
                          if (mounted) setState(() => _tuning = true);
                        },
                ),
              ],
              if (wide) ...[
                const SizedBox(width: 8),
                _stackedButton(
                  width: 132,
                  title: 'ATU',
                  sub: 'rig internal',
                  onTap: _tuning ? null : () => _send('/api/tune'),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 5),
          Row(children: [
            Expanded(
              child: Text(
                  armed
                      ? (_tx.radioRouting.isEmpty
                          ? 'armed'
                          : _tx.radioRouting)
                      : 'not armed — the radio is using its own microphone',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: T.mono,
                      fontSize: 10,
                      color: _tx.radioRouting.startsWith('⚠') ? T.txRed : T.dim)),
            ),
            if (_tunerMsg.isNotEmpty)
              Text(_tunerMsg,
                  style: TextStyle(
                      fontFamily: T.mono,
                      fontSize: 10,
                      color: _tuning ? T.amber : T.dim)),
          ]),
        ]);
      }),
    );
  }

  /// A two-line button: what it is, and what it will do to the radio.
  Widget _stackedButton({
    required double width,
    required String title,
    required String sub,
    VoidCallback? onTap,
    bool on = false,
    bool amber = false,
  }) {
    final border = amber ? T.amber : (on ? T.cyan : T.line);
    final fg = amber ? T.amber : (on ? T.cyan : T.text);
    return SizedBox(
      width: width,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
            backgroundColor: on ? T.cyanFill : T.panel,
            foregroundColor: fg,
            side: BorderSide(color: border),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
        onPressed: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(title,
              style: TextStyle(
                  fontFamily: T.mono, fontSize: 13, letterSpacing: 1.4, color: fg)),
          const SizedBox(height: 2),
          Text(sub,
              style: const TextStyle(
                  fontFamily: T.mono, fontSize: 8, color: T.dim, letterSpacing: .6)),
        ]),
      ),
    );
  }

  // ⚠️ SILENCE IS A FAULT AND IT MUST SHOUT. 1098 packets of perfect silence
  // went to the transmitter under a lit ON AIR bar, because "mic 0%" is six
  // quiet characters.
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

  // ── The pieces every card is built from ───────────────────────────────

  Widget _card(List<Widget> children) => Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 11),
        decoration: BoxDecoration(
            color: T.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: T.line)),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _group(String title) => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 7),
        child: Text(title, style: T.silk()),
      );

  /// A grid of equal keys. ⚠️ Equal, so a row of bands reads as one control
  /// rather than as a ragged wrap - which is what the old Wrap produced the
  /// moment a label was one character longer.
  Widget _grid(int columns, List<Widget> keys) {
    final rows = <Widget>[];
    for (var i = 0; i < keys.length; i += columns) {
      final slice = keys.sublist(i, (i + columns).clamp(0, keys.length));
      rows.add(Padding(
        padding: EdgeInsets.only(bottom: i + columns < keys.length ? 6 : 0),
        child: Row(children: [
          for (var c = 0; c < columns; c++) ...[
            if (c > 0) const SizedBox(width: 6),
            Expanded(child: c < slice.length ? slice[c] : const SizedBox()),
          ],
        ]),
      ));
    }
    return Column(children: rows);
  }

  /// ⚠️ A null onTap DISABLES rather than hides. A control that vanishes when a
  /// feature is unavailable leaves the operator wondering where it went.
  Widget _key(String label, VoidCallback? tap,
          {bool on = false, bool small = false, double? width}) =>
      SizedBox(
        width: width,
        height: small ? 38 : 44,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
              backgroundColor: on ? T.cyanFill : T.panelDeep,
              foregroundColor: on ? T.cyan : T.text,
              // ⚠️ A disabled control still has to be legible: greyed means
              // "not available here", blank means "this panel is broken".
              disabledForegroundColor: T.dim,
              side: BorderSide(color: on ? T.cyan : T.line),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
          onPressed: tap,
          child: Text(label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: TextStyle(
                  fontSize: small ? 11 : 12,
                  letterSpacing: .5,
                  color: on ? T.cyan : null)),
        ),
      );

  /// A labelled slider that sends on RELEASE.
  ///
  /// ⚠️ ON RELEASE, NEVER PER FRAME. A slider that fires on every drag frame
  /// puts a hundred CAT writes on a serial port that answers one at a time, and
  /// the radio ends up wherever the queue drained to rather than where the
  /// operator let go.
  Widget _levelSlider(String label, int value, int max,
          Future<void> Function(int) send, void Function(int) local,
          {Color colour = T.cyan}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(children: [
          SizedBox(
            width: 62,
            child: Text('$label $value',
                style: const TextStyle(
                    fontFamily: T.mono, fontSize: 10, color: T.dim)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
              child: Slider(
                value: value.toDouble().clamp(0, max.toDouble()),
                max: max.toDouble(),
                activeColor: colour,
                inactiveColor: T.line,
                onChanged: (v) => local(v.round()),
                onChangeEnd: (v) async {
                  await send(v.round());
                  final st = await _api!.status();
                  if (mounted && st != null) setState(() => _rig = st);
                },
              ),
            ),
          ),
        ]),
      );

  /// Send, then refresh what the radio says. ⚠️ The reading comes from the rig,
  /// never from "the button was pressed".
  Future<void> _send(String path) async {
    await _api!.send(path);
    final st = await _api!.status();
    if (mounted && st != null) setState(() => _rig = st);
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
}

/// Turn what the operator typed into a base URL.
///
/// ⚠️ HTTPS IS IMPLIED. The address of a station is a NAME - `station.example.com` -
/// and that is the whole thing an operator should have to type. This used to
/// demand a scheme and a port and hand back "no reply from ..." when either was
/// missing, which reads as a dead station rather than a typo.
///
/// ⚠️ AND HTTPS EVEN WHEN THE CERTIFICATE IS OUR OWN. A self-signed station is
/// still https; picking http because a certificate might not be from a public
/// CA gets the microphone refused by every browser, because getUserMedia needs
/// a secure context.
///
/// The exceptions, both deliberate:
///   - a scheme typed explicitly wins, so `http://192.168.40.64` still works
///     for a host with no name yet;
///   - a page serving this panel wins over both, because a panel loaded over
///     http must not try to talk https back to the host that sent it.
///
/// A port is a SETTING, not part of the address. One pasted into the host box
/// is moved into it rather than rejected.
String buildStationBase(String typedHost, String typedPort, Uri page) {
  var host = typedHost.trim();
  var port = typedPort.trim();

  if (host.isEmpty && (page.scheme == 'http' || page.scheme == 'https')) {
    return page.origin; // served by the host: it already knows where it is
  }

  var scheme = '';
  for (final s in ['https://', 'http://']) {
    if (host.toLowerCase().startsWith(s)) {
      scheme = s.substring(0, s.length - 3);
      host = host.substring(s.length);
      break;
    }
  }
  host = host.split('/').first; // a pasted path is not part of the address

  // A port pasted into the host box belongs in the port box.
  final colon = host.lastIndexOf(':');
  if (colon > 0 && int.tryParse(host.substring(colon + 1)) != null) {
    if (port.isEmpty) port = host.substring(colon + 1);
    host = host.substring(0, colon);
  }

  if (scheme.isEmpty) {
    // Inherit the page's scheme when there is one, otherwise https.
    scheme = (page.scheme == 'http') ? 'http' : 'https';
  }
  return port.isEmpty ? '$scheme://$host' : '$scheme://$host:$port';
}

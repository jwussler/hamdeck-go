import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
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
  Map<String, dynamic>? _rig;
  String? _error;
  Timer? _poll;
  DateTime? _lastGood;

  @override
  void dispose() {
    _poll?.cancel();
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
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final s = await _api!.status();
      if (!mounted) return;
      setState(() {
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
      const SizedBox(height: 8),
      _keys('MODE', const ['LSB', 'USB', 'CW', 'AM', 'FM', 'DATA'],
          (m) => '/api/mode/$m', selected: '${_rig?['mode']}'),
      const Spacer(),
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
              : 'connected · ${_rig?['s_meter'] ?? 0}/255 raw',
          style: TextStyle(
              color: _stale ? T.amber : T.dim, fontSize: 11, fontFamily: T.mono),
        ),
      ),
    ]);
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

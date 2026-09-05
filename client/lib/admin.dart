import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';

/// The browser surface, and the ONLY thing the web build is.
///
/// ⚠️ THERE IS NO OPERATING HERE, DELIBERATELY. A browser is the wrong place to
/// key a transmitter: the audio path is not the native one, a tab can be
/// backgrounded or throttled by the browser at any moment, and the key that
/// unkeys you may go to the page rather than to the app. The panel that operates
/// the station is the native one, per platform. What a browser IS good for is
/// the thing you need from a phone in a car park: who is logged in, throw them
/// off, lock the station down, and STOP TRANSMITTING NOW.
///
/// ⚠️ EVERY CONTROL ON THIS PAGE IS ONE THE HOST ALREADY ENFORCES. Nothing here
/// is trusted client-side: /api/admin/* refuses a session that is not an admin,
/// so a page served to the wrong person still cannot do anything. The screen is
/// a convenience over routes that were previously only reachable with curl.
class AdminApp extends StatelessWidget {
  const AdminApp({super.key, required this.base});

  /// The host that served this page. Not typed by anybody: an admin page that
  /// asks which station to administer is a page that can be pointed at the
  /// wrong one.
  final String base;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HamDeck Admin',
        debugShowCheckedModeBanner: false,
        // ⚠️ A REAL DARK SCHEME, not just a dark background. The operating
        // panel gets away with a bare ThemeData because every Text there sets
        // its own colour; this page relied on the defaults and rendered the
        // station readings and the account names in near-black on near-black -
        // present, correct, and invisible. Found by screenshotting it.
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: T.ground,
          colorScheme: const ColorScheme.dark(
            surface: T.ground,
            primary: T.cyan,
            onPrimary: Colors.white,
            secondaryContainer: T.cyanFill,
            onSecondaryContainer: T.text,
            error: Color(0xFFE2564D),
          ),
          textTheme: Typography.whiteMountainView,
          inputDecorationTheme: const InputDecorationTheme(
            filled: true,
            fillColor: T.panelDeep,
            border: OutlineInputBorder(borderSide: BorderSide(color: T.line)),
          ),
        ),
        home: AdminHome(base: base),
      );
}

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.base});
  final String base;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  late final Api _api = Api(widget.base);

  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _loginError;
  bool _busy = false;

  bool _in = false;
  String _whoami = '';

  Map<String, dynamic>? _health;
  List<dynamic> _sessions = const [];
  List<dynamic> _users = const [];
  bool _lockdown = false;
  String? _notice;
  bool _noticeBad = false;
  Timer? _refresh;

  @override
  void dispose() {
    _refresh?.cancel();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _loginError = null;
    });
    final err = await _api.login(_user.text.trim(), _pass.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _loginError = err;
      });
      return;
    }
    _whoami = _user.text.trim();
    _pass.clear();
    setState(() {
      _busy = false;
      _in = true;
    });
    await _load();
    // ⚠️ Slow on purpose. This page is a window onto the station, not a
    // dashboard - polling it hard from a phone on a train adds load to a host
    // whose actual job is moving audio.
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  Future<void> _load() async {
    final health = await _api.send('/api/health');
    final s = await _api.send('/api/admin/sessions');
    final u = await _api.send('/api/admin/users');
    final l = await _api.send('/api/admin/lockdown/status');
    if (!mounted) return;
    setState(() {
      _health = health;
      _sessions = (s?['sessions'] as List<dynamic>?) ?? const [];
      _users = (u?['users'] as List<dynamic>?) ?? const [];
      _lockdown = (l?['lockdown'] as bool?) ?? (l?['locked'] as bool?) ?? _lockdown;
      // ⚠️ An admin route answering null means this account is not an admin, or
      // the session is gone. Say so rather than drawing an empty, working-looking
      // page - an empty account list reads as "there are no accounts".
      if (u == null) {
        _notice = 'this account cannot administer the station — '
            'the host refused /api/admin/users';
        _noticeBad = true;
      }
    });
  }

  Future<void> _act(String path, String said) async {
    final r = await _api.send(path);
    if (!mounted) return;
    setState(() {
      _notice = r == null ? 'the host refused: $said' : said;
      _noticeBad = r == null;
    });
    await _load();
  }

  Future<void> _postAct(String path, Map<String, dynamic> body, String said) async {
    final r = await _api.post(path, body);
    if (!mounted) return;
    setState(() {
      _notice = r.ok ? (r.message ?? said) : (r.message ?? 'that did not work');
      _noticeBad = !r.ok;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: SafeArea(child: _in ? _admin() : _loginForm()));

  // ---------------------------------------------------------------- login

  Widget _loginForm() => Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const _Wordmark(sub: 'station admin'),
                const SizedBox(height: 28),
                _label('USERNAME'),
                TextField(controller: _user, autofocus: true),
                const SizedBox(height: 14),
                _label('PASSWORD'),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton(
                    onPressed: _busy ? null : _login,
                    child: Text(_busy ? 'SIGNING IN…' : 'SIGN IN'),
                  ),
                ),
                if (_loginError != null) ...[
                  const SizedBox(height: 14),
                  Text(_loginError!,
                      style: const TextStyle(color: Color(0xFFE2564D), fontSize: 12.5)),
                ],
                const SizedBox(height: 22),
                const Text(
                  'This page administers the station. Operating happens in the '
                  'HamDeck panel on your computer, not in a browser.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: T.dim, fontSize: 12, height: 1.5),
                ),
              ]),
            ),
          ),
        ),
      );

  // ---------------------------------------------------------------- admin

  Widget _admin() => LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 900;
        final left = <Widget>[_stopCard(), const SizedBox(height: 12), _stationCard()];
        final right = <Widget>[_sessionsCard(), const SizedBox(height: 12), _accountsCard()];
        return Column(children: [
          _bar(),
          if (_notice != null) _noticeBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 100, child: Column(children: left)),
                      const SizedBox(width: 12),
                      Expanded(flex: 125, child: Column(children: right)),
                    ])
                  : Column(children: [...left, const SizedBox(height: 12), ...right]),
            ),
          ),
        ]);
      });

  Widget _bar() => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: T.line)),
        ),
        child: Row(children: [
          const _Wordmark(sub: 'station admin', small: true),
          const Spacer(),
          Text('signed in as $_whoami',
              style: const TextStyle(color: T.dim, fontSize: 12)),
          const SizedBox(width: 14),
          TextButton(
            onPressed: () async {
              await _api.send('/api/auth/logout');
              _refresh?.cancel();
              if (mounted) setState(() => _in = false);
            },
            child: const Text('SIGN OUT'),
          ),
        ]),
      );

  Widget _noticeBar() => Container(
        width: double.infinity,
        color: _noticeBad ? const Color(0xFF3A1E1C) : const Color(0xFF15251A),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Expanded(
            child: Text(_notice!,
                style: TextStyle(
                    color: _noticeBad ? const Color(0xFFE2564D) : const Color(0xFF7FD18B),
                    fontSize: 12.5)),
          ),
          IconButton(
            iconSize: 16,
            onPressed: () => setState(() => _notice = null),
            icon: const Icon(Icons.close),
          ),
        ]),
      );

  /// ⚠️ THE ONLY CONTROL ON THIS PAGE THAT TOUCHES THE TRANSMITTER, and it only
  /// ever points one way: off. It is first, and it is big, because the reason
  /// somebody opens this page on a phone is that something is transmitting and
  /// should not be.
  Widget _stopCard() => _card('STOP TRANSMITTING', [
        SizedBox(
          width: double.infinity,
          height: 64,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: T.txRed,
              foregroundColor: Colors.white,
              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2),
            ),
            onPressed: () => _act('/api/admin/unkey', 'unkey sent — the host dropped the transmitter'),
            child: const Text('KILL TRANSMIT'),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Drops the transmitter now, whoever keyed it. It does not stop them '
          'keying again — lock the station down for that.',
          style: TextStyle(color: T.dim, fontSize: 12, height: 1.45),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: Text(
              _lockdown
                  ? 'LOCKED DOWN — nobody but an admin can transmit'
                  : 'not locked down — anyone with transmit permission may key up',
              style: TextStyle(
                  color: _lockdown ? T.amber : T.dim,
                  fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: () => _act(
              _lockdown ? '/api/admin/lockdown/off' : '/api/admin/lockdown/on',
              _lockdown ? 'lockdown lifted' : 'station locked down',
            ),
            child: Text(_lockdown ? 'LIFT LOCKDOWN' : 'LOCK DOWN'),
          ),
        ]),
      ]);

  /// ⚠️ READ ONLY, and it says what it does not know. A dash is not a zero.
  Widget _stationCard() {
    final h = _health;
    return _card('STATION', [
      _row('host', h == null ? '—' : (h['service'] as String? ?? '—')),
      _row('version', h == null ? '—' : (h['version'] as String? ?? '—')),
      _row('rig', h == null ? '—' : (h['rig'] as String? ?? '—')),
      _row(
        'rig connected',
        h == null ? '—' : ((h['rig_connected'] as bool? ?? false) ? 'yes' : 'no'),
      ),
      _row('accounts', _users.isEmpty ? '—' : '${_users.length}'),
      _row('signed in now', '${_sessions.length}'),
      const SizedBox(height: 8),
      const Text(
        'Operating controls are deliberately not on this page.',
        style: TextStyle(color: T.dim, fontSize: 11.5),
      ),
    ]);
  }

  Widget _sessionsCard() => _card('WHO IS SIGNED IN', [
        if (_sessions.isEmpty)
          const Text('nobody', style: TextStyle(color: T.dim, fontSize: 12.5))
        else
          ..._sessions.map((s) {
            final m = s as Map<String, dynamic>;
            final id = m['id'] as String? ?? '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${m['user'] ?? 'unknown'}'
                    '${m['minutes_left'] != null ? '  ·  ${m['minutes_left']} min left' : ''}'
                    '${m['expires'] != null ? '  ·  until ${m['expires']}' : ''}',
                    style: const TextStyle(fontSize: 13, color: T.text),
                  ),
                ),
                OutlinedButton(
                  onPressed: id.isEmpty
                      ? null
                      : () => _act('/api/admin/kick/$id', 'signed out ${m['user']}'),
                  child: const Text('SIGN OUT'),
                ),
              ]),
            );
          }),
      ]);

  Widget _accountsCard() => _card('ACCOUNTS', [
        ..._users.map((u) {
          final m = u as Map<String, dynamic>;
          final name = m['username'] as String? ?? '';
          final p = (m['perms'] as Map<String, dynamic>?) ?? const {};
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(color: T.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: T.text)),
                ),
                TextButton(
                  onPressed: () => _askPassword(name),
                  child: const Text('SET PASSWORD'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFFE2564D)),
                  onPressed: name == _whoami ? null : () => _confirmRemove(name),
                  child: const Text('REMOVE'),
                ),
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 4, children: [
                _perm(name, 'transmit', 'tx', p['can_transmit'] as bool? ?? false),
                _perm(name, 'admin', 'admin', p['is_admin'] as bool? ?? false),
                _perm(name, 'station', 'station', p['is_station'] as bool? ?? false),
              ]),
            ]),
          );
        }),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _askNewAccount,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('ADD ACCOUNT'),
        ),
        const SizedBox(height: 8),
        const Text(
          'A new account may listen but not transmit until you grant it.',
          style: TextStyle(color: T.dim, fontSize: 11.5),
        ),
      ]);

  Widget _perm(String user, String label, String route, bool on) => FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
        selected: on,
        showCheckmark: true,
        onSelected: (want) => _act(
          '/api/admin/user/$route/$user/${want ? 'on' : 'off'}',
          '$user: $label ${want ? 'granted' : 'revoked'}',
        ),
      );

  // ------------------------------------------------------------- dialogs

  Future<void> _askPassword(String name) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Set a password for $name'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: c, obscureText: true, autofocus: true),
          const SizedBox(height: 10),
          const Text(
            'This ends every session that account has open.',
            style: TextStyle(color: T.dim, fontSize: 12),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('SET')),
        ],
      ),
    );
    if (ok == true && c.text.isNotEmpty) {
      await _postAct('/api/admin/user/password', {'username': name, 'password': c.text},
          'password changed for $name');
    }
    c.dispose();
  }

  Future<void> _askNewAccount() async {
    final n = TextEditingController();
    final p = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add an account'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: n, autofocus: true, decoration: const InputDecoration(labelText: 'username')),
          const SizedBox(height: 10),
          TextField(controller: p, obscureText: true, decoration: const InputDecoration(labelText: 'password')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ADD')),
        ],
      ),
    );
    if (ok == true && n.text.trim().isNotEmpty && p.text.isNotEmpty) {
      await _postAct('/api/admin/user/add',
          {'username': n.text.trim(), 'password': p.text}, 'account added');
    }
    n.dispose();
    p.dispose();
  }

  /// ⚠️ Removing an account is not undoable and there is no list of what it
  /// could do. Type the name - a misclick in a list of similar callsigns is
  /// exactly how the wrong one goes.
  Future<void> _confirmRemove(String name) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Type $name to confirm. This cannot be undone.',
              style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 10),
          TextField(controller: c, autofocus: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.txRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('REMOVE'),
          ),
        ],
      ),
    );
    if (ok == true && c.text.trim() == name) {
      await _act('/api/admin/user/remove/$name', 'removed $name');
    } else if (ok == true) {
      setState(() {
        _notice = 'that did not match $name — nothing was removed';
        _noticeBad = true;
      });
    }
    c.dispose();
  }

  // --------------------------------------------------------------- bits

  Widget _card(String title, List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: T.panelDeep,
          border: Border.all(color: T.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 11, letterSpacing: 1.6, color: T.dim)),
          const SizedBox(height: 12),
          ...children,
        ]),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(
            width: 118,
            child: Text(k, style: const TextStyle(color: T.dim, fontSize: 12.5)),
          ),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 12.5, color: T.text))),
        ]),
      );

  static Widget _label(String s) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(s,
              style: const TextStyle(
                  fontSize: 10.5, letterSpacing: 1.4, color: T.dim)),
        ),
      );
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.sub, this.small = false});
  final String sub;
  final bool small;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: small ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          RichText(
            text: TextSpan(
              style: TextStyle(
                fontSize: small ? 18 : 34,
                fontWeight: FontWeight.w800,
                letterSpacing: small ? 1 : 2,
              ),
              children: const [
                TextSpan(text: 'HAM', style: TextStyle(color: Colors.white)),
                TextSpan(text: 'DECK', style: TextStyle(color: T.cyan)),
              ],
            ),
          ),
          Text(sub,
              style: TextStyle(
                  color: T.dim,
                  fontSize: small ? 10.5 : 12.5,
                  letterSpacing: 1.2)),
        ],
      );
}

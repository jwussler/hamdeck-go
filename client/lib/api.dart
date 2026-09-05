import 'dart:convert';
import 'package:http/http.dart' as http;

/// Talking to the host.
///
/// ⚠️ EVERY READING SHOWN COMES FROM HERE, never from what a button did. The C++
/// client learned that the expensive way: a status route that invented a
/// plausible value sent a whole evening's debugging to the wrong end of the
/// chain. If a read fails this returns null and the panel says so.
class Api {
  Api(this.base);
  final String base;
  String? _token;

  bool get loggedIn => _token != null;
  // The audio socket needs the same session: a browser cannot set headers on a
  // WebSocket, so the token goes in the query.
  String? get token => _token;

  Future<String?> login(String user, String pass) async {
    try {
      final r = await http
          .post(Uri.parse('$base/api/auth/login'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'username': user, 'password': pass}))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) {
        // The host's own message, passed through - it distinguishes a bad
        // password from a host that is not answering.
        return jsonDecode(r.body)['message'] as String? ?? 'login failed';
      }
      _token = jsonDecode(r.body)['token'] as String?;
      return null;
    } catch (e) {
      return 'no reply from $base';
    }
  }

  Future<Map<String, dynamic>?> status() async => _get('/api/status');

  Future<Map<String, dynamic>?> send(String path) async => _get(path);

  /// A route that takes a JSON body. The admin surface needs it: adding an
  /// account and resetting a password both carry a password, and a password
  /// must never travel in a URL where it lands in logs and history.
  ///
  /// ⚠️ Returns the host's OWN message on failure rather than null. An admin
  /// screen that says "that did not work" without saying why is the reason the
  /// operator ends up in a terminal.
  Future<({bool ok, String? message, Map<String, dynamic>? body})> post(
      String path, Map<String, dynamic> body) async {
    if (_token == null) return (ok: false, message: 'not logged in', body: null);
    try {
      final r = await http
          .post(Uri.parse('$base$path?token=$_token'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 8));
      final decoded = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return (ok: false, message: decoded['message'] as String? ?? 'failed', body: decoded);
      }
      return (ok: true, message: decoded['message'] as String?, body: decoded);
    } catch (e) {
      return (ok: false, message: 'no reply from $base', body: null);
    }
  }

  Future<Map<String, dynamic>?> _get(String path) async {
    if (_token == null) return null;
    try {
      final r = await http
          .get(Uri.parse('$base$path?token=$_token'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null; // ⚠️ null means "unknown", never a made-up reading
    }
  }
}

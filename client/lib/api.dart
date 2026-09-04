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

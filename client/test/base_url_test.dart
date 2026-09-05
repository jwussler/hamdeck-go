import 'package:flutter_test/flutter_test.dart';
import 'package:hamdeck_panel/main.dart';

/// What an operator types, and what it has to become.
///
/// ⚠️ THE ADDRESS OF A STATION IS A NAME. Typing a bare name has to reach the
/// station, and the panel used to answer "no reply from `http://<name>`"
/// - it defaulted to http, so the request went to port 80, and a working station
/// read as a dead one. A scheme and a port in the box are not the operator's job.
///
/// ⚠️ AND THE DEFAULT MUST BE HTTPS EVEN FOR OUR OWN CERTIFICATE. A self-signed
/// station is still https; choosing http because the certificate is not from a
/// public CA gets the microphone refused outright - getUserMedia needs a secure
/// context - which presents as a broken microphone and is really a URL.
void main() {
  final desktop = Uri.parse('file:///opt/hamdeck-panel/hamdeck_panel');

  test('a bare name becomes https, with no port', () {
    expect(_PanelStateTestHook.build('station.example.com', '', desktop),
        'https://station.example.com');
  });

  test('whitespace is not an address', () {
    expect(_PanelStateTestHook.build('  station.example.com  ', '  ', desktop),
        'https://station.example.com');
  });

  test('the port is a setting, and it is appended when set', () {
    expect(_PanelStateTestHook.build('station.example.com', '5102', desktop),
        'https://station.example.com:5102');
  });

  test('a port pasted into the address box is moved, not rejected', () {
    expect(_PanelStateTestHook.build('station.example.com:5102', '', desktop),
        'https://station.example.com:5102');
  });

  test('an explicitly typed scheme wins - a bare IP host has no certificate', () {
    expect(_PanelStateTestHook.build('http://192.168.40.64', '5102', desktop),
        'http://192.168.40.64:5102');
  });

  test('a pasted URL is accepted whole', () {
    expect(_PanelStateTestHook.build('https://station.example.com/', '', desktop),
        'https://station.example.com');
  });

  // ⚠️ A panel SERVED over http must talk http back to the host that sent it.
  // Forcing https there is the same failure in the other direction.
  test('the page that served the panel wins over the default', () {
    final page = Uri.parse('http://192.168.40.64:5102/');
    expect(_PanelStateTestHook.build('', '', page), 'http://192.168.40.64:5102');
  });

  test('a page served over https keeps https', () {
    final page = Uri.parse('https://station.example.com/');
    expect(_PanelStateTestHook.build('', '', page), 'https://station.example.com');
  });
}

/// buildBase is a static on the panel state; this names it for the test.
class _PanelStateTestHook {
  static String build(String host, String port, Uri page) =>
      buildStationBase(host, port, page);
}

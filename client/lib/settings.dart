import 'package:shared_preferences/shared_preferences.dart';

/// What the panel remembers between launches.
///
/// ⚠️ IT REMEMBERED NOTHING. Both older clients kept the station address, the
/// account, the audio devices and the tuning step; this one asked for all of it
/// again every single launch, which is the kind of thing an operator forgives
/// once and resents on the twentieth day.
///
/// ⚠️ THE PASSWORD IS NOT HERE AND WILL NOT BE. A remote panel that stores the
/// credential for a transmitter turns "somebody used my laptop" into "somebody
/// transmitted on my licence". The username is remembered because it is not a
/// secret and it is the tedious half to retype.
class Settings {
  Settings._(this._p);

  final SharedPreferences _p;

  static Future<Settings> load() async =>
      Settings._(await SharedPreferences.getInstance());

  String get host => _p.getString('host') ?? '';
  set host(String v) => _p.setString('host', v);

  String get port => _p.getString('port') ?? '';
  set port(String v) => _p.setString('port', v);

  String get username => _p.getString('username') ?? '';
  set username(String v) => _p.setString('username', v);

  /// The tuning step the arrow keys move by.
  int get step => _p.getInt('step') ?? 100;
  set step(int v) => _p.setInt('step', v);

  /// Microphone, by NAME. ⚠️ Never by index: indices shift when USB devices come
  /// and go, and an index that moved is how a station ends up transmitting from
  /// the wrong input with every counter looking healthy.
  String get micName => _p.getString('mic_name') ?? '';
  set micName(String v) => _p.setString('mic_name', v);

  /// Speaker, by name, same rule.
  String get speakerName => _p.getString('speaker_name') ?? '';
  set speakerName(String v) => _p.setString('speaker_name', v);

  /// Microphone gain in percent, 100 = unity. Ported from the C++ client.
  int get micGain => _p.getInt('mic_gain') ?? 100;
  set micGain(int v) => _p.setInt('mic_gain', v);

  /// Receive volume in percent, applied in this client, not at the radio.
  int get volume => _p.getInt('volume') ?? 100;
  set volume(int v) => _p.setInt('volume', v);

  /// The system-wide PTT key, by name. "Off" means no global key.
  ///
  /// ⚠️ THE DEFAULT IS OFF ON PURPOSE. Registering a key system-wide TAKES it
  /// from every other application on the machine, and a panel that silently
  /// swallowed F9 the first time it ran would be a bug report about the logger.
  String get pttKey => _p.getString('ptt_key') ?? 'Off';
  set pttKey(String v) => _p.setString('ptt_key', v);

  /// Hold-to-talk when the platform can deliver a key-up, else press-to-toggle.
  bool get pttHold => _p.getBool('ptt_hold') ?? true;
  set pttHold(bool v) => _p.setBool('ptt_hold', v);

  /// Closing the window hides to the tray instead of quitting.
  bool get closeToTray => _p.getBool('close_to_tray') ?? true;
  set closeToTray(bool v) => _p.setBool('close_to_tray', v);
}

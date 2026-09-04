/// The audio path, with one interface and two implementations.
///
/// ⚠️ THE DESKTOP APP IS THE DELIVERABLE, and the first version of this was
/// written on Web Audio - which will not compile for Windows or macOS at all. So
/// the platform code sits behind this interface and is selected at COMPILE time:
/// a native build never sees dart:js_interop, and a web build never sees dart:io.
///
/// Both must exist because the panel is meant to run everywhere the C++ client
/// runs, and the browser is a bonus rather than the product.
import 'audio_native.dart' if (dart.library.js_interop) 'audio_web.dart';

abstract class RxPlayer {
  /// Start playing the receiver. [base] is the http(s) origin of the host.
  Future<void> start(String base, String token);
  Future<void> stop();

  /// ⚠️ The level of what ARRIVED and was played, 0-100. Not what was sent, and
  /// not the host's own measurement - the two can disagree, and the disagreement
  /// is the interesting case: audio that left the radio and never reached the
  /// operator. Nothing else in the panel can tell you that.
  int get level;
  int get packets;
  String get status;

  /// ⚠️ Playing AND silent is the interesting state: the socket is delivering
  /// and the level is zero, which means audio left the radio and arrived as
  /// nothing. A panel that only showed "connected" could not tell you that.
  bool get playing;
}

abstract class TxCapture {
  Future<void> start(String base, String token);
  Future<void> stop();
  bool get running;

  /// ⚠️ The level the MICROPHONE is producing. A muted mic delivers perfectly
  /// formed silence at exactly the right rate and every other counter reads
  /// identically - this is the only one that tells them apart.
  int get level;
  int get packets;
  String get status;

  /// What the RADIO answered about its own routing. On MIC it ignores the codec
  /// completely: it keys, ALC sits at idle, power reads 0, and every counter in
  /// the chain looks healthy.
  String get radioRouting;
}

RxPlayer makeRxPlayer() => createRxPlayer();
TxCapture makeTxCapture() => createTxCapture();

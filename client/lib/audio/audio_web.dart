// The browser implementation, kept only so a web build still compiles.
//
// ⚠️ THE DESKTOP APP IS THE PRODUCT. This file exists because Flutter builds the
// same source for web, and a broken web target would break `flutter build` on a
// machine that happens to try it - not because a browser is where this is meant
// to run.
import 'audio.dart';
import 'audio_web_rx.dart';
import 'audio_web_tx.dart';

RxPlayer createRxPlayer() => WebRx();
TxCapture createTxCapture() => WebTx();

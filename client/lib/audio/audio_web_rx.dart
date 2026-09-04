import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio.dart';

/// Playing the receiver in a browser.
///
/// ⚠️ SCHEDULED, NOT FIRED-AND-FORGOTTEN. Each packet is turned into an
/// AudioBuffer and scheduled to start exactly where the previous one ended. Play
/// each chunk "now" instead and every network jitter becomes an audible click,
/// which sounds like a radio problem and is a playback problem.
///
/// ⚠️ AND THE FORMAT COMES FROM THE HOST, never assumed. The first message on
/// the socket is JSON naming the rate; a player that guesses 48000 for a 22050
/// stream sounds like a chipmunk and looks like a fault at the radio.
class WebRx implements RxPlayer {
  web.AudioContext? _ctx;
  web.WebSocket? _sock;
  double _playhead = 0;
  int _rate = 22050;
  int _channels = 1;

  /// The level of what actually ARRIVED and was played, 0-100, decaying.
  /// This is the client's own measurement - not the host's - so the two can
  /// disagree, and a disagreement is the interesting case: it means the audio
  /// left the radio and did not reach the operator.
  @override
  int level = 0;
  DateTime _levelAt = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  int packets = 0;
  @override
  String status = 'not started';

  @override
  bool get playing => _sock != null && status == 'playing';

  @override
  Future<void> start(String base, String token) async {
    stop();
    final wsBase = base.replaceFirst('http', 'ws');
    // ⚠️ The token is a query parameter because a browser cannot set headers on
    // a WebSocket. It is the same session the REST calls use, and the host logs
    // paths without query strings so it does not end up in a log file.
    final url = '$wsBase/ws?token=$token';
    status = 'connecting';
    final ctx = web.AudioContext();
    _ctx = ctx;
    final s = web.WebSocket(url);
    s.binaryType = 'arraybuffer';
    _sock = s;

    s.onopen = ((web.Event _) {
      status = 'connected, waiting for the format';
    }).toJS;

    s.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data.isA<JSString>()) {
        // The format line, first.
        final m = jsonDecode((data as JSString).toDart) as Map<String, dynamic>;
        _rate = (m['rate'] as num?)?.toInt() ?? 22050;
        _channels = (m['channels'] as num?)?.toInt() ?? 1;
        status = 'playing';
        _playhead = 0;
        return;
      }
      final bytes = (data as JSArrayBuffer).toDart.asUint8List();
      _play(bytes);
    }).toJS;

    s.onclose = ((web.CloseEvent _) {
      status = 'the host closed the audio socket';
      _sock = null;
    }).toJS;
    s.onerror = ((web.Event _) {
      status = 'audio socket failed';
    }).toJS;
  }

  void _play(Uint8List bytes) {
    final ctx = _ctx;
    if (ctx == null) return;

    final frames = bytes.lengthInBytes ~/ 2 ~/ _channels;
    if (frames == 0) return;
    final view = ByteData.sublistView(bytes);

    final buffer = ctx.createBuffer(_channels, frames, _rate.toDouble());
    var peak = 0;
    for (var c = 0; c < _channels; c++) {
      final chan = Float32List(frames);
      for (var i = 0; i < frames; i++) {
        // little-endian s16, interleaved
        final s = view.getInt16((i * _channels + c) * 2, Endian.little);
        final a = s.abs();
        if (a > peak) peak = a;
        chan[i] = s / 32768.0;
      }
      buffer.copyToChannel(chan.toJS, c);
    }

    final src = ctx.createBufferSource();
    src.buffer = buffer;
    src.connect(ctx.destination);

    // ⚠️ Keep a small cushion ahead of the clock. Scheduling into the past makes
    // the browser play the packet immediately, which is exactly the click this
    // scheduling exists to avoid.
    final now = ctx.currentTime.toDouble();
    if (_playhead < now + 0.02) _playhead = now + 0.08;
    src.start(_playhead);
    _playhead += frames / _rate;

    packets++;
    final pct = (peak * 100 / 32767).round();
    if (pct >= level || DateTime.now().difference(_levelAt).inMilliseconds > 1200) {
      level = pct;
      _levelAt = DateTime.now();
    }
  }

  @override
  Future<void> stop() async {
    _sock?.close();
    _sock = null;
    _ctx?.close();
    _ctx = null;
    status = 'stopped';
    level = 0;
    packets = 0;
  }
}

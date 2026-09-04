import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio.dart';

/// Capturing the operator's microphone and sending it to the radio.
///
/// ⚠️ THE BROWSER WILL NOT GIVE YOU A MICROPHONE ON AN INSECURE PAGE. getUserMedia
/// is refused outright unless the page is https (or localhost), and the refusal
/// looks like a broken microphone rather than a URL problem. That is why the host
/// is served under a real hostname with a real certificate.
///
/// ⚠️ AND THE RATE COMES FROM THE HOST. On this station's codec, capture
/// negotiated 22050 and playback insisted on 44100 - a client that reused the
/// receive rate for transmit would put the operator's voice on the air at half
/// speed: transmitting fine, metering fine, and unintelligible to everyone except
/// the operator. The AudioContext is CREATED at the host's rate so the browser
/// does the resampling itself rather than us doing it badly.
class WebTx implements TxCapture {
  // The browser does not hand out a device list without a permission prompt and
  // the web build is a bonus, not the product - the desktop app is where the
  // operator picks a microphone.
  @override
  MicDevice? device;

  @override
  Future<List<MicDevice>> devices() async => const [];

  @override
  bool get monitoring => false;

  @override
  Future<void> startMonitor() async {}

  @override
  Future<void> stopMonitor() async {}

  web.AudioContext? _ctx;
  web.WebSocket? _sock;
  web.MediaStream? _stream;
  web.ScriptProcessorNode? _node;

  int _rate = 44100;
  int _channels = 1;

  /// What the microphone is actually producing, 0-100.
  ///
  /// ⚠️ THIS IS THE READING THAT SEPARATES A LIVE MICROPHONE FROM A MUTED ONE.
  /// A muted mic delivers perfectly formed silence at exactly the right rate, and
  /// every counter - frames sent, queue depth, sample rate - reads identically.
  @override
  int level = 0;
  @override
  int packets = 0;
  @override
  String status = 'off';
  @override
  String radioRouting = '';

  @override
  bool get running => _sock != null;

  @override
  Future<void> start(String base, String token) async {
    await stop();
    status = 'asking for the microphone';
    try {
      final md = web.window.navigator.mediaDevices;
      // ⚠️ Echo cancellation and noise suppression OFF. They are tuned for speech
      // on a phone call and they will chew a voice destined for an SSB
      // transmitter - and automatic gain fights the rig's own ALC, which is what
      // actually sets transmit level.
      final constraints = web.MediaStreamConstraints(
        audio: {
          'echoCancellation': false,
          'noiseSuppression': false,
          'autoGainControl': false,
        }.jsify()!,
      );
      _stream = await md.getUserMedia(constraints).toDart;
    } catch (e) {
      status = 'the browser refused the microphone: $e';
      return;
    }

    final wsBase = base.replaceFirst('http', 'ws');
    final s = web.WebSocket('$wsBase/ws/tx?token=$token');
    s.binaryType = 'arraybuffer';
    _sock = s;

    s.onmessage = ((web.MessageEvent e) {
      final d = e.data;
      if (!d.isA<JSString>()) return;
      final m = jsonDecode((d as JSString).toDart) as Map<String, dynamic>;
      if (m.containsKey('rate')) {
        _rate = (m['rate'] as num).toInt();
        _channels = (m['channels'] as num?)?.toInt() ?? 1;
        _begin();
        return;
      }
      if (m.containsKey('mod_source_rear')) {
        // ⚠️ What the RADIO answered about its own routing. On MIC it ignores
        // the codec completely: it keys, ALC sits at idle, power reads 0, and
        // every counter looks healthy.
        final rear = m['mod_source_rear'] == true;
        final usb = m['rear_select_usb'] == true;
        radioRouting = (rear && usb)
            ? 'radio on REAR/USB'
            : '⚠ THE RADIO IS NOT ON REAR/USB — it will key and put out nothing';
      }
    }).toJS;

    s.onclose = ((web.CloseEvent _) {
      status = 'the transmit socket closed';
      _sock = null;
    }).toJS;
  }

  void _begin() {
    // The context is created AT THE HOST'S RATE; the browser resamples the
    // microphone into it.
    final ctx = web.AudioContext(web.AudioContextOptions(sampleRate: _rate.toDouble()));
    _ctx = ctx;
    final src = ctx.createMediaStreamSource(_stream!);

    // ⚠️ ScriptProcessorNode is deprecated in favour of AudioWorklet, and it is
    // used here deliberately: an AudioWorklet needs a separate JS module served
    // alongside the app, which is a second deployable artefact for an experiment.
    // If this becomes the real client, that is the upgrade.
    final node = ctx.createScriptProcessor(2048, _channels, _channels);
    _node = node;

    node.onaudioprocess = ((web.AudioProcessingEvent e) {
      final sock = _sock;
      if (sock == null || sock.readyState != web.WebSocket.OPEN) return;
      final input = e.inputBuffer;
      final frames = input.length;
      final out = ByteData(frames * _channels * 2);
      var peak = 0;
      for (var c = 0; c < _channels; c++) {
        final chan = input.getChannelData(c).toDart;
        for (var i = 0; i < frames; i++) {
          var v = (chan[i] * 32767).round();
          if (v > 32767) v = 32767;
          if (v < -32768) v = -32768;
          final a = v.abs();
          if (a > peak) peak = a;
          out.setInt16((i * _channels + c) * 2, v, Endian.little);
        }
      }
      sock.send(out.buffer.toJS);
      packets++;
      level = (peak * 100 / 32767).round();
    }).toJS;

    src.connect(node);
    // ⚠️ A ScriptProcessor does not run unless it is connected to something.
    // Connecting it to the destination would play the operator's own voice back
    // at them; a zero-gain node keeps it running and silent.
    final mute = ctx.createGain();
    mute.gain.value = 0;
    node.connect(mute);
    mute.connect(ctx.destination);

    status = 'transmitting audio';
  }

  @override
  Future<void> stop() async {
    _node?.disconnect();
    _node = null;
    _sock?.close();
    _sock = null;
    await _ctx?.close().toDart;
    _ctx = null;
    _stream?.getTracks().toDart.forEach((t) => t.stop());
    _stream = null;
    status = 'off';
    level = 0;
    packets = 0;
    radioRouting = '';
  }
}

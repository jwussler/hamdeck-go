import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'audio.dart';

RxPlayer createRxPlayer() => _NativeRx();
TxCapture createTxCapture() => _NativeTx();

/// Receive audio on Windows, macOS and Linux.
///
/// ⚠️ THE FORMAT COMES FROM THE HOST, never assumed. The first message on the
/// socket names the rate; a player that guesses 48000 for a 22050 stream sounds
/// like a chipmunk and looks like a fault at the radio.
///
/// ⚠️ The engine is SoLoud (miniaudio underneath), NOT flutter_pcm_sound. That
/// package builds for android, ios and macos only: on Windows - which is the
/// station's main desktop - and on Linux it throws MissingPluginException at
/// the first setup() call. The socket still connects and the host still counts
/// a listener, so the fault reads as "connecting, 0 packets" and looks like a
/// network problem at the host end. It is not. Check a package's platform list
/// before believing it covers the desktop.
class _NativeRx implements RxPlayer {
  final SoLoud _engine = SoLoud.instance;
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  AudioSource? _src;
  SoundHandle? _handle;
  bool _setup = false;
  int _rate = 22050;

  @override
  int level = 0;
  @override
  int packets = 0;
  @override
  String status = 'off';
  @override
  bool get playing => _setup && _ch != null;

  int _volume = 100;
  String? _wantDevice;
  bool _keyed = false;

  @override
  set keyed(bool on) {
    _keyed = on;
    final h = _handle;
    if (h != null) {
      try {
        _engine.setVolume(h, on ? 0 : _volume / 100.0);
      } catch (_) {}
    }
    if (!on) level = 0;
  }

  @override
  int get volume => _volume;

  @override
  set volume(int percent) {
    _volume = percent.clamp(0, 150);
    final src = _src;
    if (src != null) {
      // SoLoud takes a linear gain; 100% is unity.
      final h = _handle;
      if (h != null) {
        try {
          _engine.setVolume(h, _volume / 100.0);
        } catch (_) {}
      }
    }
  }

  @override
  Future<List<OutDevice>> outputs() async {
    try {
      return [
        for (final d in _engine.listPlaybackDevices())
          OutDevice(d.name, d.name + (d.isDefault ? '  (default)' : '')),
      ];
    } catch (e) {
      // ⚠️ An empty list is a real answer - a machine can have one device - so it
      // must not be confused with a failure to ask.
      status = 'could not list speakers: $e';
      return const [];
    }
  }

  @override
  Future<void> useOutput(String? name) async {
    _wantDevice = name;
    if (!_engine.isInitialized) return;
    try {
      final devices = _engine.listPlaybackDevices();
      final match = name == null || name.isEmpty
          ? null
          : devices.where((d) => d.name == name).firstOrNull;
      await _engine.changeDevice(newDevice: match);
    } catch (e) {
      status = 'could not switch speaker: $e';
    }
  }

  DateTime _levelAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<void> start(String base, String token) async {
    await stop();
    final url = Uri.parse('${base.replaceFirst('http', 'ws')}/ws?token=$token');
    status = 'connecting';
    try {
      final ch = WebSocketChannel.connect(url);
      _ch = ch;
      _sub = ch.stream.listen(_onMessage, onError: (e) {
        status = 'audio socket failed: $e';
      }, onDone: () {
        status = 'the host closed the audio socket';
      });
    } catch (e) {
      status = 'could not open the audio socket: $e';
    }
  }

  Future<void> _onMessage(dynamic msg) async {
    if (msg is String) {
      final m = jsonDecode(msg) as Map<String, dynamic>;
      _rate = (m['rate'] as num?)?.toInt() ?? 22050;
      final channels =
          (m['channels'] as num?)?.toInt() == 2 ? Channels.stereo : Channels.mono;
      try {
        if (!_engine.isInitialized) {
          // A small device buffer: this is a live conversation, not playback of
          // a file, and every frame of device buffer is delay on top of the
          // network's own.
          await _engine.init(bufferSize: 512);
        }
        // ⚠️ released, not preserved. A radio stream never ends, so a buffer
        // that keeps what it has already played grows until it hits
        // maxBufferSize and then REFUSES new audio - receive would run for a
        // few minutes and go silent with the socket still healthy.
        final src = _engine.setBufferStream(
          maxBufferSizeDuration: const Duration(seconds: 10),
          bufferingType: BufferingType.released,
          // ⚠️ 150 ms, not 300. Every millisecond here is added to the host's
          // own 371 ms chunk, and the total is how late the operator hears the
          // person they are about to answer. Enough to ride out a hiccup on a
          // LAN; a link that needs more than this needs to say so rather than
          // be padded for silently.
          bufferingTimeNeeds: 0.15,
          sampleRate: _rate,
          channels: channels,
          format: BufferType.s16le,
        );
        _src = src;
        _handle = _engine.play(src, volume: _volume / 100.0);
        if (_wantDevice != null && _wantDevice!.isNotEmpty) {
          await useOutput(_wantDevice);
        }
        _setup = true;
        status = 'playing';
      } catch (e) {
        // ⚠️ Say what failed. "connecting" forever sent the last search to the
        // host end of a link that was working perfectly.
        status = 'no audio output on this machine: $e';
      }
      return;
    }
    final src = _src;
    if (!_setup || src == null || msg is! List<int>) return;
    // ⚠️ DROPPED, NOT QUEUED. See RxPlayer.keyed: queueing an over's worth of
    // receive audio means hearing it played back on unkey, and every
    // transmission adds to the lag for the rest of the session.
    if (_keyed) {
      packets++;
      return;
    }
    final bytes = msg is Uint8List ? msg : Uint8List.fromList(msg);
    final view = ByteData.sublistView(bytes);
    var peak = 0;
    for (var i = 0; i + 1 < bytes.lengthInBytes; i += 2) {
      final a = view.getInt16(i, Endian.little).abs();
      if (a > peak) peak = a;
    }
    try {
      _engine.addAudioDataStream(src, bytes);
    } catch (e) {
      status = 'audio output rejected a packet: $e';
      return;
    }
    packets++;
    final pct = (peak * 100 / 32767).round();
    if (pct >= level || DateTime.now().difference(_levelAt).inMilliseconds > 1200) {
      level = pct;
      _levelAt = DateTime.now();
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _ch?.sink.close();
    _ch = null;
    final src = _src;
    if (src != null) {
      try {
        _engine.setDataIsEnded(src);
        await _engine.disposeSource(src);
      } catch (_) {}
      _src = null;
    }
    _setup = false;
    status = 'off';
    level = 0;
    packets = 0;
  }
}

/// Transmit audio on Windows, macOS and Linux.
class _NativeTx implements TxCapture {
  final _rec = AudioRecorder();

  @override
  MicDevice? device;

  int _gain = 100;

  @override
  int get gain => _gain;

  @override
  set gain(int percent) => _gain = percent.clamp(0, 300);

  /// Apply the gain to one packet of s16le.
  ///
  /// ⚠️ CLIPPED, NOT WRAPPED. Sixteen-bit samples that overflow wrap from a loud
  /// peak to a loud peak of the OPPOSITE sign, which is not distortion, it is a
  /// buzz - and on an SSB transmitter it is a splatter complaint from three
  /// channels away.
  Uint8List _applyGain(Uint8List pcm) {
    if (_gain == 100) return pcm;
    final out = Uint8List.fromList(pcm);
    final view = ByteData.sublistView(out);
    final g = _gain / 100.0;
    for (var i = 0; i + 1 < out.lengthInBytes; i += 2) {
      var v = (view.getInt16(i, Endian.little) * g).round();
      if (v > 32767) v = 32767;
      if (v < -32768) v = -32768;
      view.setInt16(i, v, Endian.little);
    }
    return out;
  }

  StreamSubscription? _mon;

  @override
  bool get monitoring => _mon != null;

  @override
  Future<void> startMonitor() async {
    if (_mon != null || _ch != null) return;
    if (!await _rec.hasPermission()) {
      status = 'the system refused the microphone';
      return;
    }
    final chosen = device;
    try {
      // 44100 mono is only a metering rate - nothing here is transmitted, so it
      // does not have to match the host.
      final stream = await _rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
        device:
            chosen == null ? null : InputDevice(id: chosen.id, label: chosen.label),
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ));
      status = 'listening to the microphone (nothing is being sent)';
      _mon = stream.listen((raw) {
        final chunk = _applyGain(raw);
        final view = ByteData.sublistView(chunk);
        var peak = 0;
        for (var i = 0; i + 1 < chunk.lengthInBytes; i += 2) {
          final a = view.getInt16(i, Endian.little).abs();
          if (a > peak) peak = a;
        }
        level = (peak * 100 / 32767).round();
      });
    } catch (e) {
      status = 'could not open that microphone: $e';
    }
  }

  @override
  Future<void> stopMonitor() async {
    await _mon?.cancel();
    _mon = null;
    if (await _rec.isRecording()) await _rec.stop();
    level = 0;
  }

  @override
  Future<List<MicDevice>> devices() async {
    try {
      final list = await _rec.listInputDevices();
      return [for (final d in list) MicDevice(d.id, d.label)];
    } catch (e) {
      // ⚠️ An empty list is a real answer here - a machine can genuinely have no
      // input - so it must not be confused with a failure to ask.
      status = 'could not list microphones: $e';
      return const [];
    }
  }

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  StreamSubscription? _mic;

  @override
  int level = 0;
  @override
  int packets = 0;
  @override
  String status = 'off';
  @override
  String radioRouting = '';
  @override
  bool get running => _ch != null;

  @override
  Future<void> start(String base, String token) async {
    await stop();
    // ⚠️ The monitor holds the same input device. Leaving it open makes the
    // transmit capture fail to start on Windows with a device-busy error that
    // reads like a broken microphone.
    await stopMonitor();
    // ⚠️ Ask BEFORE opening anything. A denied microphone must be a message, not
    // an armed transmitter with nothing to say.
    if (!await _rec.hasPermission()) {
      status = 'the system refused the microphone';
      return;
    }
    final url = Uri.parse('${base.replaceFirst('http', 'ws')}/ws/tx?token=$token');
    final ch = WebSocketChannel.connect(url);
    _ch = ch;
    status = 'waiting for the host to name a format';
    _sub = ch.stream.listen((msg) async {
      if (msg is! String) return;
      final m = jsonDecode(msg) as Map<String, dynamic>;
      if (m.containsKey('rate')) {
        await _beginMic(ch, (m['rate'] as num).toInt(),
            (m['channels'] as num?)?.toInt() ?? 1);
        return;
      }
      if (m.containsKey('mod_source_rear')) {
        final rear = m['mod_source_rear'] == true;
        final usb = m['rear_select_usb'] == true;
        radioRouting = (rear && usb)
            ? 'radio on REAR/USB'
            : '⚠ THE RADIO IS NOT ON REAR/USB — it will key and put out nothing';
      }
    }, onDone: () {
      status = 'the transmit socket closed';
      _ch = null;
    });
  }

  Future<void> _beginMic(WebSocketChannel ch, int rate, int channels) async {
    // ⚠️ RAW PCM AT THE HOST'S RATE. Capture and playback on this station's codec
    // negotiated different rates (22050 in, 44100 out), so reusing the receive
    // rate here would put the operator's voice on the air at half speed:
    // transmitting fine, metering fine, unintelligible to everyone else.
    //
    // ⚠️ And no echo cancellation, noise suppression or automatic gain: they are
    // tuned for phone calls, they chew a voice bound for an SSB transmitter, and
    // an automatic gain fights the rig's own ALC, which is what actually sets
    // transmit level.
    final chosen = device;
    final stream = await _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: rate,
      numChannels: channels,
      device: chosen == null ? null : InputDevice(id: chosen.id, label: chosen.label),
      echoCancel: false,
      noiseSuppress: false,
      autoGain: false,
    ));
    status = chosen == null
        ? 'transmitting from the system default microphone'
        : 'transmitting from ${chosen.label}';
    _mic = stream.listen((raw) {
      // ⚠️ Gain FIRST, then meter: the level the operator is shown has to be the
      // level that reached the radio, not the one before the knob.
      final chunk = _applyGain(raw);
      final view = ByteData.sublistView(chunk);
      var peak = 0;
      for (var i = 0; i + 1 < chunk.lengthInBytes; i += 2) {
        final a = view.getInt16(i, Endian.little).abs();
        if (a > peak) peak = a;
      }
      ch.sink.add(chunk);
      packets++;
      level = (peak * 100 / 32767).round();
    });
  }

  @override
  Future<void> stop() async {
    await _mic?.cancel();
    _mic = null;
    if (await _rec.isRecording()) await _rec.stop();
    await _sub?.cancel();
    _sub = null;
    await _ch?.sink.close();
    _ch = null;
    status = 'off';
    level = 0;
    packets = 0;
    radioRouting = '';
  }
}

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:six_pages_voice/six_pages_voice.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: CaptureTestPage());
  }
}

class CaptureTestPage extends StatefulWidget {
  const CaptureTestPage({super.key});

  @override
  State<CaptureTestPage> createState() => _CaptureTestPageState();
}

class _CaptureTestPageState extends State<CaptureTestPage> {
  final _voice = SixPagesVoice();

  // Direct channel for the TEST-ONLY loud playback (not in the public contract).
  static const _control = MethodChannel('six_pages_voice/control');

  String _status = 'Idle';
  bool _running = false;
  double _rms = 0.0;
  double _peakRms = 0.0;
  int _frameCount = 0;
  int _totalBytes = 0;

  Stream<Uint8List>? _stream;
  StreamSubscription<Uint8List>? _sub;

  Future<void> _start() async {
    setState(() => _status = 'Requesting mic permission...');
    final perm = await Permission.microphone.request();
    if (!perm.isGranted) {
      setState(() => _status = 'Mic permission DENIED');
      return;
    }

    setState(() => _status = 'Starting engine...');
    final ok = await _voice.start();
    if (!ok) {
      setState(() => _status = 'start() returned false — engine did NOT open');
      return;
    }

    _frameCount = 0;
    _totalBytes = 0;
    _peakRms = 0.0;

    _stream = _voice.captureStream;
    _sub = _stream!.listen(
      (frame) {
        final rms = _computeRms(frame);
        setState(() {
          _rms = rms;
          if (rms > _peakRms) _peakRms = rms;
          _frameCount++;
          _totalBytes += frame.length;
          _status = 'Running';
        });
      },
      onError: (e) {
        setState(() => _status = 'Stream error: $e');
      },
    );

    setState(() {
      _running = true;
      _status = 'Running';
    });
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    await _voice.stop();
    setState(() {
      _running = false;
      _status = 'Stopped';
      _rms = 0.0;
    });
  }

  void _resetPeak() {
    setState(() => _peakRms = 0.0);
  }

  Uint8List _makeTone() {
    const freq = 440.0;
    const durationSeconds = 1.0;
    const amplitude = 0.9;
    final sampleCount = (16000 * durationSeconds).toInt();
    final bytes = Uint8List(sampleCount * 2);
    final data = ByteData.sublistView(bytes);
    for (int i = 0; i < sampleCount; i++) {
      final t = i / 16000.0;
      final sample = (sin(2 * pi * freq * t) * amplitude * 32767).toInt();
      data.setInt16(i * 2, sample, Endian.little);
    }
    return bytes;
  }

  // Comms path (the real path Joe will use).
  Future<void> _playToneComms() async {
    if (!_running) {
      setState(() => _status = 'Press Start first');
      return;
    }
    final bytes = _makeTone();
    const chunkBytes = 640;
    for (int offset = 0; offset < bytes.length; offset += chunkBytes) {
      final end = min(offset + chunkBytes, bytes.length);
      await _voice.feedPlayback(Uint8List.sublistView(bytes, offset, end));
    }
    setState(() => _status = 'Comms tone fed');
  }

  // LOUD media path — TEST BASELINE ONLY. Should make the mic hear it.
  Future<void> _playToneLoud() async {
    if (!_running) {
      setState(() => _status = 'Press Start first');
      return;
    }
    final bytes = _makeTone();
    const chunkBytes = 640;
    for (int offset = 0; offset < bytes.length; offset += chunkBytes) {
      final end = min(offset + chunkBytes, bytes.length);
      await _control.invokeMethod<void>(
        'feedPlaybackLoud',
        Uint8List.sublistView(bytes, offset, end),
      );
    }
    setState(() => _status = 'LOUD tone fed');
  }

  double _computeRms(Uint8List frame) {
    if (frame.length < 2) return 0.0;
    final data = ByteData.sublistView(frame);
    final sampleCount = frame.length ~/ 2;
    double sumSquares = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little);
      final norm = sample / 32768.0;
      sumSquares += norm * norm;
    }
    return sqrt(sumSquares / sampleCount);
  }

  @override
  Widget build(BuildContext context) {
    final rmsPct = (_rms * 100).clamp(0, 100).toDouble();
    return Scaffold(
      appBar: AppBar(title: const Text('Six Pages Voice — Baseline Echo Test')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Status: $_status', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            const Text('RMS energy:', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            Text(
              _rms.toStringAsFixed(4),
              style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: rmsPct / 100.0, minHeight: 16),
            const SizedBox(height: 16),
            Text('PEAK RMS this run: ${_peakRms.toStringAsFixed(4)}',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            Text('Frames: $_frameCount   Bytes: $_totalBytes',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _running ? _resetPeak : null,
              child: const Text('Reset Peak'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _running ? _playToneLoud : null,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Play LOUD tone (baseline — mic should hear it)'),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _running ? _playToneComms : null,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Play tone (comms path)'),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _running ? null : _start,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Start'),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _running ? _stop : null,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Stop'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

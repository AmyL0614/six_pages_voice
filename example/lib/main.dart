import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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

  String _status = 'Idle';
  bool _running = false;
  double _rms = 0.0;
  double _peakRms = 0.0;
  int _frameCount = 0;
  int _totalBytes = 0;

  Stream<Uint8List>? _stream;
  // Keep a reference so we can cancel on stop.
  StreamSubscription<Uint8List>? _sub;

  Future<void> _start() async {
    setState(() => _status = 'Requesting mic permission...');
    final perm = await Permission.microphone.request();
    if (!perm.isGranted) {
      setState(() => _status = 'Mic permission DENIED');
      return;
    }

    setState(() => _status = 'Starting capture...');
    final ok = await _voice.start();
    if (!ok) {
      setState(() => _status = 'start() returned false — capture did NOT open');
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
          _status = 'Capturing';
        });
      },
      onError: (e) {
        setState(() => _status = 'Stream error: $e');
      },
    );

    setState(() {
      _running = true;
      _status = 'Capturing';
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

  // RMS energy of a PCM16 little-endian frame, normalized to 0..1.
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
      appBar: AppBar(title: const Text('Six Pages Voice — Capture Test')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Status: $_status', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            const Text('RMS energy (speak to see it jump):',
                style: TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            Text(
              _rms.toStringAsFixed(4),
              style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: rmsPct / 100.0, minHeight: 16),
            const SizedBox(height: 24),
            Text('Peak RMS this run: ${_peakRms.toStringAsFixed(4)}',
                style: const TextStyle(fontSize: 14)),
            Text('Frames received: $_frameCount',
                style: const TextStyle(fontSize: 14)),
            Text('Total bytes: $_totalBytes',
                style: const TextStyle(fontSize: 14)),
            const Spacer(),
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

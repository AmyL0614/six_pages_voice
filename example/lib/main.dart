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
    return const MaterialApp(home: VoiceDemoPage());
  }
}

class VoiceDemoPage extends StatefulWidget {
  const VoiceDemoPage({super.key});

  @override
  State<VoiceDemoPage> createState() => _VoiceDemoPageState();
}

class _VoiceDemoPageState extends State<VoiceDemoPage> {
  final _voice = SixPagesVoice();

  String _status = 'Idle';
  bool _running = false;
  int _frameCount = 0;
  int _totalBytes = 0;

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

    _sub = _voice.captureStream.listen(
      (frame) {
        setState(() {
          _frameCount++;
          _totalBytes += frame.length;
          _status = 'Running';
        });
      },
      onError: (e) => setState(() => _status = 'Stream error: $e'),
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
    });
  }

  // Feeds a short tone through the real playback path (what Joe's PCM uses).
  Future<void> _playTone() async {
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
    setState(() => _status = 'Tone fed');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Six Pages Voice — Example')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Status: $_status', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            Text('Frames: $_frameCount   Bytes: $_totalBytes',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _running ? _playTone : null,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Play tone (playback path)'),
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

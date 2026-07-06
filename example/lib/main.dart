import 'package:flutter/material.dart';
import 'package:six_pages_voice/six_pages_voice.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _plugin = SixPagesVoice();
  String _status = 'idle';

  Future<void> _start() async {
    final ok = await _plugin.start();
    setState(() => _status = ok ? 'started' : 'start failed');
  }

  Future<void> _stop() async {
    await _plugin.stop();
    setState(() => _status = 'stopped');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Six Pages Voice test')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Status: ' + _status),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: _start, child: const Text('Start')),
              ElevatedButton(onPressed: _stop, child: const Text('Stop')),
            ],
          ),
        ),
      ),
    );
  }
}

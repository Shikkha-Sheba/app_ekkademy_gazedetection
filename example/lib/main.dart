// Minimal usage example. Not a full app — see the package README for
// screen-integration examples (video player, live class, audio-only).

import 'package:ekkademy_gazedetection/ekkademy_gazedetection.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  late final AttentivenessMonitor _monitor;

  @override
  void initState() {
    super.initState();
    _monitor = AttentivenessMonitor(config: AttentivenessConfig.relaxed)
      ..onBecameInattentive = _handleInattentive;
    _monitor.start().catchError((_) {
      // camera permission denied — skip the feature
    });
  }

  Future<void> _handleInattentive(AttentivenessResult result) async {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final res = await showAttentivenessPrompt(context: context);
    await _monitor.stopAlertSound();
    if (res?.dontShowAgain ?? false) {
      await _monitor.dismissForSession();
    }
  }

  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void dispose() {
    _monitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      home: Scaffold(
        appBar: AppBar(title: const Text('ekkademy_gazedetection example')),
        body: ValueListenableBuilder<AttentivenessStatus>(
          valueListenable: _monitor.status,
          builder: (context, status, _) => Center(
            child: Text('Status: $status'),
          ),
        ),
      ),
    );
  }
}

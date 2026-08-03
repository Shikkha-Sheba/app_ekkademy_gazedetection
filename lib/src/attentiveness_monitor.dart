// attentiveness_monitor.dart
//
// This is the class you actually use from a screen. It wraps
// AttentivenessService and turns noisy per-frame results into clean,
// debounced events so a single blink or quick glance doesn't fire an alert.
//
// Fully standalone — works from a video player, a live-class screen, an
// audio-only screen, anywhere. Just create one, wire up the callbacks you
// care about, and call start().
//
// "Don't show this again" is intentionally in-memory only, scoped to this
// monitor instance — i.e. to the current video/live session, not saved to
// disk. Create one AttentivenessMonitor per video/section (which you're
// already doing, since it owns the camera) and the dismissal naturally
// resets the next time the learner opens a new one.
//
// Example:
//
//   final monitor = AttentivenessMonitor(config: AttentivenessConfig.relaxed);
//   monitor.onBecameInattentive = (result) async {
//     // buzzer is already playing (enableSoundAlert); show the prompt.
//     final res = await showAttentivenessPrompt(context: context);
//     await monitor.stopAlertSound();
//     if (res?.dontShowAgain ?? false) {
//       await monitor.dismissForSession(); // stops tracking for this video
//     }
//   };
//   monitor.onFaceMissing = (result) { /* learner walked away */ };
//   monitor.onMultiplePersonsDetected = (result) {
//     // someone else is in frame — pause playback, log analytics, etc.
//   };
//   await monitor.start();
//   ...
//   await monitor.dispose(); // in dispose(), when leaving this video/section

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:just_audio/just_audio.dart';

import 'attentiveness_config.dart';
import 'attentiveness_models.dart';
import 'attentiveness_service.dart';

typedef AttentivenessCallback = void Function(AttentivenessResult result);

class AttentivenessMonitor {
  final AttentivenessConfig config;
  final AttentivenessService _service;
  StreamSubscription<AttentivenessResult>? _subscription;
  AudioPlayer? _audioPlayer;
  bool _audioLoaded = false;

  /// True once the learner has checked "Don't show this again" for the
  /// current video/section. In-memory only — not saved anywhere, so it
  /// resets whenever a new AttentivenessMonitor is created (e.g. the next
  /// video). See [dismissForSession].
  bool get isDismissedForSession => _dismissedForSession;
  bool _dismissedForSession = false;

  /// Live status you can listen to directly (e.g. in a ValueListenableBuilder
  /// to show a small "distracted" badge somewhere in the UI).
  final ValueNotifier<AttentivenessStatus> status =
  ValueNotifier(AttentivenessStatus.unknown);

  /// Fires once when the learner has been continuously distracted (looking
  /// away or eyes closed) for [AttentivenessConfig.inattentiveGracePeriod].
  /// Will not fire again until they return to attentive.
  AttentivenessCallback? onBecameInattentive;

  /// Fires once when the learner returns to "attentive" after having
  /// triggered [onBecameInattentive].
  AttentivenessCallback? onBecameAttentive;

  /// Fires once when the face has been missing for
  /// [AttentivenessConfig.faceMissingGracePeriod] (they left, camera
  /// covered, etc).
  AttentivenessCallback? onFaceMissing;

  /// Fires once when the face reappears after [onFaceMissing] triggered.
  AttentivenessCallback? onFaceReturned;

  /// Fires once when more than one face has been continuously visible for
  /// [AttentivenessConfig.multiplePersonsGracePeriod] — someone else is with
  /// the learner, or looking over their shoulder.
  AttentivenessCallback? onMultiplePersonsDetected;

  /// Fires once the frame drops back to a single face (or none) after
  /// [onMultiplePersonsDetected] triggered.
  AttentivenessCallback? onMultiplePersonsCleared;

  /// Optional: called on every single processed frame, useful for debug
  /// logging or building your own analytics/heatmap of attention over time.
  AttentivenessCallback? onSample;

  DateTime? _inattentiveSince;
  DateTime? _faceMissingSince;
  DateTime? _multiplePersonsSince;
  bool _inattentiveFired = false;
  bool _faceMissingFired = false;
  bool _multiplePersonsFired = false;

  final bool _external;

  AttentivenessMonitor({AttentivenessConfig? config})
      : config = config ?? const AttentivenessConfig(),
        _external = false,
        _service = AttentivenessService(
          config: config ?? const AttentivenessConfig(),
        ) {
    if (this.config.enableSoundAlert) {
      _audioPlayer = AudioPlayer();
    }
  }

  /// Use when something else already owns the camera (e.g. a LiveKit call
  /// screen). No camera is opened by this monitor — call [pushFrame]
  /// yourself with frames captured however you like (a periodic snapshot
  /// of the local video renderer, for instance).
  AttentivenessMonitor.externalSource({AttentivenessConfig? config})
      : config = config ?? const AttentivenessConfig(),
        _external = true,
        _service = AttentivenessService.externalSource(
          config: config ?? const AttentivenessConfig(),
        ) {
    if (this.config.enableSoundAlert) {
      _audioPlayer = AudioPlayer();
    }
  }

  bool get isRunning => _service.isRunning;

  /// Feed one externally-captured frame. Only valid on a monitor created
  /// via [AttentivenessMonitor.externalSource]. Call [start] once first —
  /// it just spins up the face detector in this mode, no camera involved.
  Future<void> pushFrame(InputImage inputImage) async {
    if (!_external) {
      throw StateError('pushFrame is only for AttentivenessMonitor.externalSource().');
    }
    print("InputImage ${inputImage.filePath}");
    await _service.pushFrame(inputImage);
  }

  /// Marks "don't show this again" for the rest of this video/section.
  /// Purely in-memory — nothing is written to disk, so a new video (new
  /// AttentivenessMonitor) starts fresh. Also stops the camera/detector and
  /// any playing alert sound, same as [pause].
  Future<void> dismissForSession() async {
    _dismissedForSession = true;
    await pause();
  }

  /// Reverses [dismissForSession] and lets [start] run again, e.g. if you
  /// want to re-enable tracking mid-session without creating a new monitor.
  void resetDismissal() {
    _dismissedForSession = false;
  }

  /// Requests camera permission and starts monitoring. Safe to call again
  /// after [pause].
  ///
  /// No-ops if the learner already chose "don't show this again" for this
  /// session (see [dismissForSession]). Pass `ignoreDismissal: true` to
  /// force a start anyway (e.g. an instructor-forced proctored exam mode).
  Future<void> start({bool ignoreDismissal = false}) async {
    print('start() entered — isRunning=${_service.isRunning}, dismissed=$_dismissedForSession');
    if (_service.isRunning) return;
    if (!ignoreDismissal && _dismissedForSession) return;
    if (_external) {
      print("start called on external source");
      await _service.startExternal();
    } else {
      print("start called on own source");
      await _service.start();
    }
    _subscription = _service.results.listen(_handleResult);
  }

  /// Temporarily stops the camera/detector (e.g. app backgrounded) without
  /// discarding your callback setup or the session dismissal flag. Call
  /// [start] again to resume — this is aliased as [resume] for readability
  /// at call sites.
  Future<void> pause() async {
    await _subscription?.cancel();
    _subscription = null;
    await _service.stop();
    await _stopAlertSound();
    status.value = AttentivenessStatus.unknown;
  }

  Future<void> resume() => start();

  void _handleResult(AttentivenessResult result) {
    status.value = result.status;
    print("status.value = ${status.value}");
    onSample?.call(result);

    final now = result.timestamp;

    // --- multiple-persons tracking -----------------------------------
    if (config.enableMultiplePersonDetection &&
        result.status == AttentivenessStatus.multiplePersonsDetected) {
      _multiplePersonsSince ??= now;
      if (!_multiplePersonsFired &&
          now.difference(_multiplePersonsSince!) >=
              config.multiplePersonsGracePeriod) {
        _multiplePersonsFired = true;
        _playAlertSound();
        onMultiplePersonsDetected?.call(result);
      }
      // Multiple people in frame makes the face-missing/inattentive checks
      // below moot for this frame, so stop here.
      return;
    } else {
      if (_multiplePersonsFired) onMultiplePersonsCleared?.call(result);
      _multiplePersonsSince = null;
      _multiplePersonsFired = false;
    }

    // --- face-missing tracking -------------------------------------------
    // if (result.status == AttentivenessStatus.faceNotDetected) {
    //   _faceMissingSince ??= now;
    //   if (!_faceMissingFired &&
    //       now.difference(_faceMissingSince!) >= config.faceMissingGracePeriod) {
    //     _faceMissingFired = true;
    //     _playAlertSound();
    //     onFaceMissing?.call(result);
    //   }
    // } else {
    //   if (_faceMissingFired) onFaceReturned?.call(result);
    //   _faceMissingSince = null;
    //   _faceMissingFired = false;
    // }

    // --- inattentive tracking (looking away / eyes closed) ----------------
    final isInattentiveNow = result.status == AttentivenessStatus.lookingLeft ||
        result.status == AttentivenessStatus.lookingRight ||
        result.status == AttentivenessStatus.eyesClosed || result.status == AttentivenessStatus.faceNotDetected;

    if (isInattentiveNow) {
      _inattentiveSince ??= now;
      if (!_inattentiveFired &&
          now.difference(_inattentiveSince!) >= config.inattentiveGracePeriod) {
        _inattentiveFired = true;
        _playAlertSound();
        onBecameInattentive?.call(result);
      }
    } else if (result.status == AttentivenessStatus.attentive) {
      if (_inattentiveFired) onBecameAttentive?.call(result);
      _inattentiveSince = null;
      _inattentiveFired = false;
      _stopAlertSound();
    }
  }

  Future<void> _ensureAudioLoaded() async {
    if (_audioLoaded || _audioPlayer == null || config.alertSoundAsset == null) {
      return;
    }
    await _audioPlayer!.setAsset(config.alertSoundAsset!);
    await _audioPlayer!.setLoopMode(LoopMode.one);
    _audioLoaded = true;
  }

  Future<void> _playAlertSound() async {
    if (!config.enableSoundAlert || _audioPlayer == null) return;
    try {
      await _ensureAudioLoaded();
      await _audioPlayer!.seek(Duration.zero);
      await _audioPlayer!.play();
    } on Exception catch (e, st) {
      debugPrint('AttentivenessMonitor._playAlertSound error: $e\n$st');
    }
  }

  /// Stops the alert/buzzer sound. Call this once you've shown (and the
  /// learner has responded to) your attentiveness prompt, so it doesn't
  /// keep looping underneath the dialog. Uses pause+rewind rather than
  /// stop() so the next alert can replay instantly without reloading the
  /// asset.
  Future<void> stopAlertSound() => _stopAlertSound();

  Future<void> _stopAlertSound() async {
    if (_audioPlayer == null) return;
    try {
      await _audioPlayer!.pause();
      await _audioPlayer!.seek(Duration.zero);
    } on Exception catch (e, st) {
      debugPrint('AttentivenessMonitor._stopAlertSound error: $e\n$st');
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _service.dispose();
    await _audioPlayer?.dispose();
    status.dispose();
  }
}
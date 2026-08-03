// attentiveness_monitor.dart
//
// This is the class you actually use from a screen. It wraps
// AttentivenessService and turns noisy per-frame results into clean,
// confirmed events so a single blink or quick glance doesn't fire an alert.
//
// Fully standalone — works from a video player, a live-class screen, an
// audio-only screen, anywhere. Just create one, wire up the callbacks you
// care about, and call start().
//
// HOW INATTENTIVENESS IS DECIDED — see the doc comment at the top of
// attentiveness_config.dart for the full window/confirm-count explanation.
// In short, with the default config: frames are sampled every 15s, smoothed
// over a 3-frame window (majority, or unanimous while the window is still
// filling), and 2 confirmed windowed-inattentive samples in a row (~30s)
// trigger `onBecameInattentive`.
//
// THE PROMPT / IGNORE / FORCE-ATTENTIVE FLOW:
//
//   final monitor = AttentivenessMonitor(config: AttentivenessConfig.relaxed);
//
//   monitor.onBecameInattentive = (result) async {
//     // buzzer is already playing (enableSoundAlert); show the prompt.
//     final res = await showAttentivenessPrompt(context: context);
//     if (res?.confirmed ?? false) {
//       // Learner tapped "I'm here" — force the state back to attentive.
//       await monitor.markAttentive();
//     } else if (res?.ignored ?? false) {
//       // Learner tapped "Ignore" — stop bugging them with the dialog, but
//       // keep tracking in the background so a teacher can still be
//       // notified (see onInattentiveWhileIgnoring below).
//       await monitor.ignoreInattentiveness();
//     }
//     if (res?.dontShowAgain ?? false) {
//       await monitor.dismissForSession(); // stops tracking for this video
//     }
//   };
//
//   // While ignoring, fires every extra ~30s the learner stays inattentive,
//   // so you can let a teacher/dashboard know without re-showing a dialog.
//   monitor.onInattentiveWhileIgnoring = (result) {
//     notifyTeacherStillDistracted(result);
//   };
//
//   // While ignoring, fires once if the learner becomes attentive again.
//   monitor.onBecameAttentiveWhileIgnoring = (result) {
//     notifyTeacherBackToAttentive(result);
//   };
//
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

  /// True once [onBecameInattentive] has fired and the learner has chosen
  /// to ignore the prompt via [ignoreInattentiveness], instead of
  /// confirming via [markAttentive]. While true, the dialog is not
  /// re-triggered, but [onInattentiveWhileIgnoring] /
  /// [onBecameAttentiveWhileIgnoring] keep firing in its place.
  bool get isIgnoring => _isIgnoring;
  bool _isIgnoring = false;

  /// Fires once when the learner has been continuously (confirmed, smoothed)
  /// distracted for [AttentivenessConfig.inattentiveConfirmCount] consecutive
  /// samples — 30 seconds with the default config. This is your cue to show
  /// [showAttentivenessPrompt]. Will not fire again until the learner either
  /// returns to attentive (via a real frame) or is force-marked attentive
  /// via [markAttentive], and does not fire again at all while
  /// [isIgnoring] is true.
  AttentivenessCallback? onBecameInattentive;

  /// Fires once when the learner returns to "attentive" after having
  /// triggered [onBecameInattentive] (and was not in the middle of
  /// [ignoreInattentiveness] — see [onBecameAttentiveWhileIgnoring] for
  /// that case).
  AttentivenessCallback? onBecameAttentive;

  /// While [isIgnoring] is true, fires every additional
  /// [AttentivenessConfig.ignoreRepeatConfirmCount] consecutive confirmed
  /// inattentive samples (30 seconds again, by default) — i.e. it keeps
  /// firing roughly every 30s for as long as the learner stays inattentive
  /// and ignoring, so you can let a teacher/dashboard know without
  /// re-showing the dialog.
  AttentivenessCallback? onInattentiveWhileIgnoring;

  /// Fires once if the learner becomes attentive again while [isIgnoring]
  /// was true. Also clears [isIgnoring].
  AttentivenessCallback? onBecameAttentiveWhileIgnoring;

  /// Fires once when more than one face has been continuously visible for
  /// [AttentivenessConfig.multiplePersonsGracePeriod] — someone else is with
  /// the learner, or looking over their shoulder.
  AttentivenessCallback? onMultiplePersonsDetected;

  /// Fires once the frame drops back to a single face (or none) after
  /// [onMultiplePersonsDetected] triggered.
  AttentivenessCallback? onMultiplePersonsCleared;

  /// Optional: called on every single processed (raw, pre-smoothing) frame,
  /// useful for debug logging or building your own analytics/heatmap of
  /// attention over time.
  AttentivenessCallback? onSample;

  // --- sliding-window / confirm-count state for inattentiveness ----------
  final List<bool> _recentInattentiveFlags = [];
  int _consecutiveInattentive = 0;
  bool _promptFired = false;
  int _lastIgnoreNotifyCount = 0;

  // --- multiple-persons state (unchanged time-based debounce) ------------
  DateTime? _multiplePersonsSince;
  bool _multiplePersonsFired = false;

  final bool _external;

  AttentivenessMonitor({AttentivenessConfig? config})
      : config = config ?? AttentivenessConfig(),
        _external = false,
        _service = AttentivenessService(
          config: config ?? AttentivenessConfig(),
        ) {
    if (this.config.enableSoundAlert) {
      _audioPlayer = AudioPlayer();
    }
  }

  /// Use when something else already owns the camera (e.g. a LiveKit call
  /// screen). No camera is opened by this monitor — call [pushFrame]
  /// yourself with frames captured however you like (a periodic snapshot
  /// of the local video renderer, for instance — respect
  /// [AttentivenessConfig.sampleInterval] yourself, since external mode
  /// does not re-throttle).
  AttentivenessMonitor.externalSource({AttentivenessConfig? config})
      : config = config ?? AttentivenessConfig(),
        _external = true,
        _service = AttentivenessService.externalSource(
          config: config ?? AttentivenessConfig(),
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

  /// Call this when the learner responds "I'm here" / "Ok" to the prompt
  /// shown from [onBecameInattentive]. Forcefully resets the monitor's
  /// state to attentive — clears the smoothing window, the consecutive
  /// counter, and [isIgnoring] — and stops the alert sound. The next raw
  /// frame classification starts building a fresh window from scratch.
  Future<void> markAttentive() async {
    _resetInattentiveTracking();
    status.value = AttentivenessStatus.attentive;
    await _stopAlertSound();
  }

  /// Call this when the learner chooses "Ignore" on the prompt shown from
  /// [onBecameInattentive] instead of confirming. The dialog will not be
  /// shown again for this same inattentive stretch, but the monitor keeps
  /// tracking: every extra [AttentivenessConfig.ignoreRepeatConfirmCount]
  /// confirmed inattentive samples (30s by default) fires
  /// [onInattentiveWhileIgnoring], and if the learner becomes attentive
  /// again, [onBecameAttentiveWhileIgnoring] fires once. Stops the alert
  /// sound so it doesn't keep looping while ignored.
  Future<void> ignoreInattentiveness() async {
    _isIgnoring = true;
    _lastIgnoreNotifyCount = _consecutiveInattentive;
    await _stopAlertSound();
  }

  /// Requests camera permission and starts monitoring. Safe to call again
  /// after [pause].
  ///
  /// No-ops if the learner already chose "don't show this again" for this
  /// session (see [dismissForSession]). Pass `ignoreDismissal: true` to
  /// force a start anyway (e.g. an instructor-forced proctored exam mode).
  Future<void> start({bool ignoreDismissal = false}) async {
    if (_service.isRunning) return;
    if (!ignoreDismissal && _dismissedForSession) return;
    if (_external) {
      await _service.startExternal();
    } else {
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
    onSample?.call(result);

    // --- multiple-persons tracking (unchanged, time-based) ---------------
    if (config.enableMultiplePersonDetection &&
        result.status == AttentivenessStatus.multiplePersonsDetected) {
      _multiplePersonsSince ??= result.timestamp;
      if (!_multiplePersonsFired &&
          result.timestamp.difference(_multiplePersonsSince!) >=
              config.multiplePersonsGracePeriod) {
        _multiplePersonsFired = true;
        _playAlertSound();
        onMultiplePersonsDetected?.call(result);
      }
      // Multiple people in frame makes the inattentive window logic below
      // moot for this frame, so stop here (matches previous behaviour).
      return;
    } else {
      if (_multiplePersonsFired) onMultiplePersonsCleared?.call(result);
      _multiplePersonsSince = null;
      _multiplePersonsFired = false;
    }

    // --- inattentive tracking: sliding window + confirm-count -------------
    final isRawInattentive =
        result.status == AttentivenessStatus.lookingLeft ||
            result.status == AttentivenessStatus.lookingRight ||
            result.status == AttentivenessStatus.eyesClosed ||
            result.status == AttentivenessStatus.faceNotDetected;

    _recentInattentiveFlags.add(isRawInattentive);
    if (_recentInattentiveFlags.length > config.inattentiveWindowSize) {
      _recentInattentiveFlags.removeAt(0);
    }

    final windowInattentive = _evaluateWindow();

    if (windowInattentive) {
      _consecutiveInattentive++;

      if (!_isIgnoring) {
        if (!_promptFired &&
            _consecutiveInattentive >= config.inattentiveConfirmCount) {
          _promptFired = true;
          _playAlertSound();
          onBecameInattentive?.call(result);
        }
      } else {
        if (_consecutiveInattentive - _lastIgnoreNotifyCount >=
            config.ignoreRepeatConfirmCount) {
          _lastIgnoreNotifyCount = _consecutiveInattentive;
          onInattentiveWhileIgnoring?.call(result);
        }
      }
    } else {
      // Window says attentive — resolve whichever state we were in.
      if (_isIgnoring) {
        onBecameAttentiveWhileIgnoring?.call(result);
      } else if (_promptFired) {
        onBecameAttentive?.call(result);
      }
      _resetInattentiveTracking();
      _stopAlertSound();
    }
  }

  /// Scores the current sliding window of raw per-frame flags:
  ///  - If the window is full ([AttentivenessConfig.inattentiveWindowSize]
  ///    entries), it's "inattentive" on a majority (e.g. 2 of 3).
  ///  - If the window hasn't filled up yet (e.g. only 2 samples exist so
  ///    far), it's "inattentive" only if ALL of them are (e.g. 2 of 2).
  bool _evaluateWindow() {
    final n = _recentInattentiveFlags.length;
    if (n == 0) return false;
    final trueCount = _recentInattentiveFlags.where((f) => f).length;
    final isFull = n >= config.inattentiveWindowSize;
    final threshold = isFull ? (config.inattentiveWindowSize / 2).ceil() : n;
    return trueCount >= threshold;
  }

  void _resetInattentiveTracking() {
    _recentInattentiveFlags.clear();
    _consecutiveInattentive = 0;
    _promptFired = false;
    _isIgnoring = false;
    _lastIgnoreNotifyCount = 0;
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
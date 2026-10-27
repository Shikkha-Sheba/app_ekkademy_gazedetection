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
// In short, with the default config: frames are sampled every 10s, smoothed
// over a 3-frame window (majority, or unanimous while the window is still
// filling), and 3 confirmed windowed-inattentive samples in a row (~30s)
// trigger `onBecameInattentive`.
//
// HOW MULTIPLE-PERSONS IS DECIDED — also see attentiveness_config.dart.
// In short: `onMultiplePersonsDetected` fires once a second face has shown
// up on `multiplePersonsConfirmCount` CONSECUTIVE processed frames (default
// 3) — any frame without a second face resets that streak to zero. On the
// camera-owning path, AttentivenessService still switches to a much faster
// internal sampling cadence (`multiplePersonsCheckInterval`, 5s by default)
// the instant a second face shows up, so that streak is still confirmed
// quickly in real time; this class itself just counts consecutive frames,
// it doesn't need to know about the faster cadence. Keeps re-firing every
// further `multiplePersonsConfirmCount` consecutive frames for as long as
// the extra face stays in view.
//
// DISTRACTED vs MULTIFACE SHARE ONE STREAK — a frame is classified as
// exactly one of attentive / distracted / multiface, never more than one,
// and the "how many consecutive frames of the same kind in a row" counter
// is shared across the two alert categories rather than tracked
// independently. That means:
//   - distracted, distracted -> onBecameInattentive fires on the 2nd frame
//     (with inattentiveConfirmCount 2).
//   - distracted, multiface -> the mismatch doesn't count toward EITHER
//     alert; the multiface frame simply starts its own fresh streak at 1,
//     as if it were the first frame of its kind seen so far.
//   - any attentive frame immediately zeroes the streak no matter what it
//     was mid-way through.
//   - firing either alert also immediately zeroes the streak (not just the
//     re-fire cadence) — the next alert of either kind needs a brand new
//     run of consecutive same-category frames from scratch.
//
// THE PROMPT / IGNORE / FORCE-ATTENTIVE FLOW:
//
//   final monitor = AttentivenessMonitor(config: AttentivenessConfig.relaxed);
//
//   monitor.onBecameInattentive = (result) async {
//     // buzzer is already playing (enableSoundAlert); show the prompt.
//     // NOTE: this callback keeps re-firing every `inattentiveConfirmCount`
//     // samples while the learner stays inattentive (e.g. every 30s with
//     // AttentivenessConfig.classroomFast). showAttentivenessPrompt()
//     // auto-dismisses its own previous dialog first, so calling it again
//     // here just swaps the old prompt for a fresh one.
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

/// The three mutually-exclusive buckets a single processed frame falls
/// into, used by [AttentivenessMonitor]'s unified consecutive-streak
/// tracking (see the field doc on `_lastCategory` below).
enum _FrameCategory { attentive, distracted, multiface }

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
  final ValueNotifier<AttentivenessStatus> status = ValueNotifier(
    AttentivenessStatus.unknown,
  );

  /// Live detected face emotion you can listen to directly (e.g. in a ValueListenableBuilder).
  final ValueNotifier<FaceEmotion> emotion = ValueNotifier(
    FaceEmotion.unknown,
  );

  /// True once [onBecameInattentive] has fired and the learner has chosen
  /// to ignore the prompt via [ignoreInattentiveness], instead of
  /// confirming via [markAttentive]. While true, the dialog is not
  /// re-triggered, but [onInattentiveWhileIgnoring] /
  /// [onBecameAttentiveWhileIgnoring] keep firing in its place.
  bool get isIgnoring => _isIgnoring;
  bool _isIgnoring = false;

  /// Fires when the learner has been continuously (confirmed, smoothed)
  /// distracted for [AttentivenessConfig.inattentiveConfirmCount] consecutive
  /// samples — 30 seconds with the default config (3 samples x 10s
  /// sampleInterval). This is your cue to show [showAttentivenessPrompt];
  /// since that helper auto-dismisses any prompt it still has open, calling
  /// it again from a later firing of this callback just swaps the old
  /// dialog for a fresh one rather than stacking.
  ///
  /// Keeps re-firing every additional
  /// [AttentivenessConfig.inattentiveConfirmCount] consecutive inattentive
  /// samples (another 30s by default) for as long as the learner stays
  /// inattentive, so a new prompt keeps replacing the old one roughly every
  /// 30s. Stops re-firing once the learner either returns to attentive (via
  /// a real frame — fires [onBecameAttentive] once), is force-marked
  /// attentive via [markAttentive], or taps "Ignore" (see [isIgnoring] /
  /// [onInattentiveWhileIgnoring]).
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

  /// Fires when more than one face has been detected on
  /// [AttentivenessConfig.multiplePersonsConfirmCount] CONSECUTIVE processed
  /// frames — someone else is with the learner, or looking over their
  /// shoulder. With the default (and [AttentivenessConfig.classroomFast])
  /// config that's 2 consecutive frames — e.g. two 15s-apart pushed frames
  /// both showing a second face (~30s total).
  ///
  /// A single non-multi frame in between (whether it's attentive OR
  /// distracted) breaks the streak back to zero, and — just like
  /// [onBecameInattentive] — this keeps re-firing every further
  /// [AttentivenessConfig.multiplePersonsConfirmCount] consecutive
  /// multi-person frames for as long as the extra face keeps showing up, so
  /// a fresh alert keeps replacing the previous one roughly every 30s
  /// instead of firing once and going quiet.
  AttentivenessCallback? onMultiplePersonsDetected;

  /// Fires once the frame drops back to a single face (or none, or the
  /// learner became distracted) after [onMultiplePersonsDetected] fired.
  AttentivenessCallback? onMultiplePersonsCleared;

  /// Optional: called when face emotion/expression is detected on a frame.
  void Function(FaceEmotion emotion, AttentivenessResult result)? onEmotionDetected;

  /// Optional: called on every single processed (raw, pre-smoothing) frame,
  /// useful for debug logging or building your own analytics/heatmap of
  /// attention over time.
  AttentivenessCallback? onSample;

  // --- sliding-window smoothing for the "distracted" raw classification
  // only (see AttentivenessConfig.inattentiveWindowSize doc). Multiface
  // has no smoothing — it's driven by the raw per-frame flag directly. ----
  final List<bool> _recentInattentiveFlags = [];

  // --- unified consecutive-streak state across BOTH alert categories.
  // Only one of {distracted, multiface} is ever "current" at a time: a
  // frame whose category differs from `_lastCategory` does NOT extend the
  // previous streak — it starts a brand new streak of length 1 for its own
  // category instead (a distracted->multiface->distracted sequence never
  // fires either alert off 2 total frames of the same kind that weren't
  // actually consecutive). Firing an alert immediately zeroes this state,
  // so the next alert (of either kind) needs a fresh streak from scratch —
  // no partial carry-over. Any attentive frame also zeroes this state
  // immediately. -----------------------------------------------------------
  _FrameCategory? _lastCategory;
  int _streakCount = 0;

  // --- "have we alerted since the last real attentive frame" bookkeeping,
  // kept separate from the streak counters above so onBecameAttentive /
  // onMultiplePersonsCleared still fire correctly even though the streak
  // itself got zeroed out the moment the alert fired. --------------------
  bool _promptFired = false;
  bool _multiFired = false;

  final bool _external;

  AttentivenessMonitor({AttentivenessConfig? config})
    : config = config ?? AttentivenessConfig(),
      _external = false,
      _service = AttentivenessService(config: config ?? AttentivenessConfig()) {
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
      throw StateError(
        'pushFrame is only for AttentivenessMonitor.externalSource().',
      );
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
    _resetStreak();
    _promptFired = false;
    _isIgnoring = false;
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
    emotion.value = FaceEmotion.unknown;
  }

  Future<void> resume() => start();

  void _handleResult(AttentivenessResult result) {
    status.value = result.status;
    emotion.value = result.emotion;
    onEmotionDetected?.call(result.emotion, result);
    onSample?.call(result);

    final isMultiface =
        config.enableMultiplePersonDetection &&
        result.status == AttentivenessStatus.multiplePersonsDetected;

    if (isMultiface) {
      // A multiface frame makes the inattentive window logic below moot
      // for this frame (matches previous behaviour) — go straight to the
      // unified streak handling.
      _advanceStreak(_FrameCategory.multiface, result);
      return;
    }

    // Not a multiface frame — clear any pending "multiple persons" alert.
    if (_multiFired) onMultiplePersonsCleared?.call(result);
    _multiFired = false;

    // --- "distracted" classification: sliding window + smoothing --------
    final isRawInattentive =
        result.status == AttentivenessStatus.lookingLeft ||
        result.status == AttentivenessStatus.lookingRight ||
        result.status == AttentivenessStatus.eyesClosed ||
        result.status == AttentivenessStatus.faceNotDetected;

    _recentInattentiveFlags.add(isRawInattentive);
    if (_recentInattentiveFlags.length > config.inattentiveWindowSize) {
      _recentInattentiveFlags.removeAt(0);
    }

    if (_evaluateWindow()) {
      _advanceStreak(_FrameCategory.distracted, result);
    } else {
      // Attentive — resolve whichever state we were in and fully reset.
      if (_isIgnoring) {
        onBecameAttentiveWhileIgnoring?.call(result);
      } else if (_promptFired) {
        onBecameAttentive?.call(result);
      }
      _isIgnoring = false;
      _promptFired = false;
      _resetStreak();
      _stopAlertSound();
    }
  }

  /// Advances the unified consecutive-streak counter for [category] (a
  /// non-attentive frame — attentive is handled separately in
  /// [_handleResult], since it resets everything unconditionally rather
  /// than joining a streak).
  ///
  /// If [category] matches [_lastCategory] the streak continues; otherwise
  /// a mismatched category (e.g. distracted immediately followed by
  /// multiface) discards whatever streak was building and starts a brand
  /// new one at 1 for [category] — the mismatched frame itself is never
  /// silently dropped, it just becomes the first sample of its own kind.
  ///
  /// Once the streak reaches the relevant confirm count the matching
  /// callback fires and the streak is immediately zeroed back to scratch,
  /// so the *next* alert (of either kind) needs a fresh run of consecutive
  /// same-category frames rather than continuing to build on a partial
  /// count left over from before.
  void _advanceStreak(_FrameCategory category, AttentivenessResult result) {
    _streakCount = category == _lastCategory ? _streakCount + 1 : 1;
    _lastCategory = category;

    if (category == _FrameCategory.multiface) {
      if (_streakCount >= config.multiplePersonsConfirmCount) {
        _multiFired = true;
        _playAlertSound();
        onMultiplePersonsDetected?.call(result);
        _resetStreak();
      }
      return;
    }

    // category == distracted
    if (!_isIgnoring) {
      if (_streakCount >= config.inattentiveConfirmCount) {
        _promptFired = true;
        _playAlertSound();
        onBecameInattentive?.call(result);
        _resetStreak();
      }
    } else {
      if (_streakCount >= config.ignoreRepeatConfirmCount) {
        onInattentiveWhileIgnoring?.call(result);
        _resetStreak();
      }
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

  /// Zeroes the unified streak counter and the distraction smoothing
  /// window. Does NOT touch [_isIgnoring] / [_promptFired] / [_multiFired]
  /// — those are resolved explicitly by whichever caller needs to (a real
  /// attentive frame, or [markAttentive]), since they track "have we
  /// alerted since the last real attentive frame", a separate concern from
  /// "how long is the current same-category streak". Also zeroes the
  /// service's debug "Running: Xs" counter, since that's meant to track
  /// time-since-last-reset, not time-since-camera-started.
  void _resetStreak() {
    _recentInattentiveFlags.clear();
    _streakCount = 0;
    _lastCategory = null;
    _service.resetElapsedTimer();
  }

  Future<void> _ensureAudioLoaded() async {
    if (_audioLoaded ||
        _audioPlayer == null ||
        config.alertSoundAsset == null) {
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
    emotion.dispose();
  }
}

// attentiveness_config.dart
//
// Tunable thresholds for the attentiveness engine, plus two ready-made
// presets (`relaxed` / `strict`). Pass a custom instance to
// `AttentivenessMonitor(config: ...)` if the presets don't fit your case.
//
// HOW "INATTENTIVE" IS DECIDED (window + confirm-count):
//
// 1. Every [sampleInterval] (minimum 15 seconds — see below) one frame is
//    processed and classified as raw-inattentive or raw-attentive.
// 2. The last [inattentiveWindowSize] raw classifications are kept in a
//    sliding window. Each time a new one arrives, the window is re-scored:
//      - If the window is full (has [inattentiveWindowSize] entries), it
//        scores "inattentive" on a MAJORITY (e.g. 2 out of 3).
//      - If the window is still filling up (fewer entries so far, e.g. only
//        2 because the monitor just started), it scores "inattentive" only
//        if ALL of them are inattentive (e.g. 2 out of 2).
//    This is what keeps a single blink or one bad frame from mattering.
// 3. Each time the window scores "inattentive", a consecutive counter goes
//    up by one; a window score of "attentive" resets it to zero. Once that
//    counter reaches [inattentiveConfirmCount], `onBecameInattentive` fires
//    (with the defaults below: 2 samples x 15s sampleInterval = 30 seconds
//    of confirmed inattentiveness before the prompt is shown).
// 4. If the learner is shown the prompt and chooses to ignore it instead of
//    confirming, the monitor keeps counting in the background. Every
//    additional [ignoreRepeatConfirmCount] consecutive inattentive samples
//    (30s again, by default) it fires `onInattentiveWhileIgnoring` so you
//    can let a teacher/dashboard know, without re-showing the dialog. If
//    the learner becomes attentive again while ignoring,
//    `onBecameAttentiveWhileIgnoring` fires once instead.

class AttentivenessConfig {
  /// Absolute floor for [sampleInterval]. Enforced by an assertion in the
  /// constructor so frames can never be processed more often than this,
  /// regardless of preset or custom config — keeps CPU/battery cost and
  /// camera activity bounded.
  static const Duration minSampleInterval = Duration(seconds: 15);

  /// Minimum time between processed frames. Controls both CPU/battery cost
  /// and how "twitchy" detection feels. Must be >= [minSampleInterval]
  /// (15 seconds) — enforced at construction time.
  final Duration sampleInterval;

  /// Head yaw (left/right turn), in degrees, beyond which the learner is
  /// considered to be looking away.
  final double maxHeadYawDegrees;

  /// Head pitch (up/down tilt), in degrees, beyond which the learner is
  /// considered to be looking away.
  final double maxHeadPitchDegrees;

  /// Eye-open probability (0.0–1.0) below which an eye is considered closed.
  /// Both eyes must be below this for `AttentivenessStatus.eyesClosed`.
  final double eyeOpenThreshold;

  /// Whether to check for more than one face in frame at all. Turn this off
  /// if you don't care about "someone else is watching over their shoulder".
  final bool enableMultiplePersonDetection;

  /// How many of the most-recent raw per-frame classifications to keep in
  /// the smoothing window (see the class doc above). Default 3.
  final int inattentiveWindowSize;

  /// How many consecutive windowed "inattentive" scores in a row are needed
  /// before `onBecameInattentive` fires. With the defaults (2 x a 15s
  /// [sampleInterval]) that's 30 seconds of confirmed inattentiveness.
  final int inattentiveConfirmCount;

  /// While the learner is in the "ignoring" state (see
  /// `AttentivenessMonitor.ignoreInattentiveness`), how many additional
  /// consecutive windowed "inattentive" scores must pass before
  /// `onInattentiveWhileIgnoring` fires again. Defaults to the same cadence
  /// as [inattentiveConfirmCount] (30 seconds by default).
  final int ignoreRepeatConfirmCount;

  /// How long "more than one face in frame" must persist before
  /// `onMultiplePersonsDetected` fires. Independent of the window/confirm
  /// logic above, since multiple-person detection isn't noisy the same way.
  final Duration multiplePersonsGracePeriod;

  /// Whether to play a looping alert sound while an inattentive/multiple-
  /// persons state is active (stops automatically once resolved, or when
  /// you call `monitor.stopAlertSound()`).
  final bool enableSoundAlert;

  /// Asset path for the alert sound (e.g. `'assets/sounds/alert.mp3'`).
  /// Required if `enableSoundAlert` is true. Must be declared under
  /// `flutter: assets:` in the *consuming* app's pubspec, since Flutter
  /// packages don't bundle runtime assets for their dependents by default.
  final String? alertSoundAsset;

  AttentivenessConfig({
    this.sampleInterval = minSampleInterval,
    this.maxHeadYawDegrees = 25,
    this.maxHeadPitchDegrees = 20,
    this.eyeOpenThreshold = 0.4,
    this.enableMultiplePersonDetection = true,
    this.inattentiveWindowSize = 3,
    this.inattentiveConfirmCount = 2,
    this.ignoreRepeatConfirmCount = 2,
    this.multiplePersonsGracePeriod = const Duration(seconds: 3),
    this.enableSoundAlert = true,
    this.alertSoundAsset,
  })  : assert(
          sampleInterval >= minSampleInterval,
          'sampleInterval must be at least ${minSampleInterval.inSeconds}s '
          'so frames are not processed too continuously.',
        ),
        assert(inattentiveWindowSize >= 1, 'inattentiveWindowSize must be >= 1'),
        assert(inattentiveConfirmCount >= 1, 'inattentiveConfirmCount must be >= 1'),
        assert(ignoreRepeatConfirmCount >= 1, 'ignoreRepeatConfirmCount must be >= 1');

  /// Looser thresholds and longer confirm windows — good default for live
  /// classes or anywhere false positives (bad lighting, propped-up phone,
  /// glasses glare) would be disruptive. Frames every 20s; still needs 2
  /// confirmed windowed-inattentive samples (~40s) before the prompt fires.
  static final AttentivenessConfig relaxed = AttentivenessConfig(
    sampleInterval: const Duration(seconds: 20),
    maxHeadYawDegrees: 35,
    maxHeadPitchDegrees: 28,
    eyeOpenThreshold: 0.3,
    inattentiveWindowSize: 3,
    inattentiveConfirmCount: 2,
    ignoreRepeatConfirmCount: 2,
    multiplePersonsGracePeriod: const Duration(seconds: 5),
  );

  /// Tighter thresholds — for contexts where you want to catch distraction
  /// quickly (e.g. a proctored assessment). Uses the fastest allowed
  /// sampling rate (15s) so 2 confirmed samples = 30s.
  static final AttentivenessConfig strict = AttentivenessConfig(
    sampleInterval: minSampleInterval,
    maxHeadYawDegrees: 15,
    maxHeadPitchDegrees: 12,
    eyeOpenThreshold: 0.5,
    inattentiveWindowSize: 3,
    inattentiveConfirmCount: 2,
    ignoreRepeatConfirmCount: 2,
    multiplePersonsGracePeriod: const Duration(seconds: 2),
  );

  AttentivenessConfig copyWith({
    Duration? sampleInterval,
    double? maxHeadYawDegrees,
    double? maxHeadPitchDegrees,
    double? eyeOpenThreshold,
    bool? enableMultiplePersonDetection,
    int? inattentiveWindowSize,
    int? inattentiveConfirmCount,
    int? ignoreRepeatConfirmCount,
    Duration? multiplePersonsGracePeriod,
    bool? enableSoundAlert,
    String? alertSoundAsset,
  }) {
    return AttentivenessConfig(
      sampleInterval: sampleInterval ?? this.sampleInterval,
      maxHeadYawDegrees: maxHeadYawDegrees ?? this.maxHeadYawDegrees,
      maxHeadPitchDegrees: maxHeadPitchDegrees ?? this.maxHeadPitchDegrees,
      eyeOpenThreshold: eyeOpenThreshold ?? this.eyeOpenThreshold,
      enableMultiplePersonDetection:
          enableMultiplePersonDetection ?? this.enableMultiplePersonDetection,
      inattentiveWindowSize: inattentiveWindowSize ?? this.inattentiveWindowSize,
      inattentiveConfirmCount:
          inattentiveConfirmCount ?? this.inattentiveConfirmCount,
      ignoreRepeatConfirmCount:
          ignoreRepeatConfirmCount ?? this.ignoreRepeatConfirmCount,
      multiplePersonsGracePeriod:
          multiplePersonsGracePeriod ?? this.multiplePersonsGracePeriod,
      enableSoundAlert: enableSoundAlert ?? this.enableSoundAlert,
      alertSoundAsset: alertSoundAsset ?? this.alertSoundAsset,
    );
  }
}
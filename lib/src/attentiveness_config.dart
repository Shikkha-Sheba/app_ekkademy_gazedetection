// attentiveness_config.dart
//
// Tunable thresholds for the attentiveness engine, plus two ready-made
// presets (`relaxed` / `strict`). Pass a custom instance to
// `AttentivenessMonitor(config: ...)` if the presets don't fit your case.
//
// HOW "INATTENTIVE" IS DECIDED (window + confirm-count):
//
// 1. Every [sampleInterval] (minimum 5 seconds — see below; default 10s, so
//    3 frames every 30s) one frame is processed and classified as
//    raw-inattentive or raw-attentive.
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
//    (with the defaults below: 3 samples x 10s sampleInterval = 30 seconds
//    of confirmed inattentiveness before the prompt is shown).
// 4. If the learner is shown the prompt and chooses to ignore it instead of
//    confirming, the monitor keeps counting in the background. Every
//    additional [ignoreRepeatConfirmCount] consecutive inattentive samples
//    (30s again, by default) it fires `onInattentiveWhileIgnoring` so you
//    can let a teacher/dashboard know, without re-showing the dialog. If
//    the learner becomes attentive again while ignoring,
//    `onBecameAttentiveWhileIgnoring` fires once instead.
//
// HOW "MULTIPLE PERSONS" IS DECIDED (same window + confirm-count shape as
// distraction above, just its own separate streak):
//
// Every processed frame that comes back as
// `AttentivenessStatus.multiplePersonsDetected` bumps a consecutive counter;
// any frame that doesn't (single face, no face, or distracted) resets that
// counter to zero. Once the counter reaches [multiplePersonsConfirmCount],
// `onMultiplePersonsDetected` fires (default 3 consecutive frames). It then
// keeps re-firing every further [multiplePersonsConfirmCount] consecutive
// multi-person frames for as long as the extra face keeps showing up, and
// fires `onMultiplePersonsCleared` once the frame drops back to a single
// face (or none, or distracted).
//
// On the camera-owning ([AttentivenessMonitor.start]) path,
// `AttentivenessService` still temporarily switches its own sampling
// cadence from [sampleInterval] down to the faster
// [multiplePersonsCheckInterval] the moment a second face appears, so this
// still confirms quickly in real time even though the rule itself is now a
// plain frame count rather than a wall-clock duration. On the
// [AttentivenessMonitor.externalSource] path (frames pushed manually via
// `pushFrame`), the caller's own push cadence IS the sampling cadence — see
// [classroomFast] for a preset tuned to a 15s push interval.


class AttentivenessConfig {
  /// Absolute floor for [sampleInterval]. Enforced by an assertion in the
  /// constructor so frames can never be processed more often than this,
  /// regardless of preset or custom config — keeps CPU/battery cost and
  /// camera activity bounded. Default 5 seconds, which also happens to be
  /// the floor for [multiplePersonsCheckInterval]: at 5s a sustained
  /// multiple-persons burst still tops out at 6 frames per 30 seconds.
  static const Duration minSampleInterval = Duration(seconds: 5);

  /// Absolute floor for [multiplePersonsCheckInterval], for the same
  /// CPU/battery reason as [minSampleInterval].
  static const Duration minMultiplePersonsCheckInterval = Duration(seconds: 5);

  /// Minimum time between processed frames during normal (single-face)
  /// monitoring. Controls both CPU/battery cost and how "twitchy" detection
  /// feels. Must be >= [minSampleInterval] (5 seconds) — enforced at
  /// construction time. Default is 10 seconds, i.e. 3 frames every 30s.
  final Duration sampleInterval;

  /// Minimum time between processed frames while a second face is actively
  /// in view (see the "MULTIPLE PERSONS" section of the class doc above).
  /// Must be >= [minMultiplePersonsCheckInterval] (5 seconds) and should be
  /// <= [sampleInterval] — enforced at construction time. Default 5
  /// seconds, which lets [multiplePersonsGracePeriod] (15s by default) be
  /// confirmed by 3-4 frames instead of just 1, without slowing the alert
  /// down.
  final Duration multiplePersonsCheckInterval;

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

  /// Number of samples used for smoothing.
  ///
  /// NOT currently read by [AttentivenessMonitor] — multiple-persons
  /// detection is driven purely by consecutive-frame counting via
  /// [multiplePersonsConfirmCount] now, with no separate smoothing window.
  /// Kept for API stability / potential future use.
  final int multiplePersonsWindowSize;

  /// How many CONSECUTIVE processed frames must show more than one face
  /// before [AttentivenessMonitor.onMultiplePersonsDetected] fires. Any
  /// frame that doesn't show a second face resets this streak to zero.
  /// Mirrors [inattentiveConfirmCount]'s role for distraction. Default 3.
  final int multiplePersonsConfirmCount;

  /// How many of the most-recent raw per-frame classifications to keep in
  /// the smoothing window (see the class doc above). Default 3.
  final int inattentiveWindowSize;

  /// How many consecutive windowed "inattentive" scores in a row are needed
  /// before `onBecameInattentive` fires. With the defaults (3 x a 10s
  /// [sampleInterval]) that's 30 seconds of confirmed inattentiveness.
  final int inattentiveConfirmCount;

  /// While the learner is in the "ignoring" state (see
  /// `AttentivenessMonitor.ignoreInattentiveness`), how many additional
  /// consecutive windowed "inattentive" scores must pass before
  /// `onInattentiveWhileIgnoring` fires again. Defaults to the same cadence
  /// as [inattentiveConfirmCount] (30 seconds by default).
  final int ignoreRepeatConfirmCount;

  /// How long "more than one face in frame" must persist before
  /// `onMultiplePersonsDetected` fires.
  ///
  /// NOT currently read by [AttentivenessMonitor] — multiple-persons
  /// detection is now driven by [multiplePersonsConfirmCount] consecutive
  /// frames instead of a wall-clock duration, for the same reason
  /// distraction detection uses [inattentiveConfirmCount]: it scales
  /// correctly whether frames arrive every 5s (camera-owning path) or
  /// every 15-20s (a slower externalSource capture cadence). Kept for API
  /// stability / potential future use.
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
    this.sampleInterval = const Duration(seconds: 10),
    this.multiplePersonsCheckInterval = minMultiplePersonsCheckInterval,
    this.maxHeadYawDegrees = 25,
    this.maxHeadPitchDegrees = 20,
    this.eyeOpenThreshold = 0.4,
    this.multiplePersonsWindowSize = 3,
    this.multiplePersonsConfirmCount = 3,
    this.enableMultiplePersonDetection = true,
    this.inattentiveWindowSize = 3,
    this.inattentiveConfirmCount = 3,
    this.ignoreRepeatConfirmCount = 3,
    this.multiplePersonsGracePeriod = const Duration(seconds: 15),
    this.enableSoundAlert = true,
    this.alertSoundAsset,
  }) : assert(
         sampleInterval >= minSampleInterval,
         'sampleInterval must be at least ${minSampleInterval.inSeconds}s '
         'so frames are not processed too continuously.',
       ),
       assert(
         multiplePersonsCheckInterval >= minMultiplePersonsCheckInterval,
         'multiplePersonsCheckInterval must be at least '
         '${minMultiplePersonsCheckInterval.inSeconds}s so a sustained '
         'multiple-persons burst stays CPU/battery bounded.',
       ),
       assert(
         multiplePersonsCheckInterval <= sampleInterval,
         'multiplePersonsCheckInterval should be <= sampleInterval — '
         'otherwise the "fast check" while a second face is in view would '
         'be slower than normal single-face sampling.',
       ),
       assert(inattentiveWindowSize >= 1, 'inattentiveWindowSize must be >= 1'),
       assert(
         inattentiveConfirmCount >= 1,
         'inattentiveConfirmCount must be >= 1',
       ),
       assert(
         ignoreRepeatConfirmCount >= 1,
         'ignoreRepeatConfirmCount must be >= 1',
       );

  /// Looser thresholds and longer confirm windows — good default for live
  /// classes or anywhere false positives (bad lighting, propped-up phone,
  /// glasses glare) would be disruptive. Frames every 20s; needs 2
  /// confirmed windowed-inattentive samples (~40s) before the prompt fires.
  /// Multiple-persons still fast-checks at 10s once a second face appears,
  /// and (with the default [multiplePersonsConfirmCount] of 3) needs 3
  /// consecutive multi-person frames at that faster cadence (~30s) before
  /// `onMultiplePersonsDetected` fires.
  static final AttentivenessConfig relaxed = AttentivenessConfig(
    sampleInterval: const Duration(seconds: 20),
    multiplePersonsCheckInterval: const Duration(seconds: 10),
    maxHeadYawDegrees: 35,
    maxHeadPitchDegrees: 28,
    eyeOpenThreshold: 0.3,
    inattentiveWindowSize: 3,
    inattentiveConfirmCount: 2,
    ignoreRepeatConfirmCount: 2,
  );

  /// Tighter thresholds — for contexts where you want to catch distraction
  /// quickly (e.g. a proctored assessment). Uses the fastest allowed
  /// sampling rate (5s) so 3 confirmed samples (majority-of-3 once the
  /// window is full) = 15s of confirmed inattentiveness before the prompt
  /// fires. Multiple-persons fast-checks at the same 5s cadence, and (with
  /// the default [multiplePersonsConfirmCount] of 3) needs 3 consecutive
  /// multi-person frames (~15s) before `onMultiplePersonsDetected` fires.
  static final AttentivenessConfig strict = AttentivenessConfig(
    sampleInterval: minSampleInterval,
    multiplePersonsCheckInterval: minMultiplePersonsCheckInterval,
    maxHeadYawDegrees: 15,
    maxHeadPitchDegrees: 12,
    eyeOpenThreshold: 0.5,
    inattentiveWindowSize: 3,
    inattentiveConfirmCount: 3,
    ignoreRepeatConfirmCount: 3,
  );

  /// Tuned for `AttentivenessMonitor.externalSource` classroom usage where
  /// the host app pushes one frame every 15s (e.g. a periodic snapshot of
  /// the LiveKit local video tile fed via [pushFrame]).
  ///
  /// Both checks use the exact same rule, just on their own streak:
  /// 2 CONSECUTIVE pushed frames (15s apart = 30s total) of the same kind
  /// trigger the matching alert, and a frame of any other kind resets that
  /// streak back to zero:
  ///   - 2 consecutive distracted (looking away / eyes closed / no face)
  ///     frames -> `onBecameInattentive` (the "distracted" alert).
  ///   - 2 consecutive multiple-persons frames -> `onMultiplePersonsDetected`
  ///     (the "multiple persons" alert).
  ///   - A single attentive frame resets BOTH streaks to zero immediately —
  ///     i.e. if either of the last 2 frames was attentive, the learner is
  ///     considered attentive, full stop.
  /// [inattentiveWindowSize] is 1 (no extra smoothing) so this is exactly
  /// "2 in a row", nothing fuzzier.
  ///
  /// `AttentivenessMonitor` also re-fires either callback every further 2
  /// consecutive frames of that same kind (another 30s) for as long as it
  /// persists, and hasn't been dismissed via [markAttentive] /
  /// [ignoreInattentiveness] — so calling [showAttentivenessPrompt] from
  /// the callback replaces any prompt still on screen with a fresh one
  /// roughly every 30s instead of only firing once.
  static final AttentivenessConfig classroomFast = AttentivenessConfig(
    sampleInterval: const Duration(seconds: 15),
    multiplePersonsCheckInterval: minMultiplePersonsCheckInterval,
    inattentiveWindowSize: 1,
    inattentiveConfirmCount: 2,
    ignoreRepeatConfirmCount: 2,
    multiplePersonsConfirmCount: 2,
  );

  AttentivenessConfig copyWith({
    Duration? sampleInterval,
    Duration? multiplePersonsCheckInterval,
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
      multiplePersonsCheckInterval:
          multiplePersonsCheckInterval ?? this.multiplePersonsCheckInterval,
      maxHeadYawDegrees: maxHeadYawDegrees ?? this.maxHeadYawDegrees,
      maxHeadPitchDegrees: maxHeadPitchDegrees ?? this.maxHeadPitchDegrees,
      eyeOpenThreshold: eyeOpenThreshold ?? this.eyeOpenThreshold,
      enableMultiplePersonDetection:
          enableMultiplePersonDetection ?? this.enableMultiplePersonDetection,
      inattentiveWindowSize:
          inattentiveWindowSize ?? this.inattentiveWindowSize,
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

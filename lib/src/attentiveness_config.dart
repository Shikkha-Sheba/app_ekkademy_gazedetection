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
// HOW "MULTIPLE PERSONS" IS DECIDED (fast-check burst, decoupled from the
// cadence above):
//
// Waiting a full [sampleInterval] between checks is too slow to confirm a
// second face within ~15 seconds while still needing more than one frame of
// evidence (a single frame could be a hand, a poster, or a detector
// glitch). So the moment a raw frame comes back as
// `AttentivenessStatus.multiplePersonsDetected`, `AttentivenessService`
// temporarily switches its own sampling cadence from [sampleInterval] down
// to the much faster [multiplePersonsCheckInterval] (default 5s) for as
// long as the extra face keeps showing up. `AttentivenessMonitor` then
// applies the same time-based rule as before: it fires
// `onMultiplePersonsDetected` once the extra face has been continuously
// visible for [multiplePersonsGracePeriod] (default 15s). Because frames
// now arrive every 5s instead of every 10-15s during that burst, the 15s
// grace period is naturally confirmed by 3-4 frames instead of 1, without
// slowing down the alert. As soon as the frame drops back to a single face,
// the service falls back to the normal [sampleInterval] cadence.
//
// This burst is self-limiting: it only runs while a second face is
// actually in frame, so normal single-learner viewing still costs only
// ~3 processed frames every 30 seconds (with the defaults below), and even
// a sustained false-multi-person burst never exceeds ~6 frames per 30s
// (30s / 5s check interval).

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
  final int multiplePersonsWindowSize;

  /// Number of consecutive confirmed windows before firing.
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
  /// `onMultiplePersonsDetected` fires — i.e. the minimum time a second
  /// person has to stay in view before it counts as a real detection rather
  /// than a passer-by. Time-based rather than a sample count, but during
  /// this window `AttentivenessService` is itself sampling at the faster
  /// [multiplePersonsCheckInterval], so by default this is confirmed by
  /// several frames (not just one) while still firing within ~15 seconds.
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
  /// so it's confirmed by ~2 frames within its (longer, more forgiving) 20s
  /// grace period.
  static final AttentivenessConfig relaxed = AttentivenessConfig(
    sampleInterval: const Duration(seconds: 20),
    multiplePersonsCheckInterval: const Duration(seconds: 10),
    maxHeadYawDegrees: 35,
    maxHeadPitchDegrees: 28,
    eyeOpenThreshold: 0.3,
    inattentiveWindowSize: 3,
    inattentiveConfirmCount: 2,
    ignoreRepeatConfirmCount: 2,
    multiplePersonsGracePeriod: const Duration(seconds: 20),
  );

  /// Tighter thresholds — for contexts where you want to catch distraction
  /// quickly (e.g. a proctored assessment). Uses the fastest allowed
  /// sampling rate (5s) so 3 confirmed samples (majority-of-3 once the
  /// window is full) = 15s of confirmed inattentiveness before the prompt
  /// fires. Multiple-persons fast-checks at the same 5s cadence, so its
  /// 15s grace period is confirmed by 3-4 frames.
  static final AttentivenessConfig strict = AttentivenessConfig(
    sampleInterval: minSampleInterval,
    multiplePersonsCheckInterval: minMultiplePersonsCheckInterval,
    maxHeadYawDegrees: 15,
    maxHeadPitchDegrees: 12,
    eyeOpenThreshold: 0.5,
    inattentiveWindowSize: 3,
    inattentiveConfirmCount: 3,
    ignoreRepeatConfirmCount: 3,
    multiplePersonsGracePeriod: const Duration(seconds: 5),
  );

  /// Tuned for `AttentivenessMonitor.externalSource` classroom usage where
  /// the host app pushes one frame every 15s (e.g. a periodic snapshot of
  /// the LiveKit local video tile fed via [pushFrame]).
  ///
  /// [inattentiveWindowSize] is 1 — no smoothing window, each pushed frame
  /// is judged purely on its own raw classification. Combined with
  /// [inattentiveConfirmCount] = 2, that means: the learner must be
  /// raw-inattentive on 2 CONSECUTIVE pushed frames (15s apart = 30s total)
  /// before `onBecameInattentive` fires — a single bad frame (blink, brief
  /// glance) never triggers it, but two in a row does. A frame that comes
  /// back attentive resets the streak immediately.
  ///
  /// `AttentivenessMonitor` also re-fires `onBecameInattentive` every
  /// further 2 consecutive raw-inattentive frames (another 30s) for as long
  /// as the learner stays inattentive and hasn't tapped "Ignore" — so if you
  /// call [showAttentivenessPrompt] from that callback, a fresh prompt
  /// replaces any prompt still on screen every ~30s instead of only firing
  /// once.
  static final AttentivenessConfig classroomFast = AttentivenessConfig(
    sampleInterval: const Duration(seconds: 15),
    multiplePersonsCheckInterval: const Duration(seconds: 15),
    inattentiveWindowSize: 1,
    inattentiveConfirmCount: 2,
    ignoreRepeatConfirmCount: 2,
    multiplePersonsGracePeriod: const Duration(seconds: 15),
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

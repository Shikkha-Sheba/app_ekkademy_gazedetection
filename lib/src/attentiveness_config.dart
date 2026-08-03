// attentiveness_config.dart
//
// Tunable thresholds for the attentiveness engine, plus two ready-made
// presets (`relaxed` / `strict`). Pass a custom instance to
// `AttentivenessMonitor(config: ...)` if the presets don't fit your case.

class AttentivenessConfig {
  /// Minimum time between processed frames. Controls both CPU/battery cost
  /// and how "twitchy" detection feels. ~1.4 fps by default.
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

  /// How long a distracted state (looking away / eyes closed) must persist
  /// before `onBecameInattentive` fires.
  final Duration inattentiveGracePeriod;

  /// How long "no face in frame" must persist before `onFaceMissing` fires.
  final Duration faceMissingGracePeriod;

  /// How long "more than one face in frame" must persist before
  /// `onMultiplePersonsDetected` fires.
  final Duration multiplePersonsGracePeriod;

  /// Whether to play a looping alert sound while an inattentive/missing/
  /// multiple-persons state is active (stops automatically once resolved,
  /// or when you call `monitor.stopAlertSound()`).
  final bool enableSoundAlert;

  /// Asset path for the alert sound (e.g. `'assets/sounds/alert.mp3'`).
  /// Required if `enableSoundAlert` is true. Must be declared under
  /// `flutter: assets:` in the *consuming* app's pubspec, since Flutter
  /// packages don't bundle runtime assets for their dependents by default.
  final String? alertSoundAsset;

  const AttentivenessConfig({
    this.sampleInterval = const Duration(milliseconds: 700),
    this.maxHeadYawDegrees = 25,
    this.maxHeadPitchDegrees = 20,
    this.eyeOpenThreshold = 0.4,
    this.enableMultiplePersonDetection = true,
    this.inattentiveGracePeriod = const Duration(seconds: 4),
    this.faceMissingGracePeriod = const Duration(seconds: 4),
    this.multiplePersonsGracePeriod = const Duration(seconds: 3),
    this.enableSoundAlert = true,
    this.alertSoundAsset,
  });

  /// Looser thresholds and longer grace periods — good default for live
  /// classes or anywhere false positives (bad lighting, propped-up phone,
  /// glasses glare) would be disruptive.
  static const AttentivenessConfig relaxed = AttentivenessConfig(
    sampleInterval: Duration(milliseconds: 900),
    maxHeadYawDegrees: 35,
    maxHeadPitchDegrees: 28,
    eyeOpenThreshold: 0.3,
    inattentiveGracePeriod: Duration(seconds: 6),
    faceMissingGracePeriod: Duration(seconds: 6),
    multiplePersonsGracePeriod: Duration(seconds: 5),
  );

  /// Tighter thresholds and shorter grace periods — for contexts where you
  /// want to catch distraction quickly (e.g. a proctored assessment).
  static const AttentivenessConfig strict = AttentivenessConfig(
    sampleInterval: Duration(seconds: 5),
    maxHeadYawDegrees: 15,
    maxHeadPitchDegrees: 12,
    eyeOpenThreshold: 0.5,
    inattentiveGracePeriod: Duration(seconds: 30),
    faceMissingGracePeriod: Duration(seconds: 2),
    multiplePersonsGracePeriod: Duration(seconds: 10),
  );

  AttentivenessConfig copyWith({
    Duration? sampleInterval,
    double? maxHeadYawDegrees,
    double? maxHeadPitchDegrees,
    double? eyeOpenThreshold,
    bool? enableMultiplePersonDetection,
    Duration? inattentiveGracePeriod,
    Duration? faceMissingGracePeriod,
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
      inattentiveGracePeriod:
          inattentiveGracePeriod ?? this.inattentiveGracePeriod,
      faceMissingGracePeriod:
          faceMissingGracePeriod ?? this.faceMissingGracePeriod,
      multiplePersonsGracePeriod:
          multiplePersonsGracePeriod ?? this.multiplePersonsGracePeriod,
      enableSoundAlert: enableSoundAlert ?? this.enableSoundAlert,
      alertSoundAsset: alertSoundAsset ?? this.alertSoundAsset,
    );
  }
}

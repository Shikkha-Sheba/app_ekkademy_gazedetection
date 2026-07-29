// attentiveness_models.dart
//
// Standalone data models for the attentiveness-detection module.
// No dependency on the video player — usable from any screen.

/// The instantaneous state derived from a single camera frame.
enum AttentivenessStatus {
  /// Face detected, looking at the screen, eyes open.
  attentive,

  /// Face detected but head turned away beyond the yaw/pitch threshold.
  lookingLeft,
  lookingRight,

  /// Face detected but both eyes below the "open" probability threshold.
  eyesClosed,

  /// No face found in frame at all (left the room, camera blocked, etc).
  faceNotDetected,

  /// More than one face found in frame — someone else is with the learner,
  /// or looking over their shoulder. This is checked before the single-face
  /// statuses above, so it always takes priority over them.
  multiplePersonsDetected,

  /// Camera/permission not ready yet, or monitor not started.
  unknown,
}

/// Result of analysing a single camera frame.
class AttentivenessResult {
  final AttentivenessStatus status;

  /// Number of faces found in this frame. 0 when [AttentivenessStatus.faceNotDetected],
  /// 1 in the normal case, 2+ when [AttentivenessStatus.multiplePersonsDetected].
  final int faceCount;

  /// Head rotation left/right in degrees (yaw), for the primary (largest)
  /// face in frame. Positive/negative = turned away from center. Null if
  /// no face was found.
  final double? headEulerY;

  /// Head rotation up/down in degrees (pitch), for the primary face. Null
  /// if no face was found.
  final double? headEulerX;

  final double? leftEyeOpenProbability;
  final double? rightEyeOpenProbability;

  final DateTime timestamp;

  const AttentivenessResult({
    required this.status,
    required this.timestamp,
    this.faceCount = 0,
    this.headEulerY,
    this.headEulerX,
    this.leftEyeOpenProbability,
    this.rightEyeOpenProbability,
  });

  bool get isAttentive => status == AttentivenessStatus.attentive;

  bool get hasMultiplePersons =>
      status == AttentivenessStatus.multiplePersonsDetected;

  @override
  String toString() =>
      'AttentivenessResult(status: $status, faceCount: $faceCount, '
      'yaw: $headEulerY, pitch: $headEulerX, '
      'leftEye: $leftEyeOpenProbability, rightEye: $rightEyeOpenProbability)';
}

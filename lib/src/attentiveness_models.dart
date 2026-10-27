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

/// Detected emotion or facial expression derived from face probabilities.
enum FaceEmotion {
  /// High smiling probability (smile / happy).
  happy,

  /// Low smiling probability and reduced eye openness or sad facial traits.
  sad,

  /// High eye openness and wide eyes.
  surprised,

  /// One eye open, one eye closed.
  wink,

  /// Both eyes closed.
  eyesClosed,

  /// Normal, relaxed expression.
  neutral,

  /// Expression could not be determined or no face detected.
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

  /// Probability that the face is smiling (0.0 to 1.0). Null if not computed.
  final double? smilingProbability;

  /// The facial expression / emotion detected from the face probabilities.
  final FaceEmotion emotion;

  final DateTime timestamp;

  const AttentivenessResult({
    required this.status,
    required this.timestamp,
    this.faceCount = 0,
    this.headEulerY,
    this.headEulerX,
    this.leftEyeOpenProbability,
    this.rightEyeOpenProbability,
    this.smilingProbability,
    this.emotion = FaceEmotion.unknown,
  });

  /// Derives [FaceEmotion] based on smiling probability and eye probabilities.
  static FaceEmotion computeEmotion({
    required double? smilingProbability,
    required double? leftEyeOpenProbability,
    required double? rightEyeOpenProbability,
    double smileThreshold = 0.55,
    bool faceDetected = true,
  }) {
    if (!faceDetected) return FaceEmotion.unknown;

    final smile = smilingProbability ?? 0.0;
    final leftEye = leftEyeOpenProbability ?? 1.0;
    final rightEye = rightEyeOpenProbability ?? 1.0;

    if (smilingProbability != null && smile >= smileThreshold) {
      return FaceEmotion.happy;
    }

    final isLeftClosed = leftEyeOpenProbability != null && leftEye < 0.25;
    final isRightClosed = rightEyeOpenProbability != null && rightEye < 0.25;
    final isLeftOpen = leftEyeOpenProbability != null && leftEye > 0.6;
    final isRightOpen = rightEyeOpenProbability != null && rightEye > 0.6;

    if ((isLeftClosed && isRightOpen) || (isRightClosed && isLeftOpen)) {
      return FaceEmotion.wink;
    }

    if (isLeftClosed && isRightClosed) {
      return FaceEmotion.eyesClosed;
    }

    if (leftEye >= 0.85 && rightEye >= 0.85 && smile < 0.4) {
      return FaceEmotion.surprised;
    }

    if (smilingProbability != null && smile < 0.1 && leftEye < 0.5 && rightEye < 0.5) {
      return FaceEmotion.sad;
    }

    return FaceEmotion.neutral;
  }

  bool get isAttentive => status == AttentivenessStatus.attentive;

  bool get hasMultiplePersons =>
      status == AttentivenessStatus.multiplePersonsDetected;

  @override
  String toString() =>
      'AttentivenessResult(status: $status, faceCount: $faceCount, '
      'yaw: $headEulerY, pitch: $headEulerX, '
      'leftEye: $leftEyeOpenProbability, rightEye: $rightEyeOpenProbability, '
      'smiling: $smilingProbability, emotion: $emotion)';
}

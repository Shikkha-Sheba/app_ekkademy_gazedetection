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

/// Detected facial emotion derived from face probabilities and head pose.
enum FaceEmotion {
  /// Face showing downward head pitch, narrowed eyes, or low smile.
  angry,

  /// Face showing high smile probability.
  happy,

  /// Normal, relaxed face expression.
  neutral,

  /// Wide open eyes (high eye-open probability) and raised head pitch.
  surprised,

  /// Head tilted (yaw/roll angle) with asymmetric eyes or low smile.
  confused,

  /// Model class "disgust". Only produced by the TFLite model.
  disgusted,

  /// Model class "fear". Only produced by the TFLite model.
  fearful,

  /// Model class "sad". Only produced by the TFLite model.
  sad,

  /// Emotion could not be computed, no face detected, or the model's top
  /// score was below `AttentivenessConfig.emotionMinConfidence`.
  unknown;
}

/// Alias for facial expression type.
typedef ExpressionType = FaceEmotion;

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

  /// Head rotation relative to camera plane in degrees (roll). Null if no face.
  final double? headEulerZ;

  final double? leftEyeOpenProbability;
  final double? rightEyeOpenProbability;

  /// Probability that the face is smiling (0.0 to 1.0). Null if not computed.
  final double? smilingProbability;

  /// The facial emotion detected from face probabilities and head angles.
  final FaceEmotion emotion;

  /// Model score (0.0-1.0) of [emotion]. Null when no TFLite model is
  /// configured (smile-only fallback) or no face was found.
  final double? emotionConfidence;

  /// Alias for [emotion] as expression type.
  ExpressionType get expression => emotion;

  final DateTime timestamp;

  const AttentivenessResult({
    required this.status,
    required this.timestamp,
    this.faceCount = 0,
    this.headEulerY,
    this.headEulerX,
    this.headEulerZ,
    this.leftEyeOpenProbability,
    this.rightEyeOpenProbability,
    this.smilingProbability,
    this.emotion = FaceEmotion.unknown,
    this.emotionConfidence,
  });

  /// Derives [FaceEmotion] based on facial features, probabilities, and head angles.
  static FaceEmotion computeEmotion({
    required double? smilingProbability,
    required double? leftEyeOpenProbability,
    required double? rightEyeOpenProbability,
    double? headEulerX,
    double? headEulerY,
    double? headEulerZ,
    double smileThreshold = 0.55,
    bool faceDetected = true,
  }) {
    if (!faceDetected) return FaceEmotion.unknown;

    final smile = smilingProbability ?? 0.0;
    final leftEye = leftEyeOpenProbability ?? 1.0;
    final rightEye = rightEyeOpenProbability ?? 1.0;
    final pitch = headEulerX ?? 0.0;
    final yaw = (headEulerY ?? 0.0).abs();
    final roll = (headEulerZ ?? 0.0).abs();

    if (smilingProbability != null && smile >= smileThreshold) {
      return FaceEmotion.happy;
    }

    if (leftEye >= 0.85 && rightEye >= 0.85 && smile < 0.35 && pitch > 5) {
      return FaceEmotion.surprised;
    }

    final eyeDiff = (leftEye - rightEye).abs();
    if ((roll > 10 || yaw > 12) && smile < 0.3 && (eyeDiff > 0.15 || pitch.abs() > 8)) {
      return FaceEmotion.confused;
    }

    if ((pitch < -10 || (leftEye < 0.5 && rightEye < 0.5)) && smile < 0.15) {
      return FaceEmotion.angry;
    }

    return FaceEmotion.neutral;
  }

  /// Alias for [computeEmotion].
  static ExpressionType computeExpression({
    required double? smilingProbability,
    required double? leftEyeOpenProbability,
    required double? rightEyeOpenProbability,
    double? headEulerX,
    double? headEulerY,
    double? headEulerZ,
    double smileThreshold = 0.55,
    bool faceDetected = true,
  }) =>
      computeEmotion(
        smilingProbability: smilingProbability,
        leftEyeOpenProbability: leftEyeOpenProbability,
        rightEyeOpenProbability: rightEyeOpenProbability,
        headEulerX: headEulerX,
        headEulerY: headEulerY,
        headEulerZ: headEulerZ,
        smileThreshold: smileThreshold,
        faceDetected: faceDetected,
      );

  bool get isAttentive => status == AttentivenessStatus.attentive;

  bool get hasMultiplePersons =>
      status == AttentivenessStatus.multiplePersonsDetected;

  @override
  String toString() =>
      'AttentivenessResult(status: $status, faceCount: $faceCount, '
      'yaw: $headEulerY, pitch: $headEulerX, roll: $headEulerZ, '
      'leftEye: $leftEyeOpenProbability, rightEye: $rightEyeOpenProbability, '
      'smiling: $smilingProbability, emotion: $emotion, '
      'emotionConfidence: $emotionConfidence)';
}

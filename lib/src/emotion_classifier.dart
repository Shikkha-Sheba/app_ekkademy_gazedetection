// emotion_classifier.dart
//
// On-device TFLite emotion classifier. Expects a FER-style model with a
// single image input ([1, H, W, 1] or [1, H, W, 3]) and a [1, N] class
// output, N == AttentivenessConfig.emotionLabels.length.
//
// The default model (mini_XCEPTION, FER2013) ships inside this package at
// assets/models/emotion.tflite. A custom model can be used by declaring it
// in the consuming app and passing its path via
// AttentivenessConfig.emotionModelAsset.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'attentiveness_models.dart';

/// Result of classifying one face crop.
class EmotionPrediction {
  /// Top class, or [FaceEmotion.unknown] if its score was below the
  /// configured minimum confidence.
  final FaceEmotion emotion;

  /// Score (0.0-1.0) of the top class.
  final double confidence;

  /// Full per-class score distribution.
  final Map<FaceEmotion, double> scores;

  const EmotionPrediction({
    required this.emotion,
    required this.confidence,
    this.scores = const {},
  });

  static const EmotionPrediction unknown = EmotionPrediction(
    emotion: FaceEmotion.unknown,
    confidence: 0,
  );

  @override
  String toString() =>
      'EmotionPrediction($emotion, ${confidence.toStringAsFixed(2)})';
}

class TfliteEmotionClassifier {
  final String assetPath;
  final List<FaceEmotion> labels;
  final double inputMean;
  final double inputStd;
  final double minConfidence;
  final int threads;

  Interpreter? _interpreter;
  int _inputH = 48;
  int _inputW = 48;
  int _inputC = 1;

  TfliteEmotionClassifier({
    required this.assetPath,
    required this.labels,
    this.inputMean = 0,
    this.inputStd = 255,
    this.minConfidence = 0.4,
    this.threads = 2,
  });

  bool get isLoaded => _interpreter != null;

  /// Square input size the model expects (read from the model after [load]).
  int get inputSize => _inputH;

  /// Loads the model. Throws [StateError] if its input/output shapes don't
  /// fit (non-square input, or class count != labels.length).
  Future<void> load() async {
    if (_interpreter != null) return;
    final options = InterpreterOptions()..threads = threads;
    // Load the bytes through rootBundle so both app assets
    // ('assets/x.tflite') and package assets
    // ('packages/<pkg>/assets/x.tflite') resolve the same way.
    final data = await rootBundle.load(assetPath);
    final interpreter = Interpreter.fromBuffer(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      options: options,
    );

    final inShape = interpreter.getInputTensor(0).shape;
    final outShape = interpreter.getOutputTensor(0).shape;
    if (inShape.length != 4 || inShape[1] != inShape[2]) {
      interpreter.close();
      throw StateError('Unsupported emotion model input shape: $inShape');
    }
    if (outShape.last != labels.length) {
      interpreter.close();
      throw StateError(
        'Emotion model outputs ${outShape.last} classes but '
        '${labels.length} labels were configured.',
      );
    }
    _inputH = inShape[1];
    _inputW = inShape[2];
    _inputC = inShape[3];
    _interpreter = interpreter;
  }

  /// [gray] is an [inputSize] x [inputSize] grayscale crop, values 0-255.
  EmotionPrediction classify(Float32List gray) {
    final interpreter = _interpreter;
    if (interpreter == null || gray.length != _inputH * _inputW) {
      return EmotionPrediction.unknown;
    }

    final input = Float32List(_inputH * _inputW * _inputC);
    for (var i = 0; i < gray.length; i++) {
      final v = (gray[i] - inputMean) / inputStd;
      for (var c = 0; c < _inputC; c++) {
        input[i * _inputC + c] = v;
      }
    }

    final output = [List<double>.filled(labels.length, 0.0)];
    interpreter.run(input.reshape([1, _inputH, _inputW, _inputC]), output);

    final probs = _normalize(output[0]);
    var best = 0;
    for (var i = 1; i < probs.length; i++) {
      if (probs[i] > probs[best]) best = i;
    }
    final confidence = probs[best];
    return EmotionPrediction(
      emotion: confidence >= minConfidence ? labels[best] : FaceEmotion.unknown,
      confidence: confidence,
      scores: {for (var i = 0; i < labels.length; i++) labels[i]: probs[i]},
    );
  }

  /// Applies softmax only if the model returned logits instead of
  /// probabilities.
  static List<double> _normalize(List<double> raw) {
    final sum = raw.fold<double>(0, (a, b) => a + b);
    final isProb = raw.every((v) => v >= 0 && v <= 1) && (sum - 1).abs() < 0.02;
    if (isProb) return raw;
    final maxV = raw.reduce(math.max);
    final exps = raw.map((v) => math.exp(v - maxV)).toList();
    final total = exps.fold<double>(0, (a, b) => a + b);
    return exps.map((e) => e / total).toList();
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
  }
}

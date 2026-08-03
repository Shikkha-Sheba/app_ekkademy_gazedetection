// attentiveness_service.dart
//
// Low-level engine: owns the front camera and the ML Kit face detector,
// turns raw camera frames into AttentivenessResult events on a stream.
//
// You normally don't use this directly — use AttentivenessMonitor instead,
// which adds debouncing/grace-period rules on top. This class is exposed
// in case you want to build your own rules engine.
//
// PLATFORM SETUP:
//   - iOS: add NSCameraUsageDescription to Info.plist.
//   - Android: add CAMERA permission to AndroidManifest.xml (camera plugin's
//     example shows the exact block); minSdkVersion 21+ for ML Kit.

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

import 'attentiveness_config.dart';
import 'attentiveness_models.dart';

class AttentivenessService {
  final AttentivenessConfig config;

  /// True when this instance owns its own camera (the default [start] path).
  /// False when frames arrive externally via [pushFrame] — e.g. a snapshot
  /// of a LiveKit local video renderer, when something else (a video call
  /// SDK) already holds the camera and a second capture session would
  /// throw CAMERA_IN_USE.
  final bool _ownsCamera;

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  bool _isProcessing = false;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  bool _externalRunning = false;

  final StreamController<AttentivenessResult> _controller =
      StreamController<AttentivenessResult>.broadcast();

  /// Stream of analysed results, throttled by [AttentivenessConfig.sampleInterval].
  Stream<AttentivenessResult> get results => _controller.stream;

  bool get isRunning =>
      _ownsCamera ? _cameraController != null : _externalRunning;

  AttentivenessService({AttentivenessConfig? config})
    : config = config ?? AttentivenessConfig(),
      _ownsCamera = true;

  /// Use when the camera is already owned by someone else (e.g. LiveKit's
  /// native camera capturer). No CameraController is created here — feed
  /// frames yourself via [pushFrame].
  AttentivenessService.externalSource({AttentivenessConfig? config})
    : config = config ?? AttentivenessConfig(),
      _ownsCamera = false;

  //Logger for debugging purposes
  Timer? _logTimer;
  int _elapsedSeconds = 0;

  void _startLogging() {
    _elapsedSeconds = 0;
    _logTimer?.cancel();
    _logTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds++;
      print(
        '\n===================================================================',
      );
      print(
        '\n================⏱️ Running: ${_elapsedSeconds}s===================',
      );
      print(
        '\n===================================================================',
      );
    });
  }

  /// Starts the face detector for external-frame mode. Does not touch the
  /// camera at all — call [pushFrame] to feed it frames.
  Future<void> startExternal() async {
    _startLogging();
    if (_ownsCamera) {
      throw StateError('Use start() for the camera-owning instance.');
    }
    if (_externalRunning) return;
    print("startExternal service called");
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableTracking: false,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    _externalRunning = true;
  }

  /// Feed one externally-captured frame (already throttled by the caller —
  /// this does NOT re-throttle by [AttentivenessConfig.sampleInterval],
  /// since the caller controls the capture cadence).
  Future<void> pushFrame(InputImage inputImage) async {
    if (!_externalRunning || _faceDetector == null || _isProcessing) return;
    _isProcessing = true;
    try {
      final stopwatch = Stopwatch()..start();
      final faces = await _faceDetector!.processImage(inputImage);
      stopwatch.stop();
      print(
        '📷 Image processed | Running: ${_elapsedSeconds}s | '
        'Faces: ${faces.length} | Processing: ${stopwatch.elapsedMilliseconds} ms',
      );
      if (!_controller.isClosed) _controller.add(_interpret(faces));
    } on Exception catch (e) {
      throw StateError('AttentivenessService.pushFrame error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Requests camera permission, opens the front camera, and begins
  /// streaming analysed frames. Throws a [StateError] if permission is
  /// denied or no front camera is available.
  Future<void> start() async {
    _startLogging();
    if (!_ownsCamera) {
      throw StateError(
        'This instance uses externalSource() — call startExternal() instead.',
      );
    }
    if (isRunning) return;

    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      throw StateError('Camera permission was not granted.');
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available on this device.');
    }
    final frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await _cameraController!.initialize();

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true, // gives eye-open probabilities
        enableTracking: false,
        performanceMode: FaceDetectorMode.fast,
      ),
    );

    await _cameraController!.startImageStream(_onFrame);
  }

  void _onFrame(CameraImage image) {
    final now = DateTime.now();
    if (_isProcessing || now.difference(_lastEmit) < config.sampleInterval) {
      return;
    }
    _isProcessing = true;
    _lastEmit = now;
    _process(image).whenComplete(() => _isProcessing = false);
  }

  Future<void> _process(CameraImage image) async {
    try {
      final inputImage = _toInputImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetector!.processImage(inputImage);
      if (_controller.isClosed) return;
      _controller.add(_interpret(faces));
    } on Exception catch (e) {
      throw StateError('AttentivenessService._process error: $e');
    }
  }

  AttentivenessResult _interpret(List<Face> faces) {
    final now = DateTime.now();

    if (faces.isEmpty) {
      return AttentivenessResult(
        status: AttentivenessStatus.faceNotDetected,
        timestamp: now,
        faceCount: 0,
      );
    }

    // Largest face in frame = the primary viewer. We sort regardless of
    // face count so the "primary" face's angles/eye data are available
    // even when multiple people are in frame.
    faces.sort(
      (a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(
        a.boundingBox.width * a.boundingBox.height,
      ),
    );
    final face = faces.first;

    final yaw = face.headEulerAngleY ?? 0;
    final pitch = face.headEulerAngleX ?? 0;
    final leftEye = face.leftEyeOpenProbability;
    final rightEye = face.rightEyeOpenProbability;

    // More than one face in frame — someone else is with the learner, or
    // looking over their shoulder. This takes priority over the single-face
    // checks below (looking away / eyes closed don't matter if there are
    // two people in frame either way).
    if (config.enableMultiplePersonDetection && faces.length > 1) {
      return AttentivenessResult(
        status: AttentivenessStatus.multiplePersonsDetected,
        headEulerY: yaw,
        headEulerX: pitch,
        leftEyeOpenProbability: leftEye,
        rightEyeOpenProbability: rightEye,
        faceCount: faces.length,
        timestamp: now,
      );
    }

    final lookingAway =
        yaw.abs() > config.maxHeadYawDegrees ||
        pitch.abs() > config.maxHeadPitchDegrees;

    final eyesClosed =
        leftEye != null &&
        rightEye != null &&
        leftEye < config.eyeOpenThreshold &&
        rightEye < config.eyeOpenThreshold;

    AttentivenessStatus status;
    if (lookingAway) {
      status = yaw > 0
          ? AttentivenessStatus.lookingLeft
          : AttentivenessStatus.lookingRight;
    } else if (eyesClosed) {
      status = AttentivenessStatus.eyesClosed;
    } else {
      status = AttentivenessStatus.attentive;
    }

    return AttentivenessResult(
      status: status,
      headEulerY: yaw,
      headEulerX: pitch,
      leftEyeOpenProbability: leftEye,
      rightEyeOpenProbability: rightEye,
      faceCount: faces.length,
      timestamp: now,
    );
  }

  /// Converts a raw [CameraImage] into the format ML Kit expects.
  /// Handles the Android (NV21) vs iOS (BGRA8888) split and applies the
  /// sensor rotation so face angles are computed correctly in either
  /// portrait or landscape.
  InputImage? _toInputImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) return null;

    final rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
        InputImageRotation.rotation0deg;

    final format = Platform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormat.bgra8888;

    // Both formats supported here are delivered as a single contiguous
    // plane by the `camera` plugin when imageFormatGroup is set above.
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> stop() async {
    _logTimer?.cancel();
    _logTimer = null;
    if (!_ownsCamera) {
      await _faceDetector?.close();
      _faceDetector = null;
      _externalRunning = false;
      return;
    }
    try {
      if (_cameraController?.value.isStreamingImages ?? false) {
        await _cameraController?.stopImageStream();
      }
    } on Exception catch (e, st) {
      print('AttentivenessService.stop error: $e\n$st');
    }
    await _cameraController?.dispose();
    await _faceDetector?.close();
    _cameraController = null;
    _faceDetector = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

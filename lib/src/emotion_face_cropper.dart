// emotion_face_cropper.dart
//
// Crops the primary face out of a raw camera frame and resamples it to a
// small grayscale tensor for the emotion model. Works directly on the raw
// NV21 / YV12 / BGRA8888 bytes of an ML Kit [InputImage], so no extra image
// decoding package is needed.
//
// ML Kit returns bounding boxes in the UPRIGHT (rotation-corrected)
// coordinate space, while the raw buffer is in sensor orientation, so every
// sampled pixel is mapped back through the frame rotation.

import 'dart:typed_data';
import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class EmotionFaceCropper {
  EmotionFaceCropper._();

  /// Returns a [size] x [size] grayscale crop of [faceBox], values in 0-255
  /// (row-major), or null if the frame format is unsupported / invalid.
  ///
  /// [padding] expands the box by that fraction on every side (0.1 = 10%).
  static Float32List? cropGray({
    required InputImage image,
    required Rect faceBox,
    required int size,
    double padding = 0.1,
  }) {
    final bytes = image.bytes;
    final meta = image.metadata;
    if (bytes == null || meta == null) return null;

    final format = meta.format;
    final isLuma = format == InputImageFormat.nv21 ||
        format == InputImageFormat.yv12;
    final isBgra = format == InputImageFormat.bgra8888;
    if (!isLuma && !isBgra) return null;

    final w = meta.size.width.toInt();
    final h = meta.size.height.toInt();
    final stride = meta.bytesPerRow > 0 ? meta.bytesPerRow : (isBgra ? w * 4 : w);
    final rotation = meta.rotation.rawValue;

    final swap = rotation == 90 || rotation == 270;
    final uw = swap ? h : w; // upright width
    final uh = swap ? w : h; // upright height

    final padX = faceBox.width * padding;
    final padY = faceBox.height * padding;
    final left = (faceBox.left - padX).clamp(0.0, uw - 1.0);
    final top = (faceBox.top - padY).clamp(0.0, uh - 1.0);
    final right = (faceBox.right + padX).clamp(0.0, uw.toDouble());
    final bottom = (faceBox.bottom + padY).clamp(0.0, uh.toDouble());
    final boxW = right - left;
    final boxH = bottom - top;
    if (boxW < 8 || boxH < 8) return null;

    final out = Float32List(size * size);

    // Reads the luma of the raw pixel that maps to upright (x, y).
    double lumaAt(int x, int y) {
      final ux = x.clamp(0, uw - 1).toInt();
      final uy = y.clamp(0, uh - 1).toInt();
      int rx;
      int ry;
      switch (rotation) {
        case 90:
          rx = uy;
          ry = h - 1 - ux;
          break;
        case 180:
          rx = w - 1 - ux;
          ry = h - 1 - uy;
          break;
        case 270:
          rx = w - 1 - uy;
          ry = ux;
          break;
        default:
          rx = ux;
          ry = uy;
      }
      if (isLuma) {
        final i = ry * stride + rx;
        return i < bytes.length ? bytes[i].toDouble() : 0.0;
      }
      final i = ry * stride + rx * 4;
      if (i + 2 >= bytes.length) return 0.0;
      // BGRA byte order.
      return 0.114 * bytes[i] + 0.587 * bytes[i + 1] + 0.299 * bytes[i + 2];
    }

    // 2x2 supersampling per output pixel to limit aliasing when shrinking.
    final stepX = boxW / size;
    final stepY = boxH / size;
    for (var oy = 0; oy < size; oy++) {
      for (var ox = 0; ox < size; ox++) {
        final x0 = left + ox * stepX;
        final y0 = top + oy * stepY;
        final v = (lumaAt((x0 + stepX * 0.25).floor(), (y0 + stepY * 0.25).floor()) +
                lumaAt((x0 + stepX * 0.75).floor(), (y0 + stepY * 0.25).floor()) +
                lumaAt((x0 + stepX * 0.25).floor(), (y0 + stepY * 0.75).floor()) +
                lumaAt((x0 + stepX * 0.75).floor(), (y0 + stepY * 0.75).floor())) /
            4.0;
        out[oy * size + ox] = v;
      }
    }
    return out;
  }
}

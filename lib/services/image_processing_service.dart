import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'inference_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ImageProcessingService
//
// Pipeline PCD untuk meningkatkan akurasi deteksi jamur (indoor mold):
//
//   RAW frame (320×320 RGB)
//     │
//     ▼
//   [1] Laplacian Sharpening   → mempertegas tepi spora & tekstur koloni
//     │
//     ▼
//   [2] HSV Color Isolation    → isolasi pigmentasi jamur dari warna cat/dinding
//     │
//     ▼
//   [3] CLAHE-like Contrast    → normalisasi kontras area gelap (sudut lembap)
//     │
//     ▼
//   [4] Gaussian Blur (lite)   → kurangi noise kamera sebelum inference
//     │
//     ▼
//   [5] Normalize [0.0, 1.0]  → input tensor untuk YOLOv8
//
// Semua tahap berjalan di background isolate via compute().
// ─────────────────────────────────────────────────────────────────────────────

class ImageProcessingService {
  // ── Public entry point ──────────────────────────────────────────────────────

  /// Jalankan full PCD pipeline di background isolate.
  /// Input: [img.Image] ukuran 320×320 (sudah di-downsample dari YUV).
  /// ✅ NEW: [pcdSettings] untuk customize pipeline parameters
  /// Output: Float32List siap jadi input tensor [1, 320, 320, 3].
  static Future<List<List<List<List<double>>>>> processForInference(
    img.Image image, [
    PcdSettings pcdSettings = const PcdSettings(),
  ]) async {
    final bytes = image.getBytes(order: img.ChannelOrder.rgb);

    final result = await compute(_pipelineIsolate, {
      'bytes': bytes,
      'width': image.width,
      'height': image.height,
      'sharpening': pcdSettings.sharpening,
      'colorBoost': pcdSettings.colorBoost,
      'contrast': pcdSettings.contrast,
      'blur': pcdSettings.blur,
    });

    return result;
  }

  /// YUV camera frame + full PCD pipeline in one single isolate to minimize lag.
  static Future<List<List<List<List<double>>>>> processCameraFrameForInference({
    required int width,
    required int height,
    required int targetSize,
    required Uint8List yPlane,
    required Uint8List uPlane,
    required Uint8List vPlane,
    required int uvRowStride,
    required int uvPixelStride,
    required int sensorOrientation,
    required PcdSettings pcdSettings,
  }) async {
    return await compute(_cameraFramePipelineIsolate, {
      'width': width,
      'height': height,
      'targetSize': targetSize,
      'yPlane': yPlane,
      'uPlane': uPlane,
      'vPlane': vPlane,
      'uvRowStride': uvRowStride,
      'uvPixelStride': uvPixelStride,
      'sensorOrientation': sensorOrientation,
      'sharpening': pcdSettings.sharpening,
      'colorBoost': pcdSettings.colorBoost,
      'contrast': pcdSettings.contrast,
      'blur': pcdSettings.blur,
    });
  }

  static List<List<List<List<double>>>> _cameraFramePipelineIsolate(
      Map<String, dynamic> args) {
    final int width = args['width'];
    final int height = args['height'];
    final int target = args['targetSize'];
    final Uint8List yPlane = args['yPlane'];
    final Uint8List uPlane = args['uPlane'];
    final Uint8List vPlane = args['vPlane'];
    final int uvRowStride = args['uvRowStride'];
    final int uvPixelStride = args['uvPixelStride'];
    final int sensorOrientation = args['sensorOrientation'];

    final double sharpening = args['sharpening'] ?? 0.5;
    final double colorBoost = args['colorBoost'] ?? 1.4;
    final double contrast = args['contrast'] ?? 2.5;
    final double blur = args['blur'] ?? 0.8;

    final pixels = _yuvToDoublePixels(
      width: width,
      height: height,
      target: target,
      yPlane: yPlane,
      uPlane: uPlane,
      vPlane: vPlane,
      uvRowStride: uvRowStride,
      uvPixelStride: uvPixelStride,
      sensorOrientation: sensorOrientation,
    );

    var processed = _laplacianSharpening(pixels, target, target, strength: sharpening);
    processed = _hsvMoldBoost(processed, target, target, colorBoost: colorBoost);
    processed = _adaptiveContrast(processed, target, target, tileSize: 8, clipLimit: contrast);
    processed = _gaussianBlur3x3(processed, target, target, sigma: blur);

    return _toModelInput(processed, target, target);
  }

  static List<List<List<double>>> _yuvToDoublePixels({
    required int width,
    required int height,
    required int target,
    required Uint8List yPlane,
    required Uint8List uPlane,
    required Uint8List vPlane,
    required int uvRowStride,
    required int uvPixelStride,
    required int sensorOrientation,
  }) {
    final pixels = List.generate(
      target,
      (_) => List.generate(target, (_) => List<double>.filled(3, 0.0)),
    );

    final bool isRotated = sensorOrientation == 90 || sensorOrientation == 270;
    final double xStep = (isRotated ? height : width) / target;
    final double yStep = (isRotated ? width : height) / target;

    debugPrint('🔍 sensorOrientation=$sensorOrientation, srcW=$width, srcH=$height, '
    'xStep=${(isRotated ? height : width) / target}, '
    'yStep=${(isRotated ? width : height) / target}');

    for (int ty = 0; ty < target; ty++) {
      for (int tx = 0; tx < target; tx++) {
        int srcX = 0;
        int srcY = 0;

        if (sensorOrientation == 90) {
          // Counteract 90 deg sensor tilt -> rotate 270 deg clockwise (90 deg counter-clockwise)
          srcX = ((target - 1 - ty) * xStep).floor().clamp(0, width - 1);
          srcY = (tx * yStep).floor().clamp(0, height - 1);
        } else if (sensorOrientation == 270) {
          // Counteract 270 deg sensor tilt -> rotate 90 deg clockwise
          srcX = (ty * xStep).floor().clamp(0, width - 1);
          srcY = ((target - 1 - tx) * yStep).floor().clamp(0, height - 1);
        } else if (sensorOrientation == 180) {
          srcX = ((target - 1 - tx) * xStep).floor().clamp(0, width - 1);
          srcY = ((target - 1 - ty) * yStep).floor().clamp(0, height - 1);
        } else {
          srcX = (tx * xStep).floor().clamp(0, width - 1);
          srcY = (ty * yStep).floor().clamp(0, height - 1);
        }

        final int yVal = yPlane[srcY * width + srcX] & 0xFF;
        final int uvIndex =
            uvPixelStride * (srcX ~/ 2) + uvRowStride * (srcY ~/ 2);

        double r, g, b;
        if (uvIndex >= 0 && uvIndex < uPlane.length && uvIndex < vPlane.length) {
          final int uVal = (uPlane[uvIndex] & 0xFF) - 128;
          final int vVal = (vPlane[uvIndex] & 0xFF) - 128;

          r = (yVal + 1.402 * vVal).clamp(0, 255).toDouble();
          g = (yVal - 0.344136 * uVal - 0.714136 * vVal).clamp(0, 255).toDouble();
          b = (yVal + 1.772 * uVal).clamp(0, 255).toDouble();
        } else {
          r = yVal.toDouble();
          g = yVal.toDouble();
          b = yVal.toDouble();
        }

        pixels[ty][tx][0] = r;
        pixels[ty][tx][1] = g;
        pixels[ty][tx][2] = b;
      }
    }

    return pixels;
  }

  // ── Isolate entry (top-level dipanggil compute) ──────────────────────────────

  static List<List<List<List<double>>>> _pipelineIsolate(
      Map<String, dynamic> args) {
    final Uint8List bytes = args['bytes'];
    final int width = args['width'];
    final int height = args['height'];
    
    // ✅ NEW: Load settings dari args
    final double sharpening = args['sharpening'] ?? 0.5;
    final double colorBoost = args['colorBoost'] ?? 1.4;
    final double contrast = args['contrast'] ?? 2.5;
    final double blur = args['blur'] ?? 0.8;

    debugPrint('📊 PCD Pipeline started with settings:');
    debugPrint('   sharpening: $sharpening');
    debugPrint('   colorBoost: $colorBoost');
    debugPrint('   contrast: $contrast');
    debugPrint('   blur: $blur');

    // Buat buffer kerja — kita pakai double precision untuk akurasi filter
    var pixels = _bytesToDouble(bytes, width, height); // [H][W][3]

    // ── Tahap 1: Laplacian Sharpening ──────────────────────────────────────
    // ✅ MODIFIED: Use configurable strength
    pixels = _laplacianSharpening(pixels, width, height, strength: sharpening);

    // ── Tahap 2: HSV Color Isolation ───────────────────────────────────────
    // ✅ MODIFIED: Use configurable colorBoost
    pixels = _hsvMoldBoost(pixels, width, height, colorBoost: colorBoost);

    // ── Tahap 3: CLAHE-like Adaptive Contrast ──────────────────────────────
    // ✅ MODIFIED: Use configurable contrast (clip limit)
    pixels = _adaptiveContrast(pixels, width, height,
        tileSize: 8, clipLimit: contrast);

    // ── Tahap 4: Gaussian Blur ───────────────────────────────────────────────
    // ✅ MODIFIED: Use configurable sigma
    pixels = _gaussianBlur3x3(pixels, width, height, sigma: blur);

    // ── Tahap 5: Normalize ke [0.0, 1.0] ───────────────────────────────────
    return _toModelInput(pixels, width, height);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tahap 1 — Laplacian Sharpening
// ─────────────────────────────────────────────────────────────────────────────

/// ✅ MODIFIED: Kernel: [0,-1,0 / -1,5,-1 / 0,-1,0]
/// `strength` (0.0–1.0) mengontrol intensitas penajaman.
/// Di-clamp ke [0,255] setelah penerapan.
List<List<List<double>>> _laplacianSharpening(
    List<List<List<double>>> pixels, int w, int h,
    {double strength = 0.5}) {
  // Kernel sharpening (identity + laplacian)
  const kernel = [
    [0.0, -1.0, 0.0],
    [-1.0, 5.0, -1.0],
    [0.0, -1.0, 0.0],
  ];

  final out = _createBuffer(h, w);

  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      for (int c = 0; c < 3; c++) {
        double sum = 0.0;
        for (int ky = -1; ky <= 1; ky++) {
          for (int kx = -1; kx <= 1; kx++) {
            sum += kernel[ky + 1][kx + 1] * pixels[y + ky][x + kx][c];
          }
        }
        // Blend antara original dan sharpened berdasarkan strength
        final blended = pixels[y][x][c] * (1.0 - strength) + sum * strength;
        out[y][x][c] = blended.clamp(0.0, 255.0);
      }
    }
  }

  // Border pixels: salin langsung (kernel tidak bisa diterapkan di tepi)
  for (int y = 0; y < h; y++) {
    out[y][0] = List.from(pixels[y][0]);
    out[y][w - 1] = List.from(pixels[y][w - 1]);
  }
  for (int x = 0; x < w; x++) {
    out[0][x] = List.from(pixels[0][x]);
    out[h - 1][x] = List.from(pixels[h - 1][x]);
  }

  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tahap 2 — HSV Color Isolation (Mold Boost)
// ─────────────────────────────────────────────────────────────────────────────

/// ✅ MODIFIED: Konversi RGB → HSV, boost saturasi dan value untuk rentang warna khas jamur
/// dengan configurable [colorBoost] multiplier
List<List<List<double>>> _hsvMoldBoost(
    List<List<List<double>>> pixels, int w, int h,
    {double colorBoost = 1.4}) {
  final out = _createBuffer(h, w);

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final r = pixels[y][x][0] / 255.0;
      final g = pixels[y][x][1] / 255.0;
      final b = pixels[y][x][2] / 255.0;

      final hsv = _rgbToHsv(r, g, b);
      double hue = hsv[0]; // 0–360
      double sat = hsv[1]; // 0–1
      double val = hsv[2]; // 0–1

      // Deteksi zona warna jamur dengan range lebih lebar dan inklusif untuk live feed
      final isMoldGreen = (hue >= 70 && hue <= 170) && sat >= 0.12 && val <= 0.7; 
      final isMoldBrown = (hue >= 10 && hue <= 55) && sat >= 0.08 && val <= 0.8;  
      final isMoldDark = val <= 0.25;                                              
      final isMoldWhite = sat <= 0.15 && val >= 0.5;                               

      if (isMoldGreen || isMoldBrown || isMoldDark || isMoldWhite) {
        if (!isMoldWhite) {
          // ✅ MODIFIED: Use configurable colorBoost instead of hardcoded 1.4
          sat = (sat * colorBoost).clamp(0.0, 1.0);
          // Sedikit terangkan value supaya model bisa membaca tekstur
          if (val < 0.15) val = (val + 0.08).clamp(0.0, 1.0);
        }
      } else {
        // Area non-jamur: sedikit desaturasi agar kontras terhadap jamur naik
        sat = (sat * 0.85).clamp(0.0, 1.0);
      }

      final rgb = _hsvToRgb(hue, sat, val);
      out[y][x][0] = (rgb[0] * 255.0).clamp(0.0, 255.0);
      out[y][x][1] = (rgb[1] * 255.0).clamp(0.0, 255.0);
      out[y][x][2] = (rgb[2] * 255.0).clamp(0.0, 255.0);
    }
  }

  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tahap 3 — Adaptive Contrast (CLAHE-like, per-tile)
// ─────────────────────────────────────────────────────────────────────────────

/// ✅ MODIFIED: Bagi gambar menjadi tile, dengan configurable [clipLimit]
List<List<List<double>>> _adaptiveContrast(
    List<List<List<double>>> pixels, int w, int h,
    {int tileSize = 8, double clipLimit = 2.5}) {
  final out = _createBuffer(h, w);
  final numTilesX = (w / tileSize).ceil();
  final numTilesY = (h / tileSize).ceil();

  for (int ty = 0; ty < numTilesY; ty++) {
    for (int tx = 0; tx < numTilesX; tx++) {
      final x0 = tx * tileSize;
      final y0 = ty * tileSize;
      final x1 = math.min(x0 + tileSize, w);
      final y1 = math.min(y0 + tileSize, h);

      // Kumpulkan nilai luminance tile ini (channel Y dari YCbCr)
      final lumValues = <double>[];
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          final lum = 0.299 * pixels[y][x][0] +
              0.587 * pixels[y][x][1] +
              0.114 * pixels[y][x][2];
          lumValues.add(lum);
        }
      }

      // Histogram 256-bin
      final hist = List<double>.filled(256, 0.0);
      for (final v in lumValues) {
        hist[v.clamp(0, 255).toInt()]++;
      }

      // Clip histogram (CLAHE clip) — ✅ MODIFIED: Use configurable clipLimit
      final clipVal = clipLimit * lumValues.length / 256.0;
      double excess = 0.0;
      for (int i = 0; i < 256; i++) {
        if (hist[i] > clipVal) {
          excess += hist[i] - clipVal;
          hist[i] = clipVal;
        }
      }
      // Distribusikan excess secara merata
      final addPerBin = excess / 256.0;
      for (int i = 0; i < 256; i++) {
        hist[i] += addPerBin;
      }

      // Cumulative distribution function (CDF)
      final cdf = List<double>.filled(256, 0.0);
      cdf[0] = hist[0];
      for (int i = 1; i < 256; i++) {
        cdf[i] = cdf[i - 1] + hist[i];
      }
      final cdfMin = cdf.firstWhere((v) => v > 0, orElse: () => 1.0);
      final total = lumValues.length.toDouble();

      // LUT: luma lama → luma baru
      final lut = List<double>.filled(256, 0.0);
      for (int i = 0; i < 256; i++) {
        lut[i] = ((cdf[i] - cdfMin) / (total - cdfMin) * 255.0).clamp(0.0, 255.0);
      }

      // Terapkan LUT ke setiap pixel di tile
      // Pertahankan hue & saturation, hanya ubah luminance
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          final r = pixels[y][x][0];
          final g = pixels[y][x][1];
          final b = pixels[y][x][2];
          final oldLum = (0.299 * r + 0.587 * g + 0.114 * b).clamp(0.0, 255.0);
          final newLum = lut[oldLum.toInt()];
          final scale = oldLum > 0 ? newLum / oldLum : 1.0;
          out[y][x][0] = (r * scale).clamp(0.0, 255.0);
          out[y][x][1] = (g * scale).clamp(0.0, 255.0);
          out[y][x][2] = (b * scale).clamp(0.0, 255.0);
        }
      }
    }
  }

  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tahap 4 — Gaussian Blur 3×3
// ─────────────────────────────────────────────────────────────────────────────

/// ✅ MODIFIED: Kernel Gaussian 3×3 dengan configurable [sigma]
List<List<List<double>>> _gaussianBlur3x3(
    List<List<List<double>>> pixels, int w, int h,
    {double sigma = 0.8}) {
  // Hitung kernel 3×3
  final kernel = List.generate(3, (ky) {
    return List.generate(3, (kx) {
      final dx = kx - 1.0;
      final dy = ky - 1.0;
      return math.exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma));
    });
  });

  // Normalisasi kernel
  double kSum = 0.0;
  for (final row in kernel) {
    for (final v in row) kSum += v;
  }
  for (int ky = 0; ky < 3; ky++) {
    for (int kx = 0; kx < 3; kx++) {
      kernel[ky][kx] /= kSum;
    }
  }

  final out = _createBuffer(h, w);
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      for (int c = 0; c < 3; c++) {
        double sum = 0.0;
        for (int ky = -1; ky <= 1; ky++) {
          for (int kx = -1; kx <= 1; kx++) {
            sum += kernel[ky + 1][kx + 1] * pixels[y + ky][x + kx][c];
          }
        }
        out[y][x][c] = sum.clamp(0.0, 255.0);
      }
    }
  }

  // Border: salin langsung
  for (int y = 0; y < h; y++) {
    out[y][0] = List.from(pixels[y][0]);
    out[y][w - 1] = List.from(pixels[y][w - 1]);
  }
  for (int x = 0; x < w; x++) {
    out[0][x] = List.from(pixels[0][x]);
    out[h - 1][x] = List.from(pixels[h - 1][x]);
  }

  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tahap 5 — Normalize ke model input tensor
// ─────────────────────────────────────────────────────────────────────────────

/// Output: [1][height][width][3], nilai 0.0–1.0
List<List<List<List<double>>>> _toModelInput(
    List<List<List<double>>> pixels, int w, int h) {
  return [
    List.generate(
      h,
      (y) => List.generate(
        w,
        (x) => [
          pixels[y][x][0] / 255.0,
          pixels[y][x][1] / 255.0,
          pixels[y][x][2] / 255.0,
        ],
      ),
    )
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper utilities
// ─────────────────────────────────────────────────────────────────────────────

List<List<List<double>>> _createBuffer(int h, int w) {
  return List.generate(h, (_) => List.generate(w, (_) => [0.0, 0.0, 0.0]));
}

List<List<List<double>>> _bytesToDouble(Uint8List bytes, int w, int h) {
  return List.generate(h, (y) {
    return List.generate(w, (x) {
      final i = (y * w + x) * 3;
      return [
        bytes[i].toDouble(),
        bytes[i + 1].toDouble(),
        bytes[i + 2].toDouble(),
      ];
    });
  });
}

/// RGB [0.0,1.0] → HSV: H[0–360], S[0–1], V[0–1]
List<double> _rgbToHsv(double r, double g, double b) {
  final maxV = math.max(r, math.max(g, b));
  final minV = math.min(r, math.min(g, b));
  final delta = maxV - minV;

  double h = 0.0;
  if (delta > 0.0001) {
    if (maxV == r) {
      h = 60.0 * (((g - b) / delta) % 6.0);
    } else if (maxV == g) {
      h = 60.0 * (((b - r) / delta) + 2.0);
    } else {
      h = 60.0 * (((r - g) / delta) + 4.0);
    }
  }
  if (h < 0) h += 360.0;

  final s = maxV < 0.0001 ? 0.0 : delta / maxV;
  return [h, s, maxV];
}

/// HSV → RGB [0.0,1.0]
List<double> _hsvToRgb(double h, double s, double v) {
  if (s < 0.0001) return [v, v, v];
  final sector = h / 60.0;
  final i = sector.floor();
  final f = sector - i;
  final p = v * (1.0 - s);
  final q = v * (1.0 - s * f);
  final t = v * (1.0 - s * (1.0 - f));

  switch (i % 6) {
    case 0: return [v, t, p];
    case 1: return [q, v, p];
    case 2: return [p, v, t];
    case 3: return [p, q, v];
    case 4: return [t, p, v];
    default: return [v, p, q];
  }
}
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

import 'image_processing_service.dart';
import '../screens/scanner_screen.dart' show PcdSettings;

// PcdSettings lives in scanner_screen.dart — single source of truth.
// Re-export it from here so other files don't need a direct import of scanner_screen.
export '../screens/scanner_screen.dart' show PcdSettings;

class InferenceResult {
  final String label;
  final double confidence;
  final List<double> bbox; // [cx, cy, w, h] in model coords (0–640)

  InferenceResult({
    required this.label,
    required this.confidence,
    required this.bbox,
  });

  int get confidencePercent => (confidence * 100).round();

  String get riskLevel {
    if (confidence >= 0.8) return 'danger';
    if (confidence >= 0.6) return 'high';
    if (confidence >= 0.4) return 'medium';
    return 'low';
  }
}

class InferenceService {
  Interpreter? _interpreter;
  List<String> _classNames = [];
  bool _isReady = false;

  static const int inputSize = 640;

  double get confidenceThreshold =>
      double.tryParse(dotenv.env['CONFIDENCE_THRESHOLD'] ?? '0.4') ?? 0.4;

  bool get isReady => _isReady;
  List<String> get classNames => _classNames;

  Future<void> init() async {
    try {
      final labelRaw = await rootBundle.loadString('assets/models/labels.txt');
      _classNames = labelRaw
          .trim()
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      debugPrint('✅ Labels loaded: $_classNames');

      final modelPath =
          dotenv.env['MODEL_PATH'] ?? 'assets/models/best_int8_fixed.tflite';
      _interpreter = await Interpreter.fromAsset(modelPath);
      _isReady = true;
      debugPrint(
          '✅ TFLite model loaded — input: ${_interpreter!.getInputTensor(0).shape}');
      debugPrint('   output: ${_interpreter!.getOutputTensor(0).shape}');
    } catch (e) {
      debugPrint('❌ InferenceService init failed: $e');
    }
  }

  Future<List<InferenceResult>> runOnImage(
    img.Image image, {
    PcdSettings pcdSettings = const PcdSettings(),
  }) async {
    if (!_isReady || _interpreter == null) return [];

    final resized = (image.width != inputSize || image.height != inputSize)
        ? img.copyResize(image, width: inputSize, height: inputSize)
        : image;

    final input =
        await ImageProcessingService.processForInference(resized, pcdSettings);

    return _runInterpreter(input);
  }

  List<InferenceResult> _runInterpreter(
      List<List<List<List<double>>>> input) {
    final numClasses = _classNames.length;
    final numRows = numClasses + 4;

    final output = List.generate(
      1,
      (_) => List.generate(numRows, (_) => List<double>.filled(8400, 0.0)),
    );

    _interpreter!.run(input, output);

    final predictions = output[0]; // [numRows, 8400]
    final results = <InferenceResult>[];

    for (int i = 0; i < 8400; i++) {
      final cx = predictions[0][i];
      final cy = predictions[1][i];
      final bw = predictions[2][i];
      final bh = predictions[3][i];

      double maxScore = 0.0;
      int maxClass = 0;
      for (int c = 0; c < numClasses; c++) {
        final score = predictions[4 + c][i];
        if (score > maxScore) {
          maxScore = score;
          maxClass = c;
        }
      }

      if (maxScore >= confidenceThreshold) {
        results.add(InferenceResult(
          label: _classNames[maxClass],
          confidence: maxScore,
          bbox: [cx, cy, bw, bh],
        ));
      }
    }

    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return _nms(results, iouThreshold: 0.45).take(10).toList();
  }

  List<InferenceResult> _nms(List<InferenceResult> results,
      {double iouThreshold = 0.45}) {
    final kept = <InferenceResult>[];
    final suppressed = List<bool>.filled(results.length, false);

    for (int i = 0; i < results.length; i++) {
      if (suppressed[i]) continue;
      kept.add(results[i]);
      for (int j = i + 1; j < results.length; j++) {
        if (suppressed[j]) continue;
        if (_iou(results[i].bbox, results[j].bbox) > iouThreshold) {
          suppressed[j] = true;
        }
      }
    }
    return kept;
  }

  double _iou(List<double> a, List<double> b) {
    final ax1 = a[0] - a[2] / 2;
    final ay1 = a[1] - a[3] / 2;
    final ax2 = a[0] + a[2] / 2;
    final ay2 = a[1] + a[3] / 2;

    final bx1 = b[0] - b[2] / 2;
    final by1 = b[1] - b[3] / 2;
    final bx2 = b[0] + b[2] / 2;
    final by2 = b[1] + b[3] / 2;

    final interX1 = ax1 > bx1 ? ax1 : bx1;
    final interY1 = ay1 > by1 ? ay1 : by1;
    final interX2 = ax2 < bx2 ? ax2 : bx2;
    final interY2 = ay2 < by2 ? ay2 : by2;

    final interW = interX2 - interX1;
    final interH = interY2 - interY1;
    if (interW <= 0 || interH <= 0) return 0.0;

    final interArea = interW * interH;
    final aArea = a[2] * a[3];
    final bArea = b[2] * b[3];
    return interArea / (aArea + bArea - interArea);
  }

  void dispose() {
    _interpreter?.close();
    _isReady = false;
  }
}
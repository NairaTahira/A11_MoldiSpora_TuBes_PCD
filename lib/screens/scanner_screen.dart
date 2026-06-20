import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:get_it/get_it.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';

import '../services/camera_service.dart';
import '../services/inference_service.dart';
import '../services/hive_service.dart';
import '../models/detection_result.dart';
import '../widgets/detection_painter.dart';

// ── PcdSettings ───────────────────────────────────────────────────────────────
// Single definition — imported by inference_service.dart & image_processing_service.dart

class PcdSettings {
  final double sharpening; // Laplacian strength [0.0, 1.0]
  final double colorBoost; // HSV boost [1.0, 2.0]
  final double contrast;   // CLAHE clip limit [1.0, 5.0]
  final double blur;       // Gaussian sigma [0.3, 2.0]

  const PcdSettings({
    this.sharpening = 0.5,
    this.colorBoost = 1.4,
    this.contrast = 2.5,
    this.blur = 0.8,
  });

  Map<String, dynamic> toMap() => {
        'sharpening': sharpening,
        'colorBoost': colorBoost,
        'contrast': contrast,
        'blur': blur,
      };

  @override
  String toString() =>
      'PcdSettings(sharpening: $sharpening, colorBoost: $colorBoost, '
      'contrast: $contrast, blur: $blur)';
}

// ─────────────────────────────────────────────────────────────────────────────

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver {
  final _camera = GetIt.I<CameraService>();
  final _inference = GetIt.I<InferenceService>();
  final _hive = GetIt.I<HiveService>();

  final ValueNotifier<List<InferenceResult>> _detectionNotifier =
      ValueNotifier([]);
  final ValueNotifier<String> _statusTextNotifier =
      ValueNotifier('TAP ▶ TO START LIVE DETECTION');
  final ValueNotifier<PcdSettings> _pcdSettingsNotifier =
      ValueNotifier(const PcdSettings());

  bool _isStreaming = false;
  bool _isProcessing = false;
  bool _isSaving = false;
  XFile? _galleryImage;

  // Flash state — mirrors CameraService so UI stays in sync
  FlashMode _flashMode = FlashMode.off;

  static const _frameIntervalMs = 80;
  DateTime _lastFrameTime = DateTime(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  Future<void> _initCamera() async {
    // Always reinit — disposes stale controller and creates a fresh one.
    // This fixes the black screen when returning to the Scanner tab.
    await _camera.reinit();
    if (mounted) setState(() => _flashMode = _camera.flashMode);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Stop stream but do NOT dispose the service — it's a singleton.
    // The controller will be reinited next time the screen is shown.
    _stopStreamSilent();
    _detectionNotifier.dispose();
    _statusTextNotifier.dispose();
    _pcdSettingsNotifier.dispose();
    super.dispose();
  }

  /// Stop stream without touching UI state (safe to call from dispose).
  void _stopStreamSilent() {
    try {
      if (_camera.controller?.value.isStreamingImages ?? false) {
        _camera.controller!.stopImageStream();
      }
    } catch (_) {}
    _isStreaming = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopStream();
    }
    if (state == AppLifecycleState.resumed && _galleryImage == null) {
      // Always reinit on resume — covers backgrounding the app
      _initCamera();
    }
  }

  // ── Flash ─────────────────────────────────────────────────────────────────

  Future<void> _cycleFlash() async {
    if (_galleryImage != null) return; // flash useless in gallery mode
    final next = await _camera.cycleFlash();
    if (mounted) setState(() => _flashMode = next);
  }

  IconData get _flashIcon => switch (_flashMode) {
        FlashMode.torch => Icons.flashlight_on_rounded,
        FlashMode.auto  => Icons.flash_auto_rounded,
        _               => Icons.flash_off_rounded,
      };

  Color get _flashColor => switch (_flashMode) {
        FlashMode.torch => const Color(0xFFFFDD00),
        FlashMode.auto  => const Color(0xFF00C896),
        _               => Colors.white54,
      };

  // ── Stream ────────────────────────────────────────────────────────────────

  void _toggleStream() => _isStreaming ? _stopStream() : _startStream();

  void _startStream() {
    if (!_camera.isInitialized) return;
    setState(() {
      _isStreaming = true;
      _galleryImage = null;
      _statusTextNotifier.value = 'EDGE AI ANALYZING TEXTURES...';
    });
    _camera.controller!.startImageStream(_onCameraFrame);
  }

  void _stopStream() {
    try {
      if (_camera.controller?.value.isStreamingImages ?? false) {
        _camera.controller!.stopImageStream();
      }
    } catch (e) {
      debugPrint('Stop stream error: $e');
    }
    if (mounted) {
      setState(() => _isStreaming = false);
      _detectionNotifier.value = [];
      _statusTextNotifier.value = 'TAP ▶ TO START LIVE DETECTION';
    }
  }

  // ── Gallery scan — FIXED: no crash when no mold detected ─────────────────

  Future<void> _scanFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;

    _stopStream();
    setState(() {
      _isProcessing = true;
      _galleryImage = picked;
    });

    try {
      final bytes = await picked.readAsBytes();

      img.Image? image = img.decodeImage(bytes);
      image ??= img.decodeJpg(bytes);
      image ??= img.decodePng(bytes);

      if (image == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not read image. Try a different format.'),
              backgroundColor: Color(0xFFFF4444),
            ),
          );
        }
        return;
      }

      final resized = img.copyResize(image, width: 640, height: 640);
      final results = await _inference.runOnImage(
        resized,
        pcdSettings: _pcdSettingsNotifier.value,
      );

      // FIX: guard mounted before touching state/context
      if (!mounted) return;

      _detectionNotifier.value = results;

      if (results.isEmpty) {
        // FIX: was previously trying to show alert even with empty results
        _statusTextNotifier.value = 'NO MOLD DETECTED ✓';
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No mold detected in this image.'),
            backgroundColor: Color(0xFF00C896),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        _statusTextNotifier.value =
            '⚠ ${results.first.label.replaceAll('_', ' ').toUpperCase()} '
            '– ${results.first.confidencePercent}%';

        // Only save & show alert when mold IS detected
        for (final r in results) {
          await _hive.saveResult(DetectionResult(
            id: const Uuid().v4(),
            timestamp: DateTime.now(),
            confidence: r.confidence,
            label: r.label,
            imagePath: picked.path,
            location: 'Kamar Kos',
            riskLevel: r.riskLevel,
          ));
        }
        await _hive.syncPendingResults();
        if (mounted) _showSavedAlert(results.first);
      }
    } catch (e, stack) {
      debugPrint('Gallery scan error: $e\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Scan failed: ${e.toString().length > 60 ? e.toString().substring(0, 60) : e.toString()}',
            ),
            backgroundColor: const Color(0xFFFF4444),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _galleryImage = null;
        });
        await _camera.reinit();
        if (mounted) setState(() => _flashMode = _camera.flashMode);
      }
    }
  }

  // ── Camera frame ──────────────────────────────────────────────────────────

  Future<void> _onCameraFrame(CameraImage frame) async {
    final now = DateTime.now();
    if (now.difference(_lastFrameTime).inMilliseconds < _frameIntervalMs) {
      return;
    }
    if (_isProcessing) return;

    _lastFrameTime = now;
    _isProcessing = true;

    try {
      final rgbBytes = await compute(_yuv420ToRgbDownsampled, {
        'width': frame.width,
        'height': frame.height,
        'targetSize': 640,
        'yPlane': frame.planes[0].bytes,
        'uPlane': frame.planes[1].bytes,
        'vPlane': frame.planes[2].bytes,
        'uvRowStride': frame.planes[1].bytesPerRow,
        'uvPixelStride': frame.planes[1].bytesPerPixel ?? 1,
      });

      final image = img.Image.fromBytes(
        width: 640,
        height: 640,
        bytes: rgbBytes.buffer,
        format: img.Format.uint8,
        numChannels: 3,
      );

      final results = await _inference.runOnImage(
        image,
        pcdSettings: _pcdSettingsNotifier.value,
      );

      if (_isStreaming && mounted) {
        final changed = results.length != _detectionNotifier.value.length ||
            (results.isNotEmpty &&
                (_detectionNotifier.value.isEmpty ||
                    results.first.label !=
                        _detectionNotifier.value.first.label));

        if (changed) {
          _detectionNotifier.value = results;
          _statusTextNotifier.value = results.isEmpty
              ? 'NO MOLD DETECTED ✓'
              : '⚠ ${results.first.label.replaceAll('_', ' ').toUpperCase()} '
                  '– ${results.first.confidencePercent}%';
        } else if (results.isEmpty && _detectionNotifier.value.isNotEmpty) {
          _detectionNotifier.value = [];
          _statusTextNotifier.value = 'NO MOLD DETECTED ✓';
        }
      }
    } catch (e) {
      debugPrint('Frame error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _saveDetection() async {
    if (_isSaving) return;
    final moldResults = _detectionNotifier.value.toList();

    if (moldResults.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No mold detected to save.'),
          backgroundColor: Color(0xFF21262D),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      _stopStream();
      final file = await _camera.captureImage();
      for (final r in moldResults) {
        await _hive.saveResult(DetectionResult(
          id: const Uuid().v4(),
          timestamp: DateTime.now(),
          confidence: r.confidence,
          label: r.label,
          imagePath: file?.path,
          location: 'Kamar Kos',
          riskLevel: r.riskLevel,
        ));
      }
      await _hive.syncPendingResults();
      if (mounted) _showSavedAlert(moldResults.first);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showSavedAlert(InferenceResult r) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFFF4444).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFFF4444), size: 28),
            ),
            const SizedBox(height: 12),
            const Text('Mold Saved to History!',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Confidence: ${r.confidencePercent}%\n'
              'Risk: ${r.riskLevel.toUpperCase()}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 14),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C896),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Got it',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPcdSettings() {
    final wasStreaming = _isStreaming;
    if (wasStreaming) _stopStream();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PcdSettingsSheet(
        initialSettings: _pcdSettingsNotifier.value,
        onApply: (newSettings) {
          _pcdSettingsNotifier.value = newSettings;
          Navigator.pop(context);
          if (wasStreaming) _startStream();
        },
        onClose: () {
          Navigator.pop(context);
          if (wasStreaming) _startStream();
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview OR gallery image ──
          if (_galleryImage != null)
            Positioned.fill(
              child: Image.file(File(_galleryImage!.path), fit: BoxFit.cover),
            )
          else if (_camera.isInitialized && _camera.controller != null)
            Positioned.fill(child: CameraPreview(_camera.controller!))
          else
            const Center(
                child: CircularProgressIndicator(color: Color(0xFF00C896))),

          // ── Bounding box overlay ──
          ValueListenableBuilder<List<InferenceResult>>(
            valueListenable: _detectionNotifier,
            builder: (context, detections, _) {
              if (detections.isEmpty) return const SizedBox.shrink();
              return Positioned.fill(
                child: CustomPaint(
                  painter: DetectionPainter(
                    detections: detections,
                    imageSize: _galleryImage != null
                        ? const Size(640, 640)
                        : Size(
                            _camera.controller?.value.previewSize?.height ??
                                640,
                            _camera.controller?.value.previewSize?.width ?? 640,
                          ),
                    screenSize: size,
                  ),
                ),
              );
            },
          ),

          // ── Top bar ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    // Status pill
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: (_isStreaming
                                  ? const Color(0xFF00C896)
                                  : Colors.grey)
                              .withOpacity(0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 500),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _isStreaming
                                  ? const Color(0xFF00C896)
                                  : Colors.grey,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _galleryImage != null
                                ? 'GALLERY MODE'
                                : _isStreaming
                                    ? 'LIVE INFERENCE'
                                    : 'LOCAL INFERENCE MODE',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                letterSpacing: 1),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    // ── FLASH BUTTON (camera mode only) ──────────────────
                    if (_galleryImage == null) ...[
                      GestureDetector(
                        onTap: _cycleFlash,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Icon(_flashIcon, color: _flashColor, size: 20),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],

                    // Back to camera (gallery mode only)
                    if (_galleryImage != null)
                      GestureDetector(
                        onTap: () => setState(() {
                          _galleryImage = null;
                          _detectionNotifier.value = [];
                          _statusTextNotifier.value =
                              'TAP ▶ TO START LIVE DETECTION';
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.arrow_back_rounded,
                                  color: Colors.white, size: 14),
                              SizedBox(width: 4),
                              Text('Back to Camera',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 11)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // ── Viewfinder corners (camera mode only) ──
          if (_galleryImage == null)
            Center(
              child: SizedBox(
                width: 220,
                height: 220,
                child: CustomPaint(
                    painter: _ViewfinderPainter(active: _isStreaming)),
              ),
            ),

          // ── Detection count badge ──
          ValueListenableBuilder<List<InferenceResult>>(
            valueListenable: _detectionNotifier,
            builder: (context, detections, _) {
              if (detections.isEmpty) return const SizedBox.shrink();
              return Positioned(
                top: 100,
                right: 20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF4444).withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${detections.length} detected',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              );
            },
          ),

          // ── Status text ──
          ValueListenableBuilder<String>(
            valueListenable: _statusTextNotifier,
            builder: (context, statusText, _) {
              return Positioned(
                bottom: 130,
                left: 0,
                right: 0,
                child: Text(
                  statusText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _detectionNotifier.value.isNotEmpty
                        ? const Color(0xFFFF4444)
                        : const Color(0xFF00C896),
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            },
          ),

          // ── Bottom controls ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black.withOpacity(0.7),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Play / pause
                      _controlButton(
                        icon: _isStreaming
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        onTap:
                            _galleryImage != null ? () {} : _toggleStream,
                        color: _galleryImage != null
                            ? Colors.grey
                            : _isStreaming
                                ? const Color(0xFFFF4444)
                                : Colors.white,
                      ),

                      // Save
                      GestureDetector(
                        onTap: _saveDetection,
                        child: Container(
                          width: 66,
                          height: 66,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isSaving
                                ? Colors.grey
                                : const Color(0xFF00C896),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF00C896).withOpacity(0.4),
                                blurRadius: 20,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: _isSaving
                              ? const Padding(
                                  padding: EdgeInsets.all(18),
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2),
                                )
                              : const Icon(Icons.save_alt_rounded,
                                  color: Colors.white, size: 26),
                        ),
                      ),

                      // Tune
                      _controlButton(
                        icon: Icons.tune_rounded,
                        onTap: _showPcdSettings,
                        color: Colors.white,
                      ),

                      // Gallery
                      _controlButton(
                        icon: Icons.photo_library_rounded,
                        onTap: _scanFromGallery,
                        color: const Color(0xFF00C896),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Processing overlay (gallery mode) ──
          if (_isProcessing && _galleryImage != null)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF00C896)),
                      SizedBox(height: 12),
                      Text('Analyzing image...',
                          style: TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PCD Settings Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PcdSettingsSheet extends StatefulWidget {
  final PcdSettings initialSettings;
  final ValueChanged<PcdSettings> onApply;
  final VoidCallback onClose;

  const _PcdSettingsSheet({
    required this.initialSettings,
    required this.onApply,
    required this.onClose,
  });

  @override
  State<_PcdSettingsSheet> createState() => _PcdSettingsSheetState();
}

class _PcdSettingsSheetState extends State<_PcdSettingsSheet> {
  late double _sharpening;
  late double _colorBoost;
  late double _contrast;
  late double _blur;

  @override
  void initState() {
    super.initState();
    _sharpening = widget.initialSettings.sharpening;
    _colorBoost = widget.initialSettings.colorBoost;
    _contrast = widget.initialSettings.contrast;
    _blur = widget.initialSettings.blur;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF4A5568),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              const Icon(Icons.tune_rounded,
                  color: Color(0xFF00C896), size: 20),
              const SizedBox(width: 10),
              const Text('Detection Settings',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() {
                  _sharpening = 0.5;
                  _colorBoost = 1.4;
                  _contrast = 2.5;
                  _blur = 0.8;
                }),
                child: const Text('Reset',
                    style:
                        TextStyle(color: Color(0xFF8B949E), fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Adjust the PCD pipeline for your lighting conditions.',
            style: TextStyle(color: Color(0xFF4A5568), fontSize: 12),
          ),
          const SizedBox(height: 20),
          _slider(
            label: 'Edge Sharpening',
            subtitle: 'Laplacian — pertegas tepi spora',
            value: _sharpening,
            min: 0.0,
            max: 1.0,
            onChanged: (v) => setState(() => _sharpening = v),
            displayValue: '${(_sharpening * 100).round()}%',
          ),
          _slider(
            label: 'Mold Color Boost',
            subtitle: 'HSV — isolasi pigmentasi hijau/hitam',
            value: _colorBoost,
            min: 1.0,
            max: 2.0,
            onChanged: (v) => setState(() => _colorBoost = v),
            displayValue: '${_colorBoost.toStringAsFixed(1)}×',
          ),
          _slider(
            label: 'Adaptive Contrast',
            subtitle: 'CLAHE clip limit — area gelap & lembap',
            value: _contrast,
            min: 1.0,
            max: 5.0,
            onChanged: (v) => setState(() => _contrast = v),
            displayValue: _contrast.toStringAsFixed(1),
          ),
          _slider(
            label: 'Noise Reduction',
            subtitle: 'Gaussian blur σ — kurangi noise kamera',
            value: _blur,
            min: 0.3,
            max: 2.0,
            onChanged: (v) => setState(() => _blur = v),
            displayValue: 'σ ${_blur.toStringAsFixed(1)}',
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => widget.onApply(PcdSettings(
                sharpening: _sharpening,
                colorBoost: _colorBoost,
                contrast: _contrast,
                blur: _blur,
              )),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C896),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Apply & Resume',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required String displayValue,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              Text(displayValue,
                  style: const TextStyle(
                      color: Color(0xFF00C896),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          Text(subtitle,
              style: const TextStyle(color: Color(0xFF4A5568), fontSize: 11)),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF00C896),
              inactiveTrackColor: const Color(0xFF21262D),
              thumbColor: const Color(0xFF00C896),
              overlayColor: const Color(0xFF00C896).withOpacity(0.15),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Viewfinder painter
// ─────────────────────────────────────────────────────────────────────────────

class _ViewfinderPainter extends CustomPainter {
  final bool active;
  _ViewfinderPainter({required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = active ? const Color(0xFF00C896) : Colors.white54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    const len = 24.0;
    final w = size.width;
    final h = size.height;

    canvas.drawLine(Offset(0, len), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), Offset(len, 0), paint);
    canvas.drawLine(Offset(w - len, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, len), paint);
    canvas.drawLine(Offset(0, h - len), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(len, h), paint);
    canvas.drawLine(Offset(w - len, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - len), paint);
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => old.active != active;
}

// ─────────────────────────────────────────────────────────────────────────────
// YUV → RGB (downsampled, background isolate)
// ─────────────────────────────────────────────────────────────────────────────

Uint8List _yuv420ToRgbDownsampled(Map<String, dynamic> args) {
  final int width = args['width'];
  final int height = args['height'];
  final int target = args['targetSize'];
  final Uint8List yPlane = args['yPlane'];
  final Uint8List uPlane = args['uPlane'];
  final Uint8List vPlane = args['vPlane'];
  final int uvRowStride = args['uvRowStride'];
  final int uvPixelStride = args['uvPixelStride'];

  final rgb = Uint8List(target * target * 3);
  int idx = 0;
  final xStep = width / target;
  final yStep = height / target;

  for (int ty = 0; ty < target; ty++) {
    final int srcY = (ty * yStep).floor().clamp(0, height - 1);
    for (int tx = 0; tx < target; tx++) {
      final int srcX = (tx * xStep).floor().clamp(0, width - 1);
      final int yVal = yPlane[srcY * width + srcX] & 0xFF;
      final int uvIndex =
          uvPixelStride * (srcX ~/ 2) + uvRowStride * (srcY ~/ 2);
      final int uVal = (uPlane[uvIndex] & 0xFF) - 128;
      final int vVal = (vPlane[uvIndex] & 0xFF) - 128;

      rgb[idx++] = (yVal + 1.402 * vVal).round().clamp(0, 255);
      rgb[idx++] =
          (yVal - 0.344136 * uVal - 0.714136 * vVal).round().clamp(0, 255);
      rgb[idx++] = (yVal + 1.772 * uVal).round().clamp(0, 255);
    }
  }
  return rgb;
}
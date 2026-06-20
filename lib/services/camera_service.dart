import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  FlashMode _flashMode = FlashMode.off;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  FlashMode get flashMode => _flashMode;

  Future<void> init() async {
    // Skip if controller is already alive
    if (_isInitialized && (_controller?.value.isInitialized ?? false)) return;

    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        debugPrint('❌ No cameras found');
        return;
      }
      await _initController(_cameras.first);
    } catch (e) {
      debugPrint('❌ Camera init error: $e');
    }
  }

  /// Dispose old controller then re-create. Call when screen comes back into view.
  Future<void> reinit() async {
    await _disposeController();
    await init();
  }

  Future<void> _initController(CameraDescription camera) async {
    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    try {
      await _controller!.setFlashMode(_flashMode);
    } catch (e) {
      debugPrint('⚠️ Flash not supported: $e');
    }
    _isInitialized = true;
    debugPrint('✅ Camera initialized');
  }

  Future<void> _disposeController() async {
    try {
      if (_controller?.value.isStreamingImages ?? false) {
        await _controller!.stopImageStream();
      }
      await _controller?.dispose();
    } catch (e) {
      debugPrint('⚠️ Controller dispose error: $e');
    }
    _controller = null;
    _isInitialized = false;
  }

  Future<FlashMode> cycleFlash() async {
    if (!_isInitialized || _controller == null) return _flashMode;
    final next = switch (_flashMode) {
      FlashMode.off   => FlashMode.torch,
      FlashMode.torch => FlashMode.auto,
      _               => FlashMode.off,
    };
    try {
      await _controller!.setFlashMode(next);
      _flashMode = next;
    } catch (e) {
      debugPrint('❌ Flash error: $e');
    }
    return _flashMode;
  }

  Future<void> setFlashMode(FlashMode mode) async {
    if (!_isInitialized || _controller == null) return;
    try {
      await _controller!.setFlashMode(mode);
      _flashMode = mode;
    } catch (e) {
      debugPrint('❌ setFlashMode error: $e');
    }
  }

  Future<XFile?> captureImage() async {
    if (!_isInitialized || _controller == null) return null;
    try {
      return await _controller!.takePicture();
    } catch (e) {
      debugPrint('❌ Capture error: $e');
      return null;
    }
  }

  Future<void> stopImageStream() async {
    if (_controller?.value.isStreamingImages ?? false) {
      await _controller!.stopImageStream();
    }
  }

  void dispose() {
    _disposeController();
    _isInitialized = false;
  }
}
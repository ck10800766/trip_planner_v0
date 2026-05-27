import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/database.dart';
import '../../../core/providers/database_provider.dart';
import '../../poi/providers/poi_provider.dart';
import '../providers/camera_provider.dart';

enum _CameraFrameMode { native, screenFill }

class _CropArgs {
  final String sourcePath;
  final String targetPath;
  final double targetAspectRatio;

  const _CropArgs({
    required this.sourcePath,
    required this.targetPath,
    required this.targetAspectRatio,
  });
}

Future<String?> _cropPhotoToAspectInIsolate(_CropArgs args) async {
  final bytes = await File(args.sourcePath).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final oriented = img.bakeOrientation(decoded);
  final imageAspectRatio = oriented.width / oriented.height;

  var cropX = 0;
  var cropY = 0;
  var cropWidth = oriented.width;
  var cropHeight = oriented.height;

  if (imageAspectRatio > args.targetAspectRatio) {
    cropWidth = (oriented.height * args.targetAspectRatio).round();
    cropX = ((oriented.width - cropWidth) / 2).round();
  } else if (imageAspectRatio < args.targetAspectRatio) {
    cropHeight = (oriented.width / args.targetAspectRatio).round();
    cropY = ((oriented.height - cropHeight) / 2).round();
  }

  final cropped = img.copyCrop(
    oriented,
    x: cropX,
    y: cropY,
    width: cropWidth,
    height: cropHeight,
  );
  await File(args.targetPath).writeAsBytes(img.encodeJpg(cropped, quality: 95));
  return args.targetPath;
}

class CameraScreen extends ConsumerStatefulWidget {
  final String? poiId;

  const CameraScreen({super.key, this.poiId});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;
  bool _isCameraReady = false;
  bool _isTakingPicture = false;
  Offset _gestureStartOffset = Offset.zero;
  Offset _gestureStartFocalPoint = Offset.zero;
  double _gestureStartScale = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _currentZoom = 1;
  double _gestureStartZoom = 1;
  _CameraFrameMode _frameMode = _CameraFrameMode.native;
  bool _isDesktopFallback = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Future.microtask(() {
      ref.read(cameraProvider.notifier).initialize(widget.poiId);
      _initializeCameras();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      if (mounted) setState(() => _isCameraReady = false);
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera(_cameras[_cameraIndex]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _initializeCameras() async {
    try {
      if (kIsWeb || Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      if (!mounted) return;
      setState(() {
        _isDesktopFallback = true;
      });
      return;
      }
      final cameras = await availableCameras();
      if (!mounted) return;

      if (cameras.isEmpty) {
        ref.read(cameraProvider.notifier).setCameraError('No camera found.');
        return;
      }

      final backCameraIndex = cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );

      _cameras = cameras;
      _cameraIndex = backCameraIndex == -1 ? 0 : backCameraIndex;
      await _initializeCamera(_cameras[_cameraIndex]);
    } on CameraException catch (e) {
      if (!mounted) return;
      ref
          .read(cameraProvider.notifier)
          .setCameraError('Camera unavailable: ${e.description ?? e.code}');
    } catch (e) {
      if (!mounted) return;
      ref.read(cameraProvider.notifier).setCameraError('Camera error: $e');
    }
  }

  Future<void> _initializeCamera(CameraDescription camera) async {
    if (!mounted) return;
    setState(() => _isCameraReady = false);
    await _controller?.dispose();

    final controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
    );

    _controller = controller;

    try {
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      final minZoom = await controller.getMinZoomLevel();
      final maxZoom = await controller.getMaxZoomLevel();
      final initialZoom = math.max(1, minZoom).clamp(minZoom, maxZoom);
      await controller.setZoomLevel(initialZoom.toDouble());
      if (!mounted) return;
      setState(() {
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _currentZoom = initialZoom.toDouble();
        _isCameraReady = true;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      ref
          .read(cameraProvider.notifier)
          .setCameraError('Camera unavailable: ${e.description ?? e.code}');
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPicture) {
      return;
    }

    try {
      setState(() => _isTakingPicture = true);
      HapticFeedback.mediumImpact();
      final screenSize = MediaQuery.sizeOf(context);
      final screenAspectRatio = screenSize.width / screenSize.height;
      final file = await controller.takePicture();
      if (!mounted) return;
      final photoFile = File(file.path);
      final visiblePhoto = _frameMode == _CameraFrameMode.screenFill
          ? await _cropPhotoToAspect(photoFile, screenAspectRatio)
          : photoFile;
      if (!mounted) return;
      ref.read(cameraProvider.notifier).setCapturedPhoto(visiblePhoto);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: ${e.description ?? e.code}')),
      );
    } finally {
      if (mounted) setState(() => _isTakingPicture = false);
    }
  }

  Future<File> _cropPhotoToAspect(
    File photoFile,
    double targetAspectRatio,
  ) async {
    final targetPath = photoFile.path.replaceFirst(
      RegExp(r'\.(jpe?g|png)$', caseSensitive: false),
      '_screen.jpg',
    );
    try {
      final result = await compute(
        _cropPhotoToAspectInIsolate,
        _CropArgs(
          sourcePath: photoFile.path,
          targetPath: targetPath,
          targetAspectRatio: targetAspectRatio,
        ),
      );
      if (result == null) return photoFile;
      return File(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Screen crop failed, using original: $e')),
        );
      }
      return photoFile;
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;

    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initializeCamera(_cameras[_cameraIndex]);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final nextMode = _flashMode == FlashMode.off
        ? FlashMode.auto
        : FlashMode.off;

    try {
      await controller.setFlashMode(nextMode);
      if (!mounted) return;
      setState(() => _flashMode = nextMode);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Flash unavailable: ${e.description ?? e.code}'),
        ),
      );
    }
  }

  Future<void> _setZoom(double zoom) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final nextZoom = zoom.clamp(_minZoom, _maxZoom).toDouble();

    try {
      await controller.setZoomLevel(nextZoom);
      if (!mounted) return;
      setState(() => _currentZoom = nextZoom);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Zoom unavailable: ${e.description ?? e.code}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final camState = ref.watch(cameraProvider);

    if (camState.error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  camState.error!,
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Go Back',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (camState.capturedPhoto != null) {
      return _buildComparisonScreen(camState);
    }

    return _buildCameraScreen(camState);
  }

  Widget _buildCameraScreen(CameraState camState) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(camState),
          if (camState.referenceImage != null) _buildReferenceOverlay(camState),
          _buildTopBar(camState),
          _buildBottomControls(camState),
          if (_isTakingPicture)
            Container(
              color: Colors.black.withValues(alpha: 0.18),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview(CameraState camState) {
    final controller = _controller;

    if (!_isCameraReady ||
        controller == null ||
        !controller.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: camState.referenceImage == null
          ? (_) => _gestureStartZoom = _currentZoom
          : null,
      onScaleUpdate: camState.referenceImage == null
          ? (details) => _setZoom(_gestureStartZoom * details.scale)
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final previewSize = controller.value.previewSize;
          final previewAspectRatio = previewSize == null
              ? controller.value.aspectRatio
              : previewSize.height / previewSize.width;
          final preview = AspectRatio(
            aspectRatio: previewAspectRatio,
            child: CameraPreview(controller),
          );

          if (_frameMode == _CameraFrameMode.native) {
            return Center(child: preview);
          }

          return ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: constraints.maxWidth,
                height: constraints.maxWidth / previewAspectRatio,
                child: preview,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildReferenceOverlay(CameraState camState) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onScaleStart: (details) {
          _gestureStartOffset = camState.overlayOffset;
          _gestureStartFocalPoint = details.focalPoint;
          _gestureStartScale = camState.overlayScale;
        },
        onScaleUpdate: (details) {
          ref
              .read(cameraProvider.notifier)
              .updateOverlayTransform(
                offset:
                    _gestureStartOffset +
                    (details.focalPoint - _gestureStartFocalPoint),
                scale: _gestureStartScale * details.scale,
              );
        },
        onDoubleTap: () => ref.read(cameraProvider.notifier).resetOverlay(),
        child: Center(
          child: Transform.translate(
            offset: camState.overlayOffset,
            child: Transform.scale(
              scale: camState.overlayScale,
              child: Opacity(
                opacity: camState.overlayOpacity,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.86,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.58,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 1.5),
                  ),
                  child: Image.file(
                    camState.referenceImage!,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(CameraState camState) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _CameraIconButton(
                icon: Icons.arrow_back,
                onTap: () => Navigator.pop(context),
              ),
              const Spacer(),
              if (camState.referenceImage != null)
                _CameraIconButton(
                  icon: Icons.center_focus_strong,
                  onTap: () => ref.read(cameraProvider.notifier).resetOverlay(),
                ),
              if (camState.referenceImage != null) const SizedBox(width: 10),
              _CameraIconButton(
                icon: Icons.photo_library_outlined,
                onTap: _pickPoiReferenceImage,
              ),
              const SizedBox(width: 10),
              _FrameModeToggle(
                mode: _frameMode,
                onChanged: (mode) => setState(() => _frameMode = mode),
              ),
              const SizedBox(width: 10),
              _CameraIconButton(
                icon: _flashMode == FlashMode.off
                    ? Icons.flash_off
                    : Icons.flash_auto,
                onTap: _toggleFlash,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls(CameraState camState) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.82),
                Colors.black.withValues(alpha: 0.38),
                Colors.transparent,
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (camState.referenceImage != null)
                Row(
                  children: [
                    const Icon(Icons.layers, color: Colors.white70, size: 18),
                    Expanded(
                      child: Slider(
                        value: camState.overlayOpacity,
                        min: 0.1,
                        max: 1,
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                        onChanged: (value) => ref
                            .read(cameraProvider.notifier)
                            .setOverlayOpacity(value),
                      ),
                    ),
                    _CameraIconButton(
                      icon: Icons.visibility_off,
                      size: 38,
                      onTap: () => ref
                          .read(cameraProvider.notifier)
                          .clearReferenceImage(),
                    ),
                  ],
                ),
              if (_maxZoom > _minZoom)
                Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${_currentZoom.toStringAsFixed(1)}x',
                        style: const TextStyle(
                          color: Colors.white,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: _currentZoom
                            .clamp(_minZoom, _maxZoom)
                            .toDouble(),
                        min: _minZoom,
                        max: _maxZoom,
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                        onChanged: (value) => _setZoom(value),
                      ),
                    ),
                    _CameraIconButton(
                      icon: Icons.center_focus_weak,
                      size: 38,
                      onTap: () => _setZoom(math.max(1, _minZoom)),
                    ),
                  ],
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _ReferenceButton(
                    referenceImage:
                        camState.poiId == null ? camState.referenceImage : null,
                    emptyIcon: camState.poiId == null
                        ? Icons.image
                        : Icons.file_upload_outlined,
                    onTap: _pickReferenceImage,
                  ),
                  _ShutterButton(isBusy: _isTakingPicture, onTap: _takePicture),
                  _CameraIconButton(
                    icon: Icons.cameraswitch,
                    size: 52,
                    onTap: _cameras.length > 1 ? _switchCamera : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComparisonScreen(CameraState camState) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Compare Shot'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => ref.read(cameraProvider.notifier).clearCapture(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                camState.referenceImage == null
                    ? 'Review your photo'
                    : 'Reference and your shot',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                camState.referenceImage == null
                    ? 'Save it to the selected POI or retake.'
                    : 'Check the framing before saving to this POI.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _ComparisonLayout(
                  referenceImage: camState.referenceImage,
                  capturedPhoto: camState.capturedPhoto!,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          ref.read(cameraProvider.notifier).clearCapture(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _savePhoto(camState),
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickReferenceImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final imageFile = File(picked.path);
    final camState = ref.read(cameraProvider);

    if (camState.poiId != null) {
      final db = ref.read(databaseProvider);
      final success = await ref
          .read(cameraProvider.notifier)
          .saveUploadedImage(db, imageFile);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? 'Image uploaded!' : 'Upload failed')),
      );
      return;
    }

    ref.read(cameraProvider.notifier).setReferenceImage(imageFile);
  }

  Future<void> _pickPoiReferenceImage() async {
    final poiId = await _resolvePoiIdForReference();
    if (poiId == null) return;

    final images =
        await ref.read(referenceImagesByPoiProvider(poiId).future);

    if (!mounted) return;
    if (images.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No reference images. Add some on the POI page.'),
        ),
      );
      return;
    }

    final picked = await showModalBottomSheet<ReferenceImage>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: images.length,
        itemBuilder: (ctx, index) {
          final image = images[index];
          final file = File(image.localUri);

          return ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Image.file(
                  file,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Colors.black26,
                    child: Icon(Icons.broken_image, color: Colors.white54),
                  ),
                ),
              ),
            ),
            title: Text(
              p.basenameWithoutExtension(image.localUri),
              style: const TextStyle(color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.pop(ctx, image),
          );
        },
      ),
    );

    if (picked == null) return;

    final file = File(picked.localUri);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Image file not found: ${picked.localUri}')),
      );
      return;
    }

    ref
        .read(cameraProvider.notifier)
        .setReferenceImage(file, referenceImageId: picked.id);
  }

  Future<String?> _resolvePoiIdForReference() async {
    final currentPoiId = ref.read(cameraProvider).poiId;
    if (currentPoiId != null) return currentPoiId;

    final poisMap = await ref.read(allPoisProvider.future);
    final pois = poisMap.values.toList();

    if (!mounted) return null;
    if (pois.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No POIs yet. Create one first.')),
      );
      return null;
    }

    final picked = await showModalBottomSheet<Poi>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: pois.length,
        itemBuilder: (ctx, index) {
          final poi = pois[index];

          return ListTile(
            leading: const Icon(Icons.location_on, color: Colors.white70),
            title: Text(
              poi.name,
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: poi.animeSeriesRef != null
                ? Text(
                    poi.animeSeriesRef!,
                    style: const TextStyle(color: Colors.white54),
                  )
                : null,
            onTap: () => Navigator.pop(ctx, poi),
          );
        },
      ),
    );

    if (picked == null) return null;

    ref.read(cameraProvider.notifier).setPoiId(picked.id);
    return picked.id;
  }

  Future<void> _savePhoto(CameraState camState) async {
    if (camState.poiId == null) {
      await _showPoiPicker();
      return;
    }

    final db = ref.read(databaseProvider);
    final success = await ref.read(cameraProvider.notifier).savePhoto(db);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? 'Photo saved!' : 'Save failed')),
      );
      if (success) {
        ref.read(cameraProvider.notifier).clearCapture();
      }
    }
  }

  Future<void> _showPoiPicker() async {
    final poisMap = await ref.read(allPoisProvider.future);
    final pois = poisMap.values.toList();

    if (!mounted) return;
    if (pois.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No POIs yet. Create one first.')),
      );
      return;
    }

    final picked = await showModalBottomSheet<Poi>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: pois.length,
        itemBuilder: (ctx, i) => ListTile(
          leading: const Icon(Icons.location_on, color: Colors.white70),
          title: Text(
            pois[i].name,
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: pois[i].animeSeriesRef != null
              ? Text(
                  pois[i].animeSeriesRef!,
                  style: const TextStyle(color: Colors.white54),
                )
              : null,
          onTap: () => Navigator.pop(ctx, pois[i]),
        ),
      ),
    );

    if (picked != null) {
      ref.read(cameraProvider.notifier).setPoiId(picked.id);
      final db = ref.read(databaseProvider);
      final success = await ref.read(cameraProvider.notifier).savePhoto(db);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success ? 'Photo saved to ${picked.name}!' : 'Save failed',
            ),
          ),
        );
        if (success) {
          ref.read(cameraProvider.notifier).clearCapture();
        }
      }
    }
  }
}

class _FrameModeToggle extends StatelessWidget {
  final _CameraFrameMode mode;
  final ValueChanged<_CameraFrameMode> onChanged;

  const _FrameModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FrameModeButton(
            label: 'Native',
            selected: mode == _CameraFrameMode.native,
            onTap: () => onChanged(_CameraFrameMode.native),
          ),
          _FrameModeButton(
            label: 'Fill',
            selected: mode == _CameraFrameMode.screenFill,
            onTap: () => onChanged(_CameraFrameMode.screenFill),
          ),
        ],
      ),
    );
  }
}

class _ComparisonLayout extends StatefulWidget {
  final File? referenceImage;
  final File capturedPhoto;

  const _ComparisonLayout({
    required this.referenceImage,
    required this.capturedPhoto,
  });

  @override
  State<_ComparisonLayout> createState() => _ComparisonLayoutState();
}

class _ComparisonLayoutState extends State<_ComparisonLayout> {
  bool? _capturedIsPortrait;
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;

  @override
  void initState() {
    super.initState();
    _resolveCapturedOrientation();
  }

  @override
  void didUpdateWidget(covariant _ComparisonLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capturedPhoto.path != widget.capturedPhoto.path) {
      _capturedIsPortrait = null;
      _disposeImageStream();
      _resolveCapturedOrientation();
    }
  }

  @override
  void dispose() {
    _disposeImageStream();
    super.dispose();
  }

  void _disposeImageStream() {
    final stream = _imageStream;
    final listener = _imageStreamListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _imageStream = null;
    _imageStreamListener = null;
  }

  void _resolveCapturedOrientation() {
    final provider = FileImage(widget.capturedPhoto);
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      if (!mounted) {
        _disposeImageStream();
        return;
      }
      setState(() {
        _capturedIsPortrait = info.image.height >= info.image.width;
      });
      _disposeImageStream();
    });

    _imageStream = stream;
    _imageStreamListener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final referenceImage = widget.referenceImage;

    if (referenceImage == null) {
      return _ImageReviewCard(
        label: 'Your Shot',
        icon: Icons.camera_alt,
        imageFile: widget.capturedPhoto,
      );
    }

    final isPortrait = _capturedIsPortrait ?? true;
    final firstCard = Expanded(
      child: _ImageReviewCard(
        label: 'Reference',
        icon: Icons.image,
        imageFile: referenceImage,
      ),
    );
    final secondCard = Expanded(
      child: _ImageReviewCard(
        label: 'Your Shot',
        icon: Icons.camera_alt,
        imageFile: widget.capturedPhoto,
      ),
    );

    if (isPortrait) {
      return Column(
        children: [
          firstCard,
          const SizedBox(height: 12),
          secondCard,
        ],
      );
    }

    return Row(
      children: [
        firstCard,
        const SizedBox(width: 12),
        secondCard,
      ],
    );
  }
}

class _ImageReviewCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final File imageFile;

  const _ImageReviewCard({
    required this.label,
    required this.icon,
    required this.imageFile,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: InteractiveViewer(
                minScale: 0.75,
                maxScale: 4,
                child: Center(
                  child: Image.file(imageFile, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
          Container(
            height: 44,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: IconButton(
              tooltip: 'Preview',
              icon: const Icon(Icons.open_in_full),
              onPressed: () => _showFullscreenImage(context),
            ),
          ),
        ],
      ),
    );
  }

  void _showFullscreenImage(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              minScale: 0.75,
              maxScale: 5,
              child: Center(
                child: Image.file(imageFile, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: AppBar(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                  title: Text(label),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FrameModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FrameModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CameraIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;

  const _CameraIconButton({
    required this.icon,
    required this.onTap,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.35 : 1,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.42),
            border: Border.all(color: Colors.white12),
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.48),
        ),
      ),
    );
  }
}

class _ReferenceButton extends StatelessWidget {
  final File? referenceImage;
  final IconData emptyIcon;
  final VoidCallback onTap;

  const _ReferenceButton({
    required this.referenceImage,
    required this.emptyIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.black.withValues(alpha: 0.42),
          border: Border.all(color: Colors.white30, width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: referenceImage == null
            ? Icon(emptyIcon, color: Colors.white, size: 28)
            : Image.file(referenceImage!, fit: BoxFit.cover),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isBusy;
  final VoidCallback onTap;

  const _ShutterButton({required this.isBusy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isBusy ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: isBusy ? 0.55 : 1,
        child: Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: Container(
            margin: const EdgeInsets.all(5),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

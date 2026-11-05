import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const PhotoCullerApp());
}

class PhotoCullerApp extends StatelessWidget {
  const PhotoCullerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photo Culler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.tealAccent,
          secondary: Colors.amberAccent,
        ),
      ),
      home: const CullerHomePage(),
    );
  }
}

enum SwipeAction {
  discard(
    folderName: 'คัดทิ้ง',
    label: 'คัดทิ้ง (← / A)',
    color: Colors.redAccent,
    icon: Icons.delete_outline,
  ),
  keep(
    folderName: 'ภาพที่ใช้ได้',
    label: 'เก็บไว้ (→ / D)',
    color: Colors.greenAccent,
    icon: Icons.check_circle_outline,
  ),
  best(
    folderName: 'ภาพที่นำไปใช้ได้ทันที',
    label: 'ดีที่สุด (↑ / W)',
    color: Colors.amberAccent,
    icon: Icons.star_outline,
  ),
  atmosphere(
    folderName: 'ภาพบรรยากาศ',
    label: 'ภาพบรรยากาศ (↓ / S)',
    color: Colors.lightBlueAccent,
    icon: Icons.landscape_outlined,
  );

  final String folderName;
  final String label;
  final Color color;
  final IconData icon;

  const SwipeAction({
    required this.folderName,
    required this.label,
    required this.color,
    required this.icon,
  });
}

class MoveHistory {
  final File originalFile;
  final File movedFile;
  final SwipeAction action;

  MoveHistory({
    required this.originalFile,
    required this.movedFile,
    required this.action,
  });
}

class CullerHomePage extends StatefulWidget {
  const CullerHomePage({super.key});

  @override
  State<CullerHomePage> createState() => _CullerHomePageState();
}

class _CullerHomePageState extends State<CullerHomePage> {
  String? _selectedDirectory;
  List<File> _imageFiles = [];
  int _currentIndex = 0;
  bool _isLoading = false;

  Offset _dragOffset = Offset.zero;
  int _pointerCount = 0;
  bool _isZoomed = false;
  final TransformationController _zoomController = TransformationController();
  final FocusNode _keyboardFocusNode = FocusNode();

  final List<MoveHistory> _history = [];
  final Map<String, Uint8List?> _imageBytesCache = {};

  static const Set<String> _supportedExtensions = {
    '.jpg', '.jpeg', '.png', '.webp', '.heic', '.bmp', '.arw'
  };

  @override
  void initState() {
    super.initState();
    _zoomController.addListener(_onZoomChanged);
    _requestPermissions();
  }

  void _onZoomChanged() {
    final scale = _zoomController.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.05;
    if (zoomed != _isZoomed) {
      setState(() {
        _isZoomed = zoomed;
        if (_isZoomed) {
          _dragOffset = Offset.zero;
        }
      });
    }
  }

  void _resetZoom() {
    _zoomController.value = Matrix4.identity();
    setState(() {
      _isZoomed = false;
      _dragOffset = Offset.zero;
    });
  }

  void _toggleDoubleTapZoom() {
    if (_isZoomed) {
      _resetZoom();
    } else {
      _zoomController.value = Matrix4.diagonal3Values(2.5, 2.5, 1.0);
    }
  }

  @override
  void dispose() {
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      if (!await Permission.manageExternalStorage.isGranted) {
        await Permission.manageExternalStorage.request();
      }
      if (!await Permission.storage.isGranted) {
        await Permission.storage.request();
      }
    }
  }

  Future<void> _pickFolder() async {
    await _requestPermissions();

    String? selectedDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'เลือกโฟลเดอร์รูปภาพที่ต้องการคัดเลือก',
    );

    if (selectedDir != null) {
      setState(() {
        _selectedDirectory = selectedDir;
        _isLoading = true;
        _imageFiles.clear();
        _currentIndex = 0;
        _history.clear();
        _imageBytesCache.clear();
      });

      await _loadImagesFromDirectory(selectedDir);

      setState(() {
        _isLoading = false;
      });
      _keyboardFocusNode.requestFocus();
    }
  }

  Future<void> _loadImagesFromDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    final List<File> loadedFiles = [];

    try {
      final entities = dir.listSync(recursive: false, followLinks: false);
      for (var entity in entities) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (_supportedExtensions.contains(ext)) {
            loadedFiles.add(entity);
          }
        }
      }
      loadedFiles.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    } catch (e) {
      _showSnackBar('เกิดข้อผิดพลาดในการอ่านโฟลเดอร์: $e', Colors.red);
    }

    _imageFiles = loadedFiles;
    _preloadAdjacentImages();
  }

  Future<void> _preloadAdjacentImages() async {
    for (int i = _currentIndex; i <= _currentIndex + 2; i++) {
      if (i >= 0 && i < _imageFiles.length) {
        final file = _imageFiles[i];
        if (!_imageBytesCache.containsKey(file.path)) {
          _extractImageBytes(file).then((bytes) {
            if (mounted) {
              setState(() {
                _imageBytesCache[file.path] = bytes;
              });
            }
          });
        }
      }
    }
    if (_currentIndex - 2 >= 0) {
      _imageBytesCache.remove(_imageFiles[_currentIndex - 2].path);
    }
  }

  Future<Uint8List?> _extractImageBytes(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    try {
      final bytes = await file.readAsBytes();
      if (ext != '.arw') {
        return bytes;
      }
      return _extractLargestEmbeddedJpeg(bytes);
    } catch (e) {
      return null;
    }
  }

  Uint8List? _extractLargestEmbeddedJpeg(Uint8List bytes) {
    int bestStart = -1;
    int bestLength = 0;

    for (int i = 0; i < bytes.length - 3; i++) {
      if (bytes[i] == 0xFF &&
          bytes[i + 1] == 0xD8 &&
          bytes[i + 2] == 0xFF &&
          (bytes[i + 3] == 0xE0 || bytes[i + 3] == 0xE1 || bytes[i + 3] == 0xDB)) {
        int start = i;
        int end = -1;

        for (int j = start + 4; j < bytes.length - 1; j++) {
          if (bytes[j] == 0xFF && bytes[j + 1] == 0xD9) {
            end = j + 2;
            int length = end - start;
            if (length > 200000) {
              break;
            }
          }
        }

        if (end != -1) {
          int length = end - start;
          if (length > bestLength) {
            bestLength = length;
            bestStart = start;
          }
          i = end - 1;
        }
      }
    }

    if (bestStart != -1 && bestLength > 0) {
      return Uint8List.sublistView(bytes, bestStart, bestStart + bestLength);
    }
    return null;
  }

  SwipeAction? _getCurrentDragAction() {
    if (_dragOffset.distance < 80) return null;

    if (_dragOffset.dx.abs() > _dragOffset.dy.abs()) {
      return _dragOffset.dx > 0 ? SwipeAction.keep : SwipeAction.discard;
    } else {
      return _dragOffset.dy < 0 ? SwipeAction.best : SwipeAction.atmosphere;
    }
  }

  Future<void> _handleSwipeAction(SwipeAction action) async {
    if (_currentIndex >= _imageFiles.length || _selectedDirectory == null) return;

    final currentFile = _imageFiles[_currentIndex];
    final targetDir = Directory(p.join(_selectedDirectory!, action.folderName));

    try {
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final newFilePath = p.join(targetDir.path, p.basename(currentFile.path));
      File movedFile;

      try {
        movedFile = await currentFile.rename(newFilePath);
      } catch (_) {
        movedFile = await currentFile.copy(newFilePath);
        await currentFile.delete();
      }

      _zoomController.value = Matrix4.identity();
      setState(() {
        _history.add(MoveHistory(
          originalFile: currentFile,
          movedFile: movedFile,
          action: action,
        ));
        _currentIndex++;
        _dragOffset = Offset.zero;
        _isZoomed = false;
      });

      _preloadAdjacentImages();
    } catch (e) {
      _showSnackBar('ย้ายไฟล์ไม่สำเร็จ: $e', Colors.redAccent);
      setState(() {
        _dragOffset = Offset.zero;
      });
    }
  }

  Future<void> _undoLastAction() async {
    if (_history.isEmpty) return;

    final lastMove = _history.removeLast();
    try {
      if (await lastMove.movedFile.exists()) {
        await lastMove.movedFile.rename(lastMove.originalFile.path);
      }
      _zoomController.value = Matrix4.identity();
      setState(() {
        _currentIndex--;
        _dragOffset = Offset.zero;
        _isZoomed = false;
      });
      _showSnackBar('เรียกคืนไฟล์ ${p.basename(lastMove.originalFile.path)} แล้ว', Colors.teal);
    } catch (e) {
      _showSnackBar('ไม่สามารถเรียกคืนไฟล์ได้: $e', Colors.redAccent);
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final key = event.logicalKey;
    final isCtrlPressed = HardwareKeyboard.instance.isControlPressed;

    if (key == LogicalKeyboardKey.backspace ||
        (isCtrlPressed && key == LogicalKeyboardKey.keyZ)) {
      _undoLastAction();
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA) {
      _handleSwipeAction(SwipeAction.discard);
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyD) {
      _handleSwipeAction(SwipeAction.keep);
    } else if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.keyW) {
      _handleSwipeAction(SwipeAction.best);
    } else if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.keyS) {
      _handleSwipeAction(SwipeAction.atmosphere);
    } else if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.space) {
      _resetZoom();
    }
  }

  void _showSnackBar(String message, Color bgColor) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: bgColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasImages = _imageFiles.isNotEmpty && _currentIndex < _imageFiles.length;
    final currentFile = hasImages ? _imageFiles[_currentIndex] : null;
    final activeAction = _getCurrentDragAction();

    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black87,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                currentFile != null ? p.basename(currentFile.path) : 'Photo Culler (PC & Mobile)',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              if (hasImages)
                Text(
                  'ภาพที่ ${_currentIndex + 1} จาก ${_imageFiles.length} '
                  '${_isZoomed ? "(โหมดซูม - แตะ 2 ครั้ง หรือกด Spacebar เพื่อออก)" : ""}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
            ],
          ),
          actions: [
            if (_isZoomed)
              IconButton(
                icon: const Icon(Icons.zoom_out_map),
                tooltip: 'รีเซ็ตการซูม',
                onPressed: _resetZoom,
              ),
            if (_history.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'ย้อนกลับ (Ctrl+Z หรือ Backspace)',
                onPressed: _undoLastAction,
              ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'เลือกโฟลเดอร์รูปภาพ',
              onPressed: _pickFolder,
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : !hasImages
                ? _buildEmptyState()
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      _buildDirectionGuides(),
                      _buildSwipeableCard(currentFile!),
                      if (activeAction != null) _buildActionBadge(activeAction),
                      Positioned(
                        bottom: 20,
                        child: _buildManualControlBar(),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final isDone = _imageFiles.isNotEmpty && _currentIndex >= _imageFiles.length;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isDone ? Icons.check_circle_outline : Icons.photo_library_outlined,
              size: 80,
              color: Colors.tealAccent,
            ),
            const SizedBox(height: 16),
            Text(
              isDone
                  ? 'คัดเลือกรูปภาพครบทุกภาพแล้ว!'
                  : 'เลือกโฟลเดอร์เพื่อเริ่มคัดเลือกรูปภาพ\n(รองรับ JPG, PNG, HEIC, WEBP และ Sony .ARW)\n\nบน PC สามารถใช้ปุ่มลูกศร ◀ ▲ ▼ ▶ หรือ W A S D เพื่อคัดแยกรูปได้ทันที',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.white70),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _pickFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('เลือกโฟลเดอร์รูปภาพ'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
            if (isDone && _history.isNotEmpty) ...[
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _undoLastAction,
                icon: const Icon(Icons.undo),
                label: const Text('ย้อนกลับภาพล่าสุด (Backspace)'),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildZoomableImage(Uint8List bytes, String filePath) {
    return GestureDetector(
      onDoubleTap: _toggleDoubleTapZoom,
      child: InteractiveViewer(
        key: ValueKey(filePath),
        transformationController: _zoomController,
        minScale: 1.0,
        maxScale: 5.0,
        panEnabled: _isZoomed,
        scaleEnabled: true,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }

  Widget _buildSwipeableCard(File file) {
    final imageBytes = _imageBytesCache[file.path];
    final ext = p.extension(file.path).toLowerCase();

    return Listener(
      onPointerDown: (_) {
        _pointerCount++;
        _keyboardFocusNode.requestFocus();
      },
      onPointerUp: (_) {
        _pointerCount = (_pointerCount - 1).clamp(0, 10);
        if (_pointerCount == 0 && !_isZoomed) {
          final action = _getCurrentDragAction();
          if (action != null) {
            _handleSwipeAction(action);
          } else {
            setState(() => _dragOffset = Offset.zero);
          }
        }
      },
      onPointerCancel: (_) {
        _pointerCount = 0;
        setState(() => _dragOffset = Offset.zero);
      },
      onPointerMove: (event) {
        if (_pointerCount == 1 && !_isZoomed) {
          setState(() {
            _dragOffset += event.delta;
          });
        }
      },
      child: Transform.translate(
        offset: _dragOffset,
        child: Transform.rotate(
          angle: (_dragOffset.dx / 1000).clamp(-0.2, 0.2),
          child: Container(
            margin: const EdgeInsets.only(bottom: 70, top: 10, left: 10, right: 10),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 12, spreadRadius: 2),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (imageBytes != null)
                  _buildZoomableImage(imageBytes, file.path)
                else
                  FutureBuilder<Uint8List?>(
                    future: _extractImageBytes(file),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.data == null) {
                        return Center(
                          child: Text(
                            'ไม่สามารถอ่านไฟล์ภาพได้\n(${p.basename(file.path)})',
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      _imageBytesCache[file.path] = snapshot.data;
                      return _buildZoomableImage(snapshot.data!, file.path);
                    },
                  ),
                if (ext == '.arw')
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xD9FF9800),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'SONY RAW (.ARW)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionBadge(SwipeAction action) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xBF000000),
          border: Border.all(color: action.color, width: 3),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, color: action.color, size: 36),
            const SizedBox(width: 12),
            Text(
              action.label,
              style: TextStyle(
                color: action.color,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectionGuides() {
    return const IgnorePointer(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 80),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('▲ ปัดขึ้น / กด ↑ (W) : ดีที่สุด (ใช้ทันที)',
                style: TextStyle(color: Colors.white30, fontSize: 12)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('◀ ซ้าย / กด ← (A) : คัดทิ้ง',
                    style: TextStyle(color: Colors.white30, fontSize: 12)),
                Text('ขวา / กด → (D) : เก็บไว้ ▶',
                    style: TextStyle(color: Colors.white30, fontSize: 12)),
              ],
            ),
            Text('▼ ปัดลง / กด ↓ (S) : ภาพบรรยากาศ',
                style: TextStyle(color: Colors.white30, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildManualControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xE6212121),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: SwipeAction.values.map((action) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: IconButton(
              icon: Icon(action.icon, color: action.color, size: 28),
              tooltip: action.label,
              onPressed: () => _handleSwipeAction(action),
            ),
          );
        }).toList(),
      ),
    );
  }
}

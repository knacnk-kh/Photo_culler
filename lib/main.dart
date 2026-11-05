import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_view/photo_view.dart';
import 'package:exif/exif.dart';
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
    label: 'คัดทิ้ง',
    color: Colors.redAccent,
    icon: Icons.delete_outline,
  ),
  keep(
    folderName: 'ภาพที่ใช้ได้',
    label: 'เก็บไว้ (ใช้ได้)',
    color: Colors.greenAccent,
    icon: Icons.check_circle_outline,
  ),
  best(
    folderName: 'ภาพที่นำไปใช้ได้ทันที',
    label: 'ดีที่สุด (ใช้ทันที)',
    color: Colors.amberAccent,
    icon: Icons.star_outline,
  ),
  atmosphere(
    folderName: 'ภาพบรรยากาศ',
    label: 'ภาพบรรยากาศ',
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

  // สำหรับระบบปัดและซูม
  Offset _dragOffset = Offset.zero;
  int _pointerCount = 0;
  bool _isZoomed = false;
  late PhotoViewScaleStateController _scaleStateController;

  // ประวัติการย้ายไฟล์ (เผื่อกด Undo)
  final List<MoveHistory> _history = [];

  // แคชข้อมูลรูปภาพ (เพื่อให้เปิดรูปถัดไปและไฟล์ ARW ได้ทันทีโดยไม่กระตุก)
  final Map<String, Uint8List?> _imageBytesCache = {};

  static const Set<String> _supportedExtensions = {
    '.jpg', '.jpeg', '.png', '.webp', '.heic', '.bmp', '.arw'
  };

  @override
  void initState() {
    super.initState();
    _scaleStateController = PhotoViewScaleStateController();
    _requestPermissions();
  }

  @override
  void dispose() {
    _scaleStateController.dispose();
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
      // เรียงตามชื่อไฟล์
      loadedFiles.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    } catch (e) {
      _showSnackBar('เกิดข้อผิดพลาดในการอ่านโฟลเดอร์: $e', Colors.red);
    }

    _imageFiles = loadedFiles;
    _preloadAdjacentImages();
  }

  // โหลดภาพปัจจุบันและภาพถัดไปรอไว้ในหน่วยความจำล่วงหน้า
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
    // ล้างแคชภาพที่ผ่านไปแล้วเพื่อประหยัด RAM
    if (_currentIndex - 2 >= 0) {
      _imageBytesCache.remove(_imageFiles[_currentIndex - 2].path);
    }
  }

  /// ดึงข้อมูลภาพสำหรับแสดงผล (รองรับทั้งไฟล์ภาพปกติ และดึง Preview JPEG จากไฟล์ Sony .ARW)
  Future<Uint8List?> _extractImageBytes(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    try {
      final bytes = await file.readAsBytes();
      if (ext != '.arw') {
        return bytes;
      }

      // กรณีเป็นไฟล์ .ARW:1. ลองดึงจาก EXIF Thumbnail ก่อน
      try {
        final exifData = await readExifFromBytes(bytes);
        if (exifData.containsKey('JPEGThumbnail')) {
          final thumb = exifData['JPEGThumbnail']!.values.toList();
          if (thumb.length > 50000) {
            return Uint8List.fromList(thumb);
          }
        }
      } catch (_) {}

      // 2. ค้นหา Full-size Embedded JPEG ที่ซ่อนอยู่ในโครงสร้างไฟล์ Sony ARW
      // โดยสแกนหาจุดเริ่มต้น (FF D8 FF) และจุดสิ้นสุด (FF D9) ของ JPEG ที่มีขนาดใหญ่ที่สุด
      return _extractLargestEmbeddedJpeg(bytes);
    } catch (e) {
      return null;
    }
  }

  Uint8List? _extractLargestEmbeddedJpeg(Uint8List bytes) {
    int bestStart = -1;
    int bestLength = 0;

    // ข้ามส่วน Header แรกสุดเพื่อหา Embedded Preview ของจริง
    for (int i = 0; i < bytes.length - 3; i++) {
      // ค้นหา JPEG SOI Marker: FF D8 FF (ตามด้วย E0, E1, หรือ DB)
      if (bytes[i] == 0xFF &&
          bytes[i + 1] == 0xD8 &&
          bytes[i + 2] == 0xFF &&
          (bytes[i + 3] == 0xE0 || bytes[i + 3] == 0xE1 || bytes[i + 3] == 0xDB)) {
        int start = i;
        int end = -1;

        // ค้นหา EOI Marker (FF D9) ถัดไป
        for (int j = start + 4; j < bytes.length - 1; j++) {
          if (bytes[j] == 0xFF && bytes[j + 1] == 0xD9) {
            end = j + 2;
            int length = end - start;
            // ภาพ Preview มาตรฐานของ Sony ARW มักมีขนาดตั้งแต่ 300KB ขึ้นไป
            if (length > 300000) {
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
        // กรณีอยู่ต่าง Partition ให้ Copy แล้วลบต้นฉบับ
        movedFile = await currentFile.copy(newFilePath);
        await currentFile.delete();
      }

      setState(() {
        _history.add(MoveHistory(
          originalFile: currentFile,
          movedFile: movedFile,
          action: action,
        ));
        _currentIndex++;
        _dragOffset = Offset.zero;
        _isZoomed = false;
        _scaleStateController.scaleState = PhotoViewScaleState.initial;
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
      setState(() {
        _currentIndex--;
        _dragOffset = Offset.zero;
        _isZoomed = false;
        _scaleStateController.scaleState = PhotoViewScaleState.initial;
      });
      _showSnackBar('เรียกคืนไฟล์ ${p.basename(lastMove.originalFile.path)} แล้ว', Colors.teal);
    } catch (e) {
      _showSnackBar('ไม่สามารถเรียกคืนไฟล์ได้: $e', Colors.redAccent);
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

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              currentFile != null ? p.basename(currentFile.path) : 'Photo Culler',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            if (hasImages)
              Text(
                'ภาพที่ ${_currentIndex + 1} จาก ${_imageFiles.length} '
                '${_isZoomed ? "(โหมดซูม - แตะ 2 ครั้งเพื่อออก)" : ""}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'ย้อนกลับภาพเมื่อสักครู่',
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
                    // แถบบอกทิศทางรอบขอบจอ
                    _buildDirectionGuides(),

                    // การ์ดรูปภาพหลักที่ซูมและปัดได้
                    _buildSwipeableCard(currentFile!),

                    // ป้ายกำกับสถานะขณะลากนิ้ว
                    if (activeAction != null) _buildActionBadge(activeAction),

                    // ปุ่มกดด้านล่าง (เผื่อไม่อยากปัดหรือต้องการกดเร็วๆ)
                    Positioned(
                      bottom: 20,
                      child: _buildManualControlBar(),
                    ),
                  ],
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
                  : 'เลือกโฟลเดอร์เพื่อเริ่มคัดเลือกรูปภาพ\n(รองรับ JPG, PNG, HEIC, WEBP และ Sony .ARW)',
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
                label: const Text('ย้อนกลับภาพล่าสุด'),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildSwipeableCard(File file) {
    final imageBytes = _imageBytesCache[file.path];
    final ext = p.extension(file.path).toLowerCase();

    return Listener(
      onPointerDown: (_) => _pointerCount++,
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
        // อนุญาตให้ปัดการ์ดเฉพาะตอนใช้นิ้วเดียว และไม่ได้อยู่ในโหมดซูม
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
                  PhotoView.customChild(
                    key: ValueKey(file.path),
                    scaleStateController: _scaleStateController,
                    scaleStateChangedCallback: (state) {
                      setState(() {
                        _isZoomed = state != PhotoViewScaleState.initial;
                        if (_isZoomed) _dragOffset = Offset.zero;
                      });
                    },
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 4.0,
                    backgroundDecoration: const BoxDecoration(color: Colors.black),
                    child: Image.memory(
                      imageBytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  )
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
                      return PhotoView.customChild(
                        scaleStateController: _scaleStateController,
                        scaleStateChangedCallback: (state) {
                          setState(() {
                            _isZoomed = state != PhotoViewScaleState.initial;
                          });
                        },
                        minScale: PhotoViewComputedScale.contained,
                        maxScale: PhotoViewComputedScale.covered * 4.0,
                        child: Image.memory(snapshot.data!, fit: BoxFit.contain),
                      );
                    },
                  ),

                // ป้ายกำกับมุมขวาบนกรณีเป็นไฟล์ RAW (.ARW)
                if (ext == '.arw')
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.85),
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
          color: Colors.black.withOpacity(0.75),
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
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 80),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('▲ ปัดขึ้น: ดีที่สุด (ใช้ทันที)',
                style: TextStyle(color: Colors.white24, fontSize: 11)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('◀ ซ้าย: คัดทิ้ง',
                    style: TextStyle(color: Colors.white24, fontSize: 11)),
                Text('ขวา: เก็บไว้ ▶',
                    style: TextStyle(color: Colors.white24, fontSize: 11)),
              ],
            ),
            const Text('▼ ปัดลง: ภาพบรรยากาศ',
                style: TextStyle(color: Colors.white24, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildManualControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[900]?.withOpacity(0.9),
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

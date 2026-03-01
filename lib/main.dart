import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

const Size _compactWindowSize = Size(88, 88);
const Size _expandedWindowSize = Size(400, 560);
const double _assistantHomePopupWidth = 320;
const double _assistantDetailPopupWidth = 640;
const double _assistantSettingsPopupWidth = 920;
const bool _isFlutterTest = bool.fromEnvironment('FLUTTER_TEST');
const double _windowMarginRight = 24;
const double _windowMarginBottom = 24;
const String _fileVaultDbName = 'arya_file_vault.db';

Future<void> main([List<String> args = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();

  final subWindowLaunch = _parseSubWindowLaunch(args);
  if (subWindowLaunch != null) {
    runApp(
      SettingsWindowApp(
        windowController: WindowController.fromWindowId(
          subWindowLaunch.windowId,
        ),
      ),
    );
    return;
  }

  await _configureDesktopWindow();
  runApp(const AryaApp());
}

class _SubWindowLaunch {
  const _SubWindowLaunch({required this.windowId, required this.arguments});

  final int windowId;
  final Map<String, dynamic> arguments;
}

_SubWindowLaunch? _parseSubWindowLaunch(List<String> args) {
  final markerIndex = args.indexOf('multi_window');
  if (markerIndex == -1 || markerIndex + 1 >= args.length) {
    return null;
  }

  final windowId = int.tryParse(args[markerIndex + 1]);
  if (windowId == null) {
    return null;
  }

  var arguments = <String, dynamic>{};
  if (markerIndex + 2 < args.length && args[markerIndex + 2].isNotEmpty) {
    try {
      final decoded = jsonDecode(args[markerIndex + 2]);
      if (decoded is Map<String, dynamic>) {
        arguments = decoded;
      } else if (decoded is Map) {
        arguments = decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      // Ignore malformed payloads; window id is enough to launch subwindow UI.
    }
  }

  return _SubWindowLaunch(windowId: windowId, arguments: arguments);
}

bool get _supportsDesktopWindowControls {
  if (_isFlutterTest || kIsWeb) {
    return false;
  }
  if (Platform.environment.containsKey('FLUTTER_TEST') ||
      Platform.environment.containsKey('DART_TEST')) {
    return false;
  }
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

Future<void> _configureDesktopWindow() async {
  if (!_supportsDesktopWindowControls) {
    return;
  }

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: _compactWindowSize,
    minimumSize: _compactWindowSize,
    center: false,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Colors.transparent,
  );

  await windowManager.waitUntilReadyToShow(options);
  await windowManager.setAsFrameless();
  if (!Platform.isMacOS) {
    await windowManager.setAlwaysOnTop(true);
  }
  await windowManager.setResizable(false);
  await windowManager.setMinimizable(false);
  await windowManager.setMaximizable(false);
  await windowManager.setHasShadow(false);
  await windowManager.setSkipTaskbar(true);

  if (Platform.isMacOS) {
    await windowManager.setVisibleOnAllWorkspaces(
      true,
      visibleOnFullScreen: true,
    );
    await windowManager.focus();
  }

  await _positionWindowAtBottomRight();
  await windowManager.show();
  await windowManager.focus();
}

Future<void> _positionWindowAtBottomRight() async {
  final display = await screenRetriever.getPrimaryDisplay();
  final visiblePosition = display.visiblePosition ?? Offset.zero;
  final visibleSize = display.visibleSize ?? display.size;

  final target = Offset(
    visiblePosition.dx +
        visibleSize.width -
        _compactWindowSize.width -
        _windowMarginRight,
    visiblePosition.dy +
        visibleSize.height -
        _compactWindowSize.height -
        _windowMarginBottom,
  );

  await windowManager.setPosition(target);
}

class AryaApp extends StatelessWidget {
  const AryaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arya',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      color: Colors.transparent,
      builder: (context, child) => ColoredBox(
        color: Colors.transparent,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const FloatingButtonScreen(),
    );
  }
}

class FileVaultEntry {
  const FileVaultEntry({
    required this.id,
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.addedAt,
  });

  final int id;
  final String path;
  final String name;
  final int sizeBytes;
  final DateTime addedAt;

  factory FileVaultEntry.fromMap(Map<String, Object?> map) {
    return FileVaultEntry(
      id: (map['id'] as num).toInt(),
      path: map['path'] as String,
      name: map['name'] as String,
      sizeBytes: (map['size_bytes'] as num?)?.toInt() ?? 0,
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['added_at'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

class FileVaultStore {
  FileVaultStore._();

  static final FileVaultStore instance = FileVaultStore._();
  Database? _database;

  Future<Database> _db() async {
    if (_database != null) {
      return _database!;
    }

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final supportDir = await _resolveSupportDir();
    final dbPath = p.join(supportDir.path, _fileVaultDbName);
    _database = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE file_vault_entries (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              path TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL,
              size_bytes INTEGER NOT NULL DEFAULT 0,
              added_at INTEGER NOT NULL
            )
          ''');
        },
      ),
    );
    return _database!;
  }

  Future<Directory> _resolveSupportDir() async {
    String basePath;

    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      basePath = home == null
          ? Directory.current.path
          : p.join(home, 'Library', 'Application Support');
    } else if (Platform.isLinux) {
      final xdgData = Platform.environment['XDG_DATA_HOME'];
      if (xdgData != null && xdgData.isNotEmpty) {
        basePath = xdgData;
      } else {
        final home = Platform.environment['HOME'];
        basePath = home == null
            ? Directory.current.path
            : p.join(home, '.local', 'share');
      }
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      final localAppData = Platform.environment['LOCALAPPDATA'];
      basePath = (appData != null && appData.isNotEmpty)
          ? appData
          : ((localAppData != null && localAppData.isNotEmpty)
                ? localAppData
                : Directory.current.path);
    } else {
      basePath = Directory.current.path;
    }

    final dir = Directory(p.join(basePath, 'Arya'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<List<FileVaultEntry>> listEntries() async {
    final db = await _db();
    final rows = await db.query('file_vault_entries', orderBy: 'added_at DESC');
    return rows.map(FileVaultEntry.fromMap).toList();
  }

  Future<void> addPaths(List<String> paths) async {
    if (paths.isEmpty) {
      return;
    }
    final db = await _db();
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final filePath in paths) {
      final normalized = filePath.trim();
      if (normalized.isEmpty) {
        continue;
      }
      final file = File(normalized);
      if (!await file.exists()) {
        continue;
      }
      final stat = await file.stat();
      batch.insert('file_vault_entries', {
        'path': normalized,
        'name': p.basename(normalized),
        'size_bytes': stat.size,
        'added_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  Future<void> deleteById(int id) async {
    final db = await _db();
    await db.delete('file_vault_entries', where: 'id = ?', whereArgs: [id]);
  }
}

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key, required this.windowController});

  final WindowController windowController;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  int _selectedTabIndex = 0;
  bool _isFileVaultLoading = false;
  bool _isAddingFiles = false;
  bool _hasLoadedFileVault = false;
  String? _fileVaultError;
  List<FileVaultEntry> _fileVaultEntries = const [];

  static const List<String> _tabs = [
    'General',
    'AI Settings',
    'File Vault',
    'Password Vault',
    'Payment Vault',
  ];

  bool get _isFileVaultTab => _selectedTabIndex == 2;

  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'windowType') {
        return 'settings';
      }
      return null;
    });
  }

  Future<void> _loadFileVaultEntries() async {
    if (_isFileVaultLoading) {
      return;
    }
    setState(() {
      _isFileVaultLoading = true;
      _fileVaultError = null;
    });
    try {
      final entries = await FileVaultStore.instance.listEntries();
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultEntries = entries;
        _hasLoadedFileVault = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultError = 'Unable to load files.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isFileVaultLoading = false;
        });
      }
    }
  }

  Future<void> _addFileVaultFiles() async {
    if (_isAddingFiles) {
      return;
    }
    setState(() {
      _isAddingFiles = true;
      _fileVaultError = null;
    });
    try {
      final paths = await _pickFilePaths();
      if (paths.isEmpty) {
        return;
      }
      await FileVaultStore.instance.addPaths(paths);
      await _loadFileVaultEntries();
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultError =
            'File picker timed out. Please retry and keep the settings window focused.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      debugPrint('File picker failed: $error');
      setState(() {
        _fileVaultError = 'Unable to add selected files.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isAddingFiles = false;
        });
      }
    }
  }

  Future<void> _lowerWindowLevel() async {
    if (!_supportsDesktopWindowControls) {
      return;
    }
    if (Platform.isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(false);
    }
    await windowManager.setAlwaysOnTop(false);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> _restoreWindowLevel() async {
    if (!_supportsDesktopWindowControls) {
      return;
    }
    if (Platform.isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(
        true,
        visibleOnFullScreen: true,
      );
    } else {
      await windowManager.setAlwaysOnTop(true);
    }
    await windowManager.focus();
  }

  Future<List<String>> _pickFilePaths() async {
    await _lowerWindowLevel();
    try {
      if (Platform.isMacOS) {
        return _pickFilePathsMacOS();
      }

      const typeGroup = XTypeGroup(label: 'All files', extensions: <String>[]);
      final files = await openFiles(
        acceptedTypeGroups: [typeGroup],
      ).timeout(const Duration(seconds: 90));
      return files.map((file) => file.path).where((p) => p.isNotEmpty).toList();
    } finally {
      await _restoreWindowLevel();
    }
  }

  Future<List<String>> _pickFilePathsMacOS() async {
    final result = await Process.run('osascript', [
      '-e',
      'set pickedFiles to choose file with prompt "Select file(s) for Arya File Vault" with multiple selections allowed',
      '-e',
      'set outputPaths to {}',
      '-e',
      'repeat with oneFile in pickedFiles',
      '-e',
      'set end of outputPaths to POSIX path of oneFile',
      '-e',
      'end repeat',
      '-e',
      'set AppleScript\'s text item delimiters to linefeed',
      '-e',
      'return outputPaths as text',
    ]).timeout(const Duration(seconds: 90));

    if (result.exitCode != 0) {
      final errorText = '${result.stderr}'.toLowerCase();
      if (errorText.contains('user canceled')) {
        return const [];
      }
      throw Exception('osascript picker failed: ${result.stderr}');
    }

    final stdoutText = '${result.stdout}'.trim();
    if (stdoutText.isEmpty) {
      return const [];
    }
    return stdoutText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  Future<void> _deleteFileVaultEntry(FileVaultEntry entry) async {
    try {
      await FileVaultStore.instance.deleteById(entry.id);
      await _loadFileVaultEntries();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultError = 'Unable to delete file.';
      });
    }
  }

  void _onTabSelected(int index) {
    if (_selectedTabIndex == index) {
      return;
    }
    setState(() {
      _selectedTabIndex = index;
      _fileVaultError = null;
    });
    if (index == 2 && !_hasLoadedFileVault) {
      _loadFileVaultEntries();
    }
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    final decimals = size >= 100 || unitIndex == 0 ? 0 : 1;
    return '${size.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  String _formatAddedAt(DateTime dt) {
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _fileVaultBody() {
    if (_isFileVaultLoading && !_hasLoadedFileVault) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1F80E9)),
      );
    }

    if (_fileVaultEntries.isEmpty) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF252F3D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF313D4D), width: 1),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 34,
                color: Color(0xFF89B2DC),
              ),
              SizedBox(height: 12),
              Text(
                'No files in your vault yet.',
                style: TextStyle(
                  color: Color(0xFFD8E0EB),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Click Add to import one or more files.',
                style: TextStyle(color: Color(0xFF9FADBF), fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _fileVaultEntries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = _fileVaultEntries[index];
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF252F3D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF313D4D), width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E4F7A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.insert_drive_file_rounded,
                  color: Color(0xFF8CC4FF),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFE7EDF7),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF94A3B6),
                        fontSize: 11.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_formatBytes(entry.sizeBytes)}  •  Added ${_formatAddedAt(entry.addedAt)}',
                      style: const TextStyle(
                        color: Color(0xFFB3C0D0),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Delete',
                onPressed: () => _deleteFileVaultEntry(entry),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFFE07E7E),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _settingsTabTile(int index, String label) {
    final selected = index == _selectedTabIndex;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTabSelected(index),
        child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2A3A4C) : Colors.transparent,
            border: const Border(
              bottom: BorderSide(color: Color(0xFF2A3441), width: 1),
            ),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFFE6EDF8)
                    : const Color(0xFFAAB3C2),
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsTabBody() {
    switch (_selectedTabIndex) {
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add files to your local vault. Data is stored locally on this device.',
              style: TextStyle(color: Color(0xFF9FAABC), fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (_fileVaultError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _fileVaultError!,
                  style: const TextStyle(
                    color: Color(0xFFE58E8E),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Expanded(child: _fileVaultBody()),
          ],
        );
      default:
        return const Text(
          'Configuration panel coming next.',
          style: TextStyle(color: Color(0xFF9FAABC), fontSize: 13),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arya Settings',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF1A212A),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: 58,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: const BoxDecoration(
                  color: Color(0xFF2A323B),
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF38414B), width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Settings',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => widget.windowController.hide(),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, color: Color(0xFFA9B2BE)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 220,
                      decoration: const BoxDecoration(
                        color: Color(0xFF202936),
                        border: Border(
                          right: BorderSide(color: Color(0xFF2C3643), width: 1),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Padding(
                            padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
                            child: Text(
                              'Categories',
                              style: TextStyle(
                                color: Color(0xFF98A4B5),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                          Expanded(
                            child: ListView(
                              padding: EdgeInsets.zero,
                              children: [
                                for (var i = 0; i < _tabs.length; i++)
                                  _settingsTabTile(i, _tabs[i]),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Color(0xFF1B2330), Color(0xFF18202B)],
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    _tabs[_selectedTabIndex],
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (_isFileVaultTab)
                                    SizedBox(
                                      height: 34,
                                      width: 92,
                                      child: ElevatedButton.icon(
                                        onPressed: _isAddingFiles
                                            ? null
                                            : _addFileVaultFiles,
                                        style: ElevatedButton.styleFrom(
                                          elevation: 0,
                                          backgroundColor: const Color(
                                            0xFF1F80E9,
                                          ),
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                        icon: _isAddingFiles
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: Colors.white,
                                                    ),
                                              )
                                            : const Icon(Icons.add, size: 16),
                                        label: const Text(
                                          'Add',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    )
                                  else
                                    SizedBox(
                                      height: 34,
                                      width: 78,
                                      child: ElevatedButton(
                                        onPressed: () {},
                                        style: ElevatedButton.styleFrom(
                                          elevation: 0,
                                          padding: EdgeInsets.zero,
                                          backgroundColor: const Color(
                                            0xFF1F80E9,
                                          ),
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                        child: const Text(
                                          'Save',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: KeyedSubtree(
                                  key: ValueKey(_selectedTabIndex),
                                  child: _settingsTabBody(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FloatingButtonScreen extends StatefulWidget {
  const FloatingButtonScreen({super.key});

  @override
  State<FloatingButtonScreen> createState() => _FloatingButtonScreenState();
}

enum _AssistantView {
  home,
  chat,
  guideMe,
  takeAction,
  entertainment,
  learnFromMe,
  settings,
}

class _FloatingButtonScreenState extends State<FloatingButtonScreen> {
  bool _isWindowOpen = false;
  _AssistantView _currentView = _AssistantView.home;
  int _selectedSettingsTabIndex = 0;
  bool _isFileVaultLoading = false;
  bool _isAddingFiles = false;
  bool _hasLoadedFileVault = false;
  String? _fileVaultError;
  List<FileVaultEntry> _fileVaultEntries = const [];

  static const List<String> _settingsTabs = [
    'General',
    'AI Settings',
    'File Vault',
    'Password Vault',
    'Payment Vault',
  ];

  bool get _isFileVaultTab => _selectedSettingsTabIndex == 2;

  Widget _assistantRow({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF26496C),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFF1E90FF), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF9EA5AF),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFF666D77),
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleWindow() async {
    final nextState = !_isWindowOpen;
    if (_supportsDesktopWindowControls) {
      await _resizeWindowKeepingBottomRightAnchor(
        nextState ? _expandedWindowSize : _compactWindowSize,
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isWindowOpen = nextState;
      if (nextState) {
        _currentView = _AssistantView.home;
      }
    });
  }

  Future<void> _openAssistantView(_AssistantView view) async {
    if (_supportsDesktopWindowControls) {
      await _resizeWindowKeepingBottomRightAnchor(
        await _assistantWindowSizeForView(view),
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _currentView = view;
    });
  }

  Future<void> _goBackToAssistantHome() async {
    if (_supportsDesktopWindowControls) {
      await _resizeWindowKeepingBottomRightAnchor(_expandedWindowSize);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _currentView = _AssistantView.home;
    });
  }

  Future<Size> _assistantWindowSizeForView(_AssistantView view) async {
    if (view == _AssistantView.home) {
      return _expandedWindowSize;
    }

    final display = await screenRetriever.getPrimaryDisplay();
    final visibleSize = display.visibleSize ?? display.size;
    final maxWidth = (visibleSize.width - (_windowMarginRight * 2)).toDouble();
    final maxHeight = (visibleSize.height - (_windowMarginBottom * 2))
        .toDouble();
    final targetHeight = visibleSize.height * 0.9;
    final targetWidth = view == _AssistantView.settings
        ? _assistantSettingsPopupWidth + 32
        : _assistantDetailPopupWidth + 32;

    return Size(
      targetWidth <= maxWidth ? targetWidth : maxWidth,
      targetHeight <= maxHeight ? targetHeight : maxHeight,
    );
  }

  String _assistantViewTitle(_AssistantView view) {
    switch (view) {
      case _AssistantView.home:
        return 'Agent Assistant';
      case _AssistantView.chat:
        return 'Chat';
      case _AssistantView.guideMe:
        return 'Guide Me';
      case _AssistantView.takeAction:
        return 'Take Action';
      case _AssistantView.entertainment:
        return 'Entertainment';
      case _AssistantView.learnFromMe:
        return 'Learn from me';
      case _AssistantView.settings:
        return 'Settings';
    }
  }

  Widget _assistantMainContent() {
    if (_currentView == _AssistantView.home) {
      return Container(
        width: double.infinity,
        color: const Color(0xFF373E47),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _assistantRow(
              icon: Icons.chat_bubble,
              title: 'Chat',
              subtitle: 'Ask me anything',
              onTap: () {
                _openAssistantView(_AssistantView.chat);
              },
            ),
            _assistantRow(
              icon: Icons.lightbulb,
              title: 'Guide Me',
              subtitle: 'Step-by-step assistance',
              onTap: () {
                _openAssistantView(_AssistantView.guideMe);
              },
            ),
            _assistantRow(
              icon: Icons.bolt,
              title: 'Take Action',
              subtitle: 'Automate this task',
              onTap: () {
                _openAssistantView(_AssistantView.takeAction);
              },
            ),
            _assistantRow(
              icon: Icons.movie_filter_outlined,
              title: 'Entertainment',
              subtitle: 'Fun, content, and interactive moments',
              onTap: () {
                _openAssistantView(_AssistantView.entertainment);
              },
            ),
            _assistantRow(
              icon: Icons.psychology_alt_outlined,
              title: 'Learn from me',
              subtitle: 'Teach Arya how to do something',
              onTap: () {
                _openAssistantView(_AssistantView.learnFromMe);
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      );
    }

    if (_currentView == _AssistantView.settings) {
      return _assistantSettingsContent();
    }

    return const SizedBox.expand(child: ColoredBox(color: Color(0xFF373E47)));
  }

  Future<void> _loadFileVaultEntries() async {
    if (_isFileVaultLoading) {
      return;
    }
    setState(() {
      _isFileVaultLoading = true;
      _fileVaultError = null;
    });
    try {
      final entries = await FileVaultStore.instance.listEntries();
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultEntries = entries;
        _hasLoadedFileVault = true;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultError = 'Unable to load files.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isFileVaultLoading = false;
        });
      }
    }
  }

  Future<void> _addFileVaultFiles() async {
    if (_isAddingFiles) {
      return;
    }
    setState(() {
      _isAddingFiles = true;
      _fileVaultError = null;
    });
    try {
      final paths = await _pickFilePaths();
      if (paths.isEmpty) {
        return;
      }
      await FileVaultStore.instance.addPaths(paths);
      await _loadFileVaultEntries();
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultError =
            'File picker timed out. Please retry and keep the settings window focused.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultError = 'Unable to add selected files.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isAddingFiles = false;
        });
      }
    }
  }

  Future<List<String>> _pickFilePaths() async {
    await _lowerWindowLevel();
    try {
      if (Platform.isMacOS) {
        return _pickFilePathsMacOS();
      }

      const typeGroup = XTypeGroup(label: 'All files', extensions: <String>[]);
      final files = await openFiles(
        acceptedTypeGroups: [typeGroup],
      ).timeout(const Duration(seconds: 90));
      return files.map((file) => file.path).where((p) => p.isNotEmpty).toList();
    } finally {
      await _restoreWindowLevel();
    }
  }

  Future<List<String>> _pickFilePathsMacOS() async {
    final result = await Process.run('osascript', [
      '-e',
      'set pickedFiles to choose file with prompt "Select file(s) for Arya File Vault" with multiple selections allowed',
      '-e',
      'set outputPaths to {}',
      '-e',
      'repeat with oneFile in pickedFiles',
      '-e',
      'set end of outputPaths to POSIX path of oneFile',
      '-e',
      'end repeat',
      '-e',
      'set AppleScript\'s text item delimiters to linefeed',
      '-e',
      'return outputPaths as text',
    ]).timeout(const Duration(seconds: 90));

    if (result.exitCode != 0) {
      final errorText = '${result.stderr}'.toLowerCase();
      if (errorText.contains('user canceled')) {
        return const [];
      }
      throw Exception('osascript picker failed: ${result.stderr}');
    }

    final stdoutText = '${result.stdout}'.trim();
    if (stdoutText.isEmpty) {
      return const [];
    }
    return stdoutText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  Future<void> _lowerWindowLevel() async {
    if (!_supportsDesktopWindowControls) {
      return;
    }
    if (Platform.isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(false);
    }
    await windowManager.setAlwaysOnTop(false);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> _restoreWindowLevel() async {
    if (!_supportsDesktopWindowControls) {
      return;
    }
    if (Platform.isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(
        true,
        visibleOnFullScreen: true,
      );
    } else {
      await windowManager.setAlwaysOnTop(true);
    }
    await windowManager.focus();
  }

  Future<void> _deleteFileVaultEntry(FileVaultEntry entry) async {
    try {
      await FileVaultStore.instance.deleteById(entry.id);
      await _loadFileVaultEntries();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fileVaultError = 'Unable to delete file.';
      });
    }
  }

  void _onSettingsTabSelected(int index) {
    if (_selectedSettingsTabIndex == index) {
      return;
    }
    setState(() {
      _selectedSettingsTabIndex = index;
      _fileVaultError = null;
    });
    if (index == 2 && !_hasLoadedFileVault) {
      _loadFileVaultEntries();
    }
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    final decimals = size >= 100 || unitIndex == 0 ? 0 : 1;
    return '${size.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  String _formatAddedAt(DateTime dt) {
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _fileVaultBody() {
    if (_isFileVaultLoading && !_hasLoadedFileVault) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1F80E9)),
      );
    }

    if (_fileVaultEntries.isEmpty) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF252F3D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF313D4D), width: 1),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 34,
                color: Color(0xFF89B2DC),
              ),
              SizedBox(height: 12),
              Text(
                'No files in your vault yet.',
                style: TextStyle(
                  color: Color(0xFFD8E0EB),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Click Add to import one or more files.',
                style: TextStyle(color: Color(0xFF9FADBF), fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _fileVaultEntries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = _fileVaultEntries[index];
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF252F3D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF313D4D), width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E4F7A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.insert_drive_file_rounded,
                  color: Color(0xFF8CC4FF),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFE7EDF7),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF94A3B6),
                        fontSize: 11.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_formatBytes(entry.sizeBytes)}  •  Added ${_formatAddedAt(entry.addedAt)}',
                      style: const TextStyle(
                        color: Color(0xFFB3C0D0),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Delete',
                onPressed: () => _deleteFileVaultEntry(entry),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFFE07E7E),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _settingsTabTile(int index, String label) {
    final selected = index == _selectedSettingsTabIndex;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onSettingsTabSelected(index),
        child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2A3A4C) : Colors.transparent,
            border: const Border(
              bottom: BorderSide(color: Color(0xFF2A3441), width: 1),
            ),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFFE6EDF8)
                    : const Color(0xFFAAB3C2),
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsTabBody() {
    switch (_selectedSettingsTabIndex) {
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add files to your local vault. Data is stored locally on this device.',
              style: TextStyle(color: Color(0xFF9FAABC), fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (_fileVaultError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _fileVaultError!,
                  style: const TextStyle(
                    color: Color(0xFFE58E8E),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Expanded(child: _fileVaultBody()),
          ],
        );
      default:
        return const Text(
          'Configuration panel coming next.',
          style: TextStyle(color: Color(0xFF9FAABC), fontSize: 13),
        );
    }
  }

  Widget _assistantSettingsContent() {
    return Row(
      children: [
        Container(
          width: 220,
          decoration: const BoxDecoration(
            color: Color(0xFF202936),
            border: Border(
              right: BorderSide(color: Color(0xFF2C3643), width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: Text(
                  'Categories',
                  style: TextStyle(
                    color: Color(0xFF98A4B5),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (var i = 0; i < _settingsTabs.length; i++)
                      _settingsTabTile(i, _settingsTabs[i]),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFF1B2330), Color(0xFF18202B)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _settingsTabs[_selectedSettingsTabIndex],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (_isFileVaultTab)
                        SizedBox(
                          height: 34,
                          width: 92,
                          child: ElevatedButton.icon(
                            onPressed: _isAddingFiles ? null : _addFileVaultFiles,
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              backgroundColor: const Color(0xFF1F80E9),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon: _isAddingFiles
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.add, size: 16),
                            label: const Text(
                              'Add',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        )
                      else
                        SizedBox(
                          height: 34,
                          width: 78,
                          child: ElevatedButton(
                            onPressed: () {},
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              padding: EdgeInsets.zero,
                              backgroundColor: const Color(0xFF1F80E9),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text(
                              'Save',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: KeyedSubtree(
                      key: ValueKey(_selectedSettingsTabIndex),
                      child: _settingsTabBody(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _resizeWindowKeepingBottomRightAnchor(Size nextSize) async {
    final currentPosition = await windowManager.getPosition();
    final currentSize = await windowManager.getSize();

    final nextPosition = Offset(
      currentPosition.dx + currentSize.width - nextSize.width,
      currentPosition.dy + currentSize.height - nextSize.height,
    );

    await windowManager.setBounds(
      Rect.fromLTWH(
        nextPosition.dx,
        nextPosition.dy,
        nextSize.width,
        nextSize.height,
      ),
      animate: true,
    );
  }

  Future<void> _startNativeDrag() async {
    if (!_supportsDesktopWindowControls) {
      return;
    }
    await windowManager.startDragging();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              right: 16,
              bottom: 16,
              child: GestureDetector(
                onPanStart: (_) => _startNativeDrag(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _isWindowOpen
                          ? MediaQuery(
                              data: MediaQuery.of(
                                context,
                              ).copyWith(textScaler: TextScaler.noScaling),
                              child: Container(
                                key: const ValueKey('popup'),
                                width: _currentView == _AssistantView.home
                                    ? _assistantHomePopupWidth
                                    : (MediaQuery.of(context).size.width - 32)
                                          .clamp(
                                            _assistantHomePopupWidth,
                                            _currentView ==
                                                    _AssistantView.settings
                                                ? _assistantSettingsPopupWidth
                                                : _assistantDetailPopupWidth,
                                          ),
                                height: _currentView == _AssistantView.home
                                    ? null
                                    : (MediaQuery.of(context).size.height - 96)
                                          .clamp(
                                            320,
                                            MediaQuery.of(context).size.height,
                                          ),
                                margin: const EdgeInsets.only(bottom: 12),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: ColoredBox(
                                    color: const Color(0xFF47505A),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize:
                                          _currentView == _AssistantView.home
                                          ? MainAxisSize.min
                                          : MainAxisSize.max,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            16,
                                            14,
                                            16,
                                            12,
                                          ),
                                          child: Row(
                                            children: [
                                              if (_currentView ==
                                                  _AssistantView.home) ...[
                                                const Icon(
                                                  Icons.circle,
                                                  color: Color(0xFF1F7ACF),
                                                  size: 9,
                                                ),
                                                const SizedBox(width: 10),
                                                Text(
                                                  _assistantViewTitle(
                                                    _currentView,
                                                  ),
                                                  style: const TextStyle(
                                                    color: Color(0xFFE8E9EB),
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ] else ...[
                                                InkWell(
                                                  onTap: () {
                                                    _goBackToAssistantHome();
                                                  },
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: const Padding(
                                                    padding:
                                                        EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 6,
                                                        ),
                                                    child: Icon(
                                                      Icons.arrow_back_ios_new,
                                                      size: 14,
                                                      color: Color(0xFFD2D8DF),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Text(
                                                  _assistantViewTitle(
                                                    _currentView,
                                                  ),
                                                  style: const TextStyle(
                                                    color: Color(0xFFE8E9EB),
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        const Divider(
                                          height: 1,
                                          color: Color(0xFF5B626C),
                                        ),
                                        _currentView == _AssistantView.home
                                            ? _assistantMainContent()
                                            : Expanded(
                                                child: _assistantMainContent(),
                                              ),
                                        if (_currentView == _AssistantView.home)
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 10,
                                            ),
                                            decoration: const BoxDecoration(
                                              color: Color(0xFF4E5661),
                                              borderRadius:
                                                  BorderRadius.vertical(
                                                    bottom: Radius.circular(11),
                                                  ),
                                            ),
                                            child: Row(
                                              children: [
                                                const Text(
                                                  'Powered by AgentOS',
                                                  style: TextStyle(
                                                    color: Color(0xFFA4AAB2),
                                                    fontSize: 10.5,
                                                  ),
                                                ),
                                                const Spacer(),
                                                InkWell(
                                                  onTap: () {
                                                    _openAssistantView(
                                                      _AssistantView.settings,
                                                    );
                                                  },
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                  child: const Padding(
                                                    padding: EdgeInsets.all(4),
                                                    child: Icon(
                                                      Icons.settings,
                                                      size: 15,
                                                      color: Color(0xFFA4AAB2),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(key: ValueKey('empty')),
                    ),
                    FloatingActionButton(
                      onPressed: _toggleWindow,
                      tooltip: '',
                      backgroundColor: const Color(0xFF1F80E9),
                      foregroundColor: Colors.white,
                      child: Icon(
                        _isWindowOpen
                            ? Icons.close
                            : Icons.auto_awesome_rounded,
                      ),
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

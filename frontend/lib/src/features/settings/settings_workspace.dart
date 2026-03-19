import 'dart:async';
import 'dart:io';

import 'package:arya_app/src/core/window_helpers.dart';
import 'package:arya_app/src/features/file_vault/file_vault_entry.dart';
import 'package:arya_app/src/features/file_vault/file_vault_store.dart';
import 'package:arya_app/src/features/settings/pages/ai_settings_page.dart';
import 'package:arya_app/src/features/settings/pages/file_vault_settings_page.dart';
import 'package:arya_app/src/features/settings/pages/general_settings_page.dart';
import 'package:arya_app/src/features/settings/pages/password_vault_settings_page.dart';
import 'package:arya_app/src/features/settings/pages/payment_vault_settings_page.dart';
import 'package:arya_app/src/features/settings/settings_tab.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class SettingsWorkspace extends StatefulWidget {
  const SettingsWorkspace({super.key});

  @override
  State<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends State<SettingsWorkspace> {
  SettingsTab _selectedTab = SettingsTab.general;
  bool _isFileVaultLoading = false;
  bool _isAddingFiles = false;
  bool _hasLoadedFileVault = false;
  String? _fileVaultError;
  List<FileVaultEntry> _fileVaultEntries = const [];

  bool get _isFileVaultTab => _selectedTab == SettingsTab.fileVault;

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
      return files
          .map((file) => file.path)
          .where((path) => path.isNotEmpty)
          .toList();
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
    if (!supportsDesktopWindowControls) {
      return;
    }
    if (Platform.isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(false);
    }
    await windowManager.setAlwaysOnTop(false);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> _restoreWindowLevel() async {
    if (!supportsDesktopWindowControls) {
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

  void _onTabSelected(SettingsTab tab) {
    if (_selectedTab == tab) {
      return;
    }
    setState(() {
      _selectedTab = tab;
      _fileVaultError = null;
    });
    if (tab == SettingsTab.fileVault && !_hasLoadedFileVault) {
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
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _settingsTabBody() {
    switch (_selectedTab) {
      case SettingsTab.general:
        return const GeneralSettingsPage();
      case SettingsTab.aiSettings:
        return const AiSettingsPage();
      case SettingsTab.fileVault:
        return FileVaultSettingsPage(
          isLoading: _isFileVaultLoading,
          hasLoaded: _hasLoadedFileVault,
          error: _fileVaultError,
          entries: _fileVaultEntries,
          onDelete: _deleteFileVaultEntry,
          formatBytes: _formatBytes,
          formatAddedAt: _formatAddedAt,
        );
      case SettingsTab.passwordVault:
        return const PasswordVaultSettingsPage();
      case SettingsTab.paymentVault:
        return const PaymentVaultSettingsPage();
    }
  }

  Widget _settingsTabTile(SettingsTab tab) {
    final selected = tab == _selectedTab;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTabSelected(tab),
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
              tab.label,
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

  @override
  Widget build(BuildContext context) {
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
                  children: SettingsTab.values.map(_settingsTabTile).toList(),
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
                        _selectedTab.label,
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
                      else if (_selectedTab != SettingsTab.aiSettings)
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
                      key: ValueKey(_selectedTab),
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
}

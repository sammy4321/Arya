import 'package:arya_app/src/features/file_vault/file_vault_entry.dart';
import 'package:flutter/material.dart';

class FileVaultSettingsPage extends StatelessWidget {
  const FileVaultSettingsPage({
    super.key,
    required this.isLoading,
    required this.hasLoaded,
    required this.error,
    required this.entries,
    required this.onDelete,
    required this.formatBytes,
    required this.formatAddedAt,
  });

  final bool isLoading;
  final bool hasLoaded;
  final String? error;
  final List<FileVaultEntry> entries;
  final ValueChanged<FileVaultEntry> onDelete;
  final String Function(int bytes) formatBytes;
  final String Function(DateTime dateTime) formatAddedAt;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Add files to your local vault. Data is stored locally on this device.',
          style: TextStyle(color: Color(0xFF9FAABC), fontSize: 13),
        ),
        const SizedBox(height: 12),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              error!,
              style: const TextStyle(
                color: Color(0xFFE58E8E),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Expanded(
          child: _FileVaultList(
            isLoading: isLoading,
            hasLoaded: hasLoaded,
            entries: entries,
            onDelete: onDelete,
            formatBytes: formatBytes,
            formatAddedAt: formatAddedAt,
          ),
        ),
      ],
    );
  }
}

class _FileVaultList extends StatelessWidget {
  const _FileVaultList({
    required this.isLoading,
    required this.hasLoaded,
    required this.entries,
    required this.onDelete,
    required this.formatBytes,
    required this.formatAddedAt,
  });

  final bool isLoading;
  final bool hasLoaded;
  final List<FileVaultEntry> entries;
  final ValueChanged<FileVaultEntry> onDelete;
  final String Function(int bytes) formatBytes;
  final String Function(DateTime dateTime) formatAddedAt;

  @override
  Widget build(BuildContext context) {
    if (isLoading && !hasLoaded) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1F80E9)),
      );
    }

    if (entries.isEmpty) {
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
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = entries[index];
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
                      '${formatBytes(entry.sizeBytes)}  •  Added ${formatAddedAt(entry.addedAt)}',
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
                onPressed: () => onDelete(entry),
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
}

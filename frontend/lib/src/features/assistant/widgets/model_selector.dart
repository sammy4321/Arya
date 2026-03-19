import 'package:arya_app/src/features/settings/ai_settings_store.dart';
import 'package:flutter/material.dart';

/// A dropdown selector for OpenRouter models.
class ModelSelector extends StatefulWidget {
  const ModelSelector({
    required this.onModelSelected,
    this.initialModelId,
    super.key,
  });

  final ValueChanged<String> onModelSelected;
  final String? initialModelId;

  @override
  State<ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<ModelSelector> {
  bool _isLoading = false;
  bool _isDropdownOpen = false;
  String? _error;
  List<OpenRouterModel> _models = [];
  String _selectedModelId = '';
  String _searchQuery = '';

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _dropdownLink = LayerLink();
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _selectedModelId = widget.initialModelId ?? '';
    _loadModel();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _removeOverlay();
    super.dispose();
  }

  Future<void> _loadModel() async {
    final savedModel = await AiSettingsStore.instance.getModel();
    if (savedModel.isNotEmpty && mounted) {
      setState(() => _selectedModelId = savedModel);
    }
    _fetchModels();
  }

  Future<void> _fetchModels() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final models = await AiSettingsStore.instance.fetchModels();
      if (mounted) {
        setState(() => _models = models);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to load models');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _selectModel(OpenRouterModel model) async {
    setState(() => _selectedModelId = model.id);
    await AiSettingsStore.instance.setModel(model.id);
    widget.onModelSelected(model.id);
    _removeOverlay();
  }

  List<OpenRouterModel> get _filteredModels {
    if (_searchQuery.isEmpty) return _models;
    final q = _searchQuery.toLowerCase();
    return _models
        .where(
          (m) =>
              m.name.toLowerCase().contains(q) ||
              m.id.toLowerCase().contains(q),
        )
        .toList();
  }

  String get _displayLabel {
    if (_selectedModelId.isEmpty) return 'Select model';
    final match = _models.where((m) => m.id == _selectedModelId);
    if (match.isNotEmpty) return match.first.name;
    return _selectedModelId;
  }

  void _toggleDropdown() {
    if (_isDropdownOpen) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    _removeOverlay();
    _searchController.clear();
    _searchQuery = '';
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(builder: (_) => _buildOverlayDropdown());
    overlay.insert(_overlayEntry!);
    setState(() => _isDropdownOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (_isDropdownOpen && mounted) {
      setState(() => _isDropdownOpen = false);
    }
  }

  Widget _buildOverlayDropdown() {
    return StatefulBuilder(
      builder: (context, setOverlayState) {
        final filtered = _filteredModels;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _removeOverlay,
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
            CompositedTransformFollower(
              link: _dropdownLink,
              showWhenUnlinked: false,
              offset: const Offset(0, 40),
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFF2A3441),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 320,
                    maxHeight: 280,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search models...',
                            hintStyle: const TextStyle(
                              color: Color(0xFF6B7585),
                              fontSize: 12,
                            ),
                            prefixIcon: const Icon(
                              Icons.search,
                              color: Color(0xFF6B7585),
                              size: 16,
                            ),
                            filled: true,
                            fillColor: const Color(0xFF1B2330),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: BorderSide.none,
                            ),
                            isDense: true,
                          ),
                          onChanged: (value) {
                            _searchQuery = value;
                            setOverlayState(() {});
                          },
                        ),
                      ),
                      const Divider(height: 1, color: Color(0xFF3A4555)),
                      if (_isLoading)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF1F80E9),
                              ),
                            ),
                          ),
                        )
                      else if (filtered.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'No models found',
                            style: TextStyle(
                              color: Color(0xFF6B7585),
                              fontSize: 12,
                            ),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final model = filtered[index];
                              final isSelected = model.id == _selectedModelId;
                              return InkWell(
                                onTap: () => _selectModel(model),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  color: isSelected
                                      ? const Color(0xFF1F80E9)
                                          .withValues(alpha: 0.15)
                                      : Colors.transparent,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          model.name,
                                          style: TextStyle(
                                            color: isSelected
                                                ? const Color(0xFF5AABFF)
                                                : Colors.white,
                                            fontSize: 12,
                                            fontWeight: isSelected
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (isSelected)
                                        const Icon(
                                          Icons.check,
                                          color: Color(0xFF1F80E9),
                                          size: 16,
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _dropdownLink,
      child: GestureDetector(
        onTap: _isLoading && _models.isEmpty ? null : _toggleDropdown,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF373E47),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _isDropdownOpen
                  ? const Color(0xFF1F80E9)
                  : const Color(0xFF5B626C),
            ),
          ),
          child: SizedBox(
            height: 16,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_isLoading && _models.isEmpty)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF9EA5AF),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      _displayLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _selectedModelId.isEmpty
                            ? const Color(0xFF9EA5AF)
                            : const Color(0xFFE8E9EB),
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Icon(
                    _isDropdownOpen
                        ? Icons.arrow_drop_up
                        : Icons.arrow_drop_down,
                    color: const Color(0xFF9EA5AF),
                    size: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

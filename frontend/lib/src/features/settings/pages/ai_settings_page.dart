import 'package:arya_app/src/features/settings/ai_settings_store.dart';
import 'package:flutter/material.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final _apiKeyController = TextEditingController();
  final _tavilyApiKeyController = TextEditingController();
  bool _obscureApiKey = true;
  bool _obscureTavilyApiKey = true;
  bool _isSaving = false;
  String? _saveMessage;
  String _savedApiKey = '';
  String _savedTavilyApiKey = '';

  bool get _hasChanges =>
      _apiKeyController.text != _savedApiKey ||
      _tavilyApiKeyController.text != _savedTavilyApiKey;

  @override
  void initState() {
    super.initState();
    _apiKeyController.addListener(() => setState(() {}));
    _tavilyApiKeyController.addListener(() => setState(() {}));
    _loadSavedSettings();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _tavilyApiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedSettings() async {
    final store = AiSettingsStore.instance;
    final apiKey = await store.getApiKey();
    final tavilyApiKey = await store.getTavilyApiKey();
    if (!mounted) return;
    setState(() {
      _apiKeyController.text = apiKey;
      _tavilyApiKeyController.text = tavilyApiKey;
      _savedApiKey = apiKey;
      _savedTavilyApiKey = tavilyApiKey;
    });
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _saveMessage = null;
    });
    try {
      final store = AiSettingsStore.instance;
      await store.setApiKey(_apiKeyController.text);
      await store.setTavilyApiKey(_tavilyApiKeyController.text);
      if (!mounted) return;
      setState(() {
        _savedApiKey = _apiKeyController.text;
        _savedTavilyApiKey = _tavilyApiKeyController.text;
        _saveMessage = 'Settings saved.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveMessage = 'Failed to save settings.');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(top: 8),
      children: [
        // --- API Key row ---
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(
                width: 160,
                child: Text(
                  'OpenRouter API Key',
                  style: TextStyle(
                    color: Color(0xFFCDD4DE),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _apiKeyController,
                  obscureText: _obscureApiKey,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'sk-or-...',
                    hintStyle: const TextStyle(
                      color: Color(0xFF6B7585),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF2A3441),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF3A4555)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF3A4555)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF1F80E9)),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureApiKey ? Icons.visibility_off : Icons.visibility,
                        color: const Color(0xFF6B7585),
                        size: 18,
                      ),
                      onPressed: () {
                        setState(() => _obscureApiKey = !_obscureApiKey);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // --- Tavily API Key row ---
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(
                width: 160,
                child: Text(
                  'Tavily API Key',
                  style: TextStyle(
                    color: Color(0xFFCDD4DE),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _tavilyApiKeyController,
                  obscureText: _obscureTavilyApiKey,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'tvly-...',
                    hintStyle: const TextStyle(
                      color: Color(0xFF6B7585),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF2A3441),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF3A4555)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF3A4555)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF1F80E9)),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureTavilyApiKey
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: const Color(0xFF6B7585),
                        size: 18,
                      ),
                      onPressed: () {
                        setState(
                          () => _obscureTavilyApiKey = !_obscureTavilyApiKey,
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // --- Save button ---
        Row(
          children: [
            const SizedBox(width: 176), // align with input fields
            SizedBox(
              height: 36,
              width: 100,
              child: ElevatedButton(
                onPressed: _isSaving || !_hasChanges ? null : _save,
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  backgroundColor: const Color(0xFF1F80E9),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      const Color(0xFF1F80E9).withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Save',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            if (_saveMessage != null) ...[
              const SizedBox(width: 12),
              Text(
                _saveMessage!,
                style: TextStyle(
                  color: _saveMessage == 'Settings saved.'
                      ? const Color(0xFF81C784)
                      : const Color(0xFFE57373),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),

        const SizedBox(height: 8),

        // --- Helper text ---
        const Row(
          children: [
            SizedBox(width: 176),
            Text(
              'Keys are sent over HTTPS and stored on the backend.',
              style: TextStyle(color: Color(0xFF6B7585), fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'web_search_dialog.dart';

class ChatInput extends StatefulWidget {
  final bool isLoading;
  final Function(String) onSend;
  final String? errorText;
  final VoidCallback? onDismissError;

  const ChatInput({
    super.key,
    required this.isLoading,
    required this.onSend,
    this.errorText,
    this.onDismissError,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
  }

  void _handleSend() {
    final text = _controller.text;
    if (text.trim().isNotEmpty && !widget.isLoading) {
      widget.onSend(text);
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.errorText != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8.0),
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            decoration: BoxDecoration(
              color: const Color(0xFF2F2F2F),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.errorText!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.red, size: 20),
                  onPressed: widget.onDismissError,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF2F2F2F),
            borderRadius: BorderRadius.circular(24),
          ),
          padding: const EdgeInsets.only(left: 12.0, right: 12.0, top: 12.0, bottom: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top: Text Input
              TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: const InputDecoration(
                  hintText: 'Message Veraxi...',
                  hintStyle: TextStyle(color: Color(0xFF878787), fontSize: 16),
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onSubmitted: (_) => _handleSend(),
                enabled: !widget.isLoading,
                textInputAction: TextInputAction.send,
              ),
              const SizedBox(height: 4),
              // Bottom Row: Actions (Attachment, Tune/Tools | Mic, Send Arrow)
              Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    icon: const Icon(Icons.attach_file, color: Color(0xFFB4B4B4), size: 20),
                    onPressed: widget.isLoading ? null : () {},
                    tooltip: 'Attach file',
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.tune, color: Color(0xFFB4B4B4), size: 20),
                    tooltip: 'Tools',
                    color: const Color(0xFF171717),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: Color(0xFF2A2A2A)),
                    ),
                    position: PopupMenuPosition.under,
                    onSelected: (value) {
                      if (value == 'web_search') {
                        showDialog(
                          context: context,
                          builder: (context) => const WebSearchDialog(),
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      _buildToolItem('file_search', 'File Search', Icons.grid_view_outlined),
                      _buildWebSearchItem(),
                      _buildToolItem('skills', 'Skills', Icons.extension_outlined),
                      _buildToolItem('run_code', 'Run Code', Icons.terminal),
                      _buildToolItem('artifacts', 'Artifacts >', Icons.auto_awesome),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    icon: const Icon(Icons.mic_none_outlined, color: Color(0xFFB4B4B4), size: 20),
                    onPressed: widget.isLoading ? null : () {},
                    tooltip: 'Voice input',
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: (widget.isLoading || !_hasText) ? null : _handleSend,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _hasText ? Colors.white : const Color(0xFF424242),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: widget.isLoading
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _hasText ? Colors.black : Colors.white,
                                  ),
                                ),
                              )
                            : Icon(
                                Icons.arrow_upward,
                                color: _hasText ? Colors.black : const Color(0xFFB4B4B4),
                                size: 18,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _buildToolItem(String value, String text, IconData icon) {
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFB4B4B4), size: 16),
          const SizedBox(width: 12),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
          const Spacer(),
          const Icon(Icons.push_pin_outlined, color: Color(0xFF6E6E6E), size: 16),
        ],
      ),
    );
  }

  PopupMenuItem<String> _buildWebSearchItem() {
    return PopupMenuItem<String>(
      value: 'web_search',
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.language, color: Color(0xFFB4B4B4), size: 16),
          const SizedBox(width: 12),
          const Text('Web Search', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
          const Spacer(),
          const Icon(Icons.settings_outlined, color: Color(0xFF6E6E6E), size: 16),
          const SizedBox(width: 8),
          const Icon(Icons.push_pin_outlined, color: Color(0xFF6E6E6E), size: 16),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

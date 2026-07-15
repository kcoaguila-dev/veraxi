import 'package:flutter/material.dart';
import 'package:veraxi_app/core/theme.dart';

class ChatInput extends StatefulWidget {
  final bool isLoading;
  final String? error;
  final Function(String) onSend;
  final VoidCallback? onDismissError;

  const ChatInput({
    super.key,
    required this.isLoading,
    this.error,
    required this.onSend,
    this.onDismissError,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();

  void _handleSend() {
    final text = _controller.text;
    if (text.trim().isNotEmpty && !widget.isLoading) {
      widget.onSend(text);
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(top: BorderSide(color: AppTheme.surfaceHighlight)),
      ),
      child: SafeArea(
        child: widget.error != null ? _buildErrorState() : _buildInputState(),
      ),
    );
  }

  Widget _buildErrorState() {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: Colors.redAccent.withAlpha(25),
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.redAccent.withAlpha(100)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.error!,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.redAccent),
            onPressed: widget.onDismissError,
            tooltip: 'Dismiss error',
          ),
        ],
      ),
    );
  }

  Widget _buildInputState() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            minLines: 1,
            maxLines: 5,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(
              hintText: 'Message Veraxi...',
            ),
            onSubmitted: (_) => _handleSend(),
            enabled: !widget.isLoading,
          ),
        ),
        const SizedBox(width: 12),
        Container(
          decoration: const BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: widget.isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.arrow_upward, color: Colors.white),
            onPressed: widget.isLoading ? null : _handleSend,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';

class ChatEmptyState extends StatelessWidget {
  final ChatState state;
  final ChatViewModel viewModel;
  final String selectedModel;
  final String? activeProjectName;
  final String Function() resolveDisplayName;

  const ChatEmptyState({
    super.key,
    required this.state,
    required this.viewModel,
    required this.selectedModel,
    this.activeProjectName,
    required this.resolveDisplayName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Good afternoon, ${resolveDisplayName()}',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ).animate().fade(duration: 800.ms).slideY(begin: 0.1, end: 0),
          SizedBox(height: 32),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ChatInput(
              projectName: activeProjectName,
              isLoading: state.isLoading,
              onSend: (text, {attachments}) => viewModel.sendMessage(text,
                  model: selectedModel, attachments: attachments),
              errorText: state.error,
            ),
          )
              .animate()
              .fade(duration: 800.ms, delay: 100.ms)
              .slideY(begin: 0.1, end: 0),
        ],
      ),
    );
  }
}

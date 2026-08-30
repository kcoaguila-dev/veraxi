import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:veraxi_app/core/widgets/model_selector_popup.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_metrics.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';
import 'package:veraxi_app/features/chat/views/widgets/project_dashboard_view.dart';
import 'package:veraxi_app/features/chat/views/widgets/all_projects_dashboard_view.dart';
import 'package:veraxi_app/features/chat/views/widgets/create_project_dialog.dart';
import 'package:veraxi_app/features/chat/views/widgets/agentic_tool_log.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_button.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_sidebar.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:veraxi_app/core/widgets/profile_menu_button.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

final activeSourcesProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

class CitationElementBuilder extends MarkdownElementBuilder {
  final ChatMessage message;

  CitationElementBuilder({required this.message});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    if (element.tag == 'a') {
      final text = element.textContent;
      final href = element.attributes['href'];
      return CitationChip(
        text: text,
        url: href ?? '',
        message: message,
      );
    } else if (element.tag == 'cite') {
      return CitationChip(
        text: element.textContent,
        url: '', // the chip will resolve the URL from the message's tool events
        message: message,
      );
    }
    return null;
  }
}

class CitationSyntax extends md.InlineSyntax {
  CitationSyntax() : super(r'\[([^\]]+)\](?:\s*\(\s*(?:-\s*)?https?:\/\/[^\)]+\s*\))?\s*[.,;:]?');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final text = match[1]!;
    final element = md.Element.text('cite', text);
    parser.addNode(element);
    return true;
  }
}

class InteractiveCodeBlock extends StatefulWidget {
  final String language;
  final String code;

  const InteractiveCodeBlock(
      {super.key, required this.language, required this.code});

  @override
  State<InteractiveCodeBlock> createState() => _InteractiveCodeBlockState();
}

class _InteractiveCodeBlockState extends State<InteractiveCodeBlock> {
  bool _isRunning = false;
  bool _hasError = false;

  void _runCode() async {
    if (_isRunning || _hasError) return;
    setState(() {
      _isRunning = true;
    });

    // Simulate code execution delay
    await Future.delayed(const Duration(seconds: 1));

    if (mounted) {
      setState(() {
        _isRunning = false;
        _hasError = true;
      });

      // Show red error snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('There was an error running the code',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
          backgroundColor: const Color(0xFFDC2626), // Red background
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            bottom: MediaQuery.of(context).size.height - 150,
            left: MediaQuery.of(context).size.width / 2 - 150,
            right: MediaQuery.of(context).size.width / 2 - 150,
          ),
          duration: const Duration(seconds: 3),
        ),
      );

      // Revert the error state after the snackbar duration
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _hasError = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F), // Dark background for code
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF2A2A2A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(widget.language,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFamily: 'monospace')),
                Row(
                  children: [
                    InkWell(
                      onTap: _runCode,
                      child: Row(
                        children: [
                          if (_hasError)
                            const Icon(Icons.close,
                                color: Color(0xFFDC2626), size: 14)
                          else if (_isRunning)
                            const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70))
                          else
                            const Icon(Icons.play_arrow_outlined,
                                color: Colors.white70, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            _hasError ? 'Failed' : 'Run Code',
                            style: TextStyle(
                              color: _hasError
                                  ? const Color(0xFFDC2626)
                                  : Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.code));
                      },
                      child: const Row(
                        children: [
                          Icon(Icons.copy_outlined,
                              color: Colors.white70, size: 14),
                          SizedBox(width: 4),
                          Text('Copy code',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Code content
          SizedBox(
            width: double.infinity,
            child: HighlightView(
              widget.code,
              language:
                  widget.language == 'text' ? 'plaintext' : widget.language,
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(16),
              textStyle: GoogleFonts.firaCode(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  CodeElementBuilder(this.context);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // If it doesn't have a language class or newlines, it's probably inline code.
    final hasLanguage =
        element.attributes.keys.any((k) => k.startsWith('class'));
    final languageClass = element.attributes['class'];
    final isBlock = element.textContent.contains('\n') || hasLanguage;

    if (!isBlock) {
      // Let flutter_markdown handle inline code
      return null;
    }

    String language = 'plaintext';
    if (languageClass != null && languageClass.startsWith('language-')) {
      language = languageClass.substring(9).toLowerCase();
      // Normalize common language aliases for highlight.js
      if (language == 'python3' || language == 'py') language = 'python';
      if (language == 'js' || language == 'node') language = 'javascript';
      if (language == 'ts') language = 'typescript';
      if (language == 'sh' || language == 'zsh') language = 'bash';
      if (language == 'c++' || language == 'cc') language = 'cpp';
      if (language == 'c#') language = 'cs';
      if (language == 'html')
        language = 'xml'; // highglight.js treats html as xml
      if (language == 'text') language = 'plaintext';
    }

    final code = element.textContent;

    if (language == 'xml' && languageClass == 'language-html') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.blue.withValues(alpha: 0.1),
            child: const Row(
              children: [
                Icon(Icons.brush, size: 16, color: Colors.blue),
                SizedBox(width: 8),
                Text('HTML Artifact (Preview coming soon)',
                    style: TextStyle(
                        color: Colors.blue, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          InteractiveCodeBlock(language: 'html', code: code),
        ],
      );
    }

    if (languageClass == 'language-mermaid') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.purple.withValues(alpha: 0.1),
            child: const Row(
              children: [
                Icon(Icons.schema, size: 16, color: Colors.purple),
                SizedBox(width: 8),
                Text('Mermaid Diagram Artifact (Preview coming soon)',
                    style: TextStyle(
                        color: Colors.purple, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          InteractiveCodeBlock(language: 'mermaid', code: code),
        ],
      );
    }

    return InteractiveCodeBlock(language: language, code: code);
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const String _sidebarToggleSvg = '''
<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <path fill-rule="evenodd" clip-rule="evenodd" d="M8.85719 3H15.1428C16.2266 2.99999 17.1007 2.99998 17.8086 3.05782C18.5375 3.11737 19.1777 3.24318 19.77 3.54497C20.7108 4.02433 21.4757 4.78924 21.955 5.73005C22.2568 6.32234 22.3826 6.96253 22.4422 7.69138C22.5 8.39925 22.5 9.27339 22.5 10.3572V13.6428C22.5 14.7266 22.5 15.6008 22.4422 16.3086C22.3826 17.0375 22.2568 17.6777 21.955 18.27C21.4757 19.2108 20.7108 19.9757 19.77 20.455C19.1777 20.7568 18.5375 20.8826 17.8086 20.9422C17.1008 21 16.2266 21 15.1428 21H8.85717C7.77339 21 6.89925 21 6.19138 20.9422C5.46253 20.8826 4.82234 20.7568 4.23005 20.455C3.28924 19.9757 2.52433 19.2108 2.04497 18.27C1.74318 17.6777 1.61737 17.0375 1.55782 16.3086C1.49998 15.6007 1.49999 14.7266 1.5 13.6428V10.3572C1.49999 9.27341 1.49998 8.39926 1.55782 7.69138C1.61737 6.96253 1.74318 6.32234 2.04497 5.73005C2.52433 4.78924 3.28924 4.02433 4.23005 3.54497C4.82234 3.24318 5.46253 3.11737 6.19138 3.05782C6.89926 2.99998 7.77341 2.99999 8.85719 3ZM6.35424 5.05118C5.74907 5.10062 5.40138 5.19279 5.13803 5.32698C4.57354 5.6146 4.1146 6.07354 3.82698 6.63803C3.69279 6.90138 3.60062 7.24907 3.55118 7.85424C3.50078 8.47108 3.5 9.26339 3.5 10.4V13.6C3.5 14.7366 3.50078 15.5289 3.55118 16.1458C3.60062 16.7509 3.69279 17.0986 3.82698 17.362C4.1146 17.9265 4.57354 18.3854 5.13803 18.673C5.40138 18.8072 5.74907 18.8994 6.35424 18.9488C6.97108 18.9992 7.76339 19 8.9 19H9.5V5H8.9C7.76339 5 6.97108 5.00078 6.35424 5.05118ZM11.5 5V19H15.1C16.2366 19 17.0289 18.9992 17.6458 18.9488C18.2509 18.8994 18.5986 18.8072 18.862 18.673C19.4265 18.3854 19.8854 17.9265 20.173 17.362C20.3072 17.0986 20.3994 16.7509 20.4488 16.1458C20.4992 15.5289 20.5 14.7366 20.5 13.6V10.4C20.5 9.26339 20.4992 8.47108 20.4488 7.85424C20.3994 7.24907 20.3072 6.90138 20.173 6.63803C19.8854 6.07354 19.4265 5.6146 18.862 5.32698C18.5986 5.19279 18.2509 5.10062 17.6458 5.05118C17.0289 5.00078 16.2366 5 15.1 5H11.5ZM5 8.5C5 7.94772 5.44772 7.5 6 7.5H7C7.55229 7.5 8 7.94772 8 8.5C8 9.05229 7.55229 9.5 7 9.5H6C5.44772 9.5 5 9.05229 5 8.5ZM5 12C5 11.4477 5.44772 11 6 11H7C7.55229 11 8 11.4477 8 12C8 12.5523 7.55229 13 7 13H6C5.44772 13 5 12.5523 5 12Z" fill="currentColor"/>
</svg>
''';

  PopupMenuItem<String> _buildPopupMenuItem(String title, IconData icon,
      {bool isDestructive = false}) {
    return PopupMenuItem<String>(
      value: title,
      child: Row(
        children: [
          Icon(icon,
              color: isDestructive ? Colors.red : const Color(0xFFB4B4B4),
              size: 16),
          const SizedBox(width: 12),
          Text(title,
              style: TextStyle(
                  color: isDestructive ? Colors.red : const Color(0xFFE0E0E0),
                  fontSize: 13)),
        ],
      ),
    );
  }

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _modelSelectorKey = GlobalKey();
  bool _isModelSelectorOpen = false;
  String? _hoveredProvider;
  String? _hoveredGearProvider;
  String _selectedModel = 'Select a model';
  String? _selectedProvider;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  String _globalSearchQuery = '';
  final TextEditingController _globalSearchController = TextEditingController();
  String? _hoveredModel;
  final Set<String> _pinnedModels = {};
  bool _chatsExpanded = true;
  bool _projectsListExpanded = false;
  bool _isScrolledUp = false;
  final Set<String> _expandedProjects = {};

  void _onScroll() {
    if (_scrollController.hasClients) {
      final isUp = _scrollController.position.pixels <
          _scrollController.position.maxScrollExtent - 50;
      if (isUp != _isScrolledUp) {
        setState(() {
          _isScrolledUp = isUp;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSavedModel();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _loadSavedModel() async {
    final prefs = await SharedPreferences.getInstance();
    final savedModel = prefs.getString('selected_model');
    final savedProvider = prefs.getString('selected_provider');
    if (savedModel != null && mounted) {
      setState(() {
        _selectedModel = savedModel;
        _selectedProvider = savedProvider;
      });
    }
  }

  Future<void> _saveSelectedModel(String model, String? provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_model', model);
    if (provider != null) {
      await prefs.setString('selected_provider', provider);
    } else {
      await prefs.remove('selected_provider');
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _globalSearchController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 100, // Overscroll slightly
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _buildSidebarToggleIcon() {
    return SvgPicture.string(
      _sidebarToggleSvg,
      width: 18,
      height: 18,
      fit: BoxFit.contain,
      colorFilter: const ColorFilter.mode(Color(0xFFB4B4B4), BlendMode.srcIn),
    );
  }

  void _showRenameProjectDialog(BuildContext context, String projectId,
      String currentName, ChatViewModel viewModel) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Rename Project',
              style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Project Name',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.grey)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  viewModel.renameProject(projectId, controller.text);
                  Navigator.pop(context);
                }
              },
              child: const Text('Save', style: TextStyle(color: Colors.blue)),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteProjectDialog(BuildContext context, String projectId,
      String projectName, ChatViewModel viewModel) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Delete Project',
              style: TextStyle(color: Colors.white)),
          content: Text(
              'Are you sure you want to delete the project "$projectName"? This action cannot be undone.',
              style: const TextStyle(color: Colors.white)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                viewModel.deleteProject(projectId);
                Navigator.pop(context);
              },
              child: const Text('Delete',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSidebarContent(
      BuildContext context,
      dynamic state,
      dynamic viewModel,
      bool isSidebarOpen,
      AppThemeExtension ext,
      bool isMobile) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      width: isSidebarOpen ? 260 : 0,
      child: ClipRect(
        child: Container(
          width: 260,
          color: const Color(0xFF171717),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      'Veraxi',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Tooltip(
                      message: 'Close sidebar',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            ref.read(sidebarStateProvider.notifier).state =
                                false;
                          },
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: Center(child: _buildSidebarToggleIcon()),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              // Pinned Models (above Projects)
              if (_pinnedModels.isNotEmpty) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _pinnedModels.map((model) {
                    final isActive = model == _selectedModel;
                    return MouseRegion(
                      onEnter: (_) =>
                          setState(() => _hoveredModel = 'sidebar_$model'),
                      onExit: (_) => setState(() {
                        if (_hoveredModel == 'sidebar_$model')
                          _hoveredModel = null;
                      }),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedModel = model;
                            // Infer provider from model name
                            if (model.startsWith('gemini'))
                              _selectedProvider = 'Google';
                            else if (model.startsWith('gpt'))
                              _selectedProvider = 'OpenAI';
                            else if (model.startsWith('claude'))
                              _selectedProvider = 'Anthropic';
                          });
                          _saveSelectedModel(_selectedModel, _selectedProvider);
                        },
                        child: Container(
                          height: 30,
                          margin: const EdgeInsets.only(bottom: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(0xFF2F2F2F)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              _providerDotFor(model),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  model,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: isActive
                                          ? Colors.white
                                          : const Color(0xFF878787)),
                                ),
                              ),
                              if (_hoveredModel == 'sidebar_$model')
                                GestureDetector(
                                  onTap: () => setState(
                                      () => _pinnedModels.remove(model)),
                                  child: const Tooltip(
                                    message: 'Unpin',
                                    child: Icon(Icons.push_pin,
                                        color: Color(0xFF878787), size: 12),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  InkWell(
                    onTap: () => setState(
                        () => _projectsListExpanded = !_projectsListExpanded),
                    child: Row(
                      children: [
                        Text('Projects',
                            style: TextStyle(
                                color: const Color(0xFF878787),
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Icon(
                            _projectsListExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            color: const Color(0xFF878787),
                            size: 16),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Tooltip(
                        message: 'All Projects',
                        child: InkWell(
                          onTap: () => viewModel.openAllProjectsDashboard(),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.all(4.0),
                            child: Icon(LucideIcons.folder,
                                color: const Color(0xFFB4B4B4), size: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'New Project',
                        child: InkWell(
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (context) => const CreateProjectDialog(),
                            );
                          },
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.all(4.0),
                            child: Icon(LucideIcons.folderPlus,
                                color: const Color(0xFFB4B4B4), size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (state.projects.isNotEmpty && _projectsListExpanded)
                Column(
                  children: state.projects.map((project) {
                    final projectId = project['id'] as String;
                    final projectName = project['name'] as String;
                    final isActive = state.activeProjectId == projectId;
                    final isExpanded = _expandedProjects.contains(projectId);

                    final projectThreads = state.pastThreads
                        .where((t) =>
                            t['project_id'] == projectId &&
                            t['is_archived'] != true)
                        .toList();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        (() {
                          bool isHovered = false;
                          return StatefulBuilder(
                            builder: (context, setHoverState) {
                              return MouseRegion(
                                onEnter: (_) =>
                                    setHoverState(() => isHovered = true),
                                onExit: (_) =>
                                    setHoverState(() => isHovered = false),
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      if (isExpanded) {
                                        _expandedProjects.remove(projectId);
                                      } else {
                                        _expandedProjects.add(projectId);
                                      }
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: (isActive || isHovered)
                                          ? const Color(0xFF2A2A2A)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Icon(
                                            isExpanded
                                                ? Icons.keyboard_arrow_down
                                                : Icons.keyboard_arrow_right,
                                            color: const Color(0xFF878787),
                                            size: 16,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Icon(
                                          LucideIcons.folder,
                                          color: isActive
                                              ? Colors.white
                                              : const Color(0xFF878787),
                                          size: 16,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            projectName,
                                            style: TextStyle(
                                              color: isActive
                                                  ? Colors.white
                                                  : const Color(0xFF878787),
                                              fontSize: 13,
                                              fontWeight: isActive
                                                  ? FontWeight.w500
                                                  : FontWeight.normal,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Visibility(
                                          visible: isHovered || isActive,
                                          maintainSize: true,
                                          maintainAnimation: true,
                                          maintainState: true,
                                          child: Row(
                                            children: [
                                              InkWell(
                                                onTap: () => viewModel
                                                    .startNewChatInProject(
                                                        projectId),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.all(4.0),
                                                  child: Icon(Icons.edit_square,
                                                      color: const Color(
                                                          0xFFB4B4B4),
                                                      size: 14),
                                                ),
                                              ),
                                              const SizedBox(width: 2),
                                              Theme(
                                                data:
                                                    Theme.of(context).copyWith(
                                                  hoverColor:
                                                      Colors.transparent,
                                                  splashColor:
                                                      Colors.transparent,
                                                  highlightColor:
                                                      Colors.transparent,
                                                ),
                                                child: PopupMenuButton<String>(
                                                  padding: EdgeInsets.zero,
                                                  icon: const Icon(
                                                      Icons.more_horiz,
                                                      color: Color(0xFFB4B4B4),
                                                      size: 14),
                                                  color:
                                                      const Color(0xFF2A2A2A),
                                                  shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8)),
                                                  offset: const Offset(0, 30),
                                                  onSelected: (value) {
                                                    if (value == 'open') {
                                                      viewModel.selectProject(
                                                          projectId,
                                                          projectName);
                                                    } else if (value ==
                                                        'rename') {
                                                      _showRenameProjectDialog(
                                                          context,
                                                          projectId,
                                                          projectName,
                                                          viewModel);
                                                    } else if (value ==
                                                        'delete') {
                                                      _showDeleteProjectDialog(
                                                          context,
                                                          projectId,
                                                          projectName,
                                                          viewModel);
                                                    }
                                                  },
                                                  itemBuilder: (BuildContext
                                                          context) =>
                                                      <PopupMenuEntry<String>>[
                                                    const PopupMenuItem<String>(
                                                      value: 'open',
                                                      height: 36,
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                              LucideIcons
                                                                  .folder,
                                                              color: Color(
                                                                  0xFFB4B4B4),
                                                              size: 14),
                                                          SizedBox(width: 8),
                                                          Text('Open project',
                                                              style: TextStyle(
                                                                  color: Color(
                                                                      0xFFB4B4B4),
                                                                  fontSize:
                                                                      12)),
                                                        ],
                                                      ),
                                                    ),
                                                    const PopupMenuItem<String>(
                                                      value: 'rename',
                                                      height: 36,
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                              Icons
                                                                  .edit_outlined,
                                                              color: Color(
                                                                  0xFFB4B4B4),
                                                              size: 14),
                                                          SizedBox(width: 8),
                                                          Text('Rename',
                                                              style: TextStyle(
                                                                  color: Color(
                                                                      0xFFB4B4B4),
                                                                  fontSize:
                                                                      12)),
                                                        ],
                                                      ),
                                                    ),
                                                    const PopupMenuItem<String>(
                                                      value: 'delete',
                                                      height: 36,
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                              Icons
                                                                  .delete_outline,
                                                              color: Colors
                                                                  .redAccent,
                                                              size: 14),
                                                          SizedBox(width: 8),
                                                          Text('Delete',
                                                              style: TextStyle(
                                                                  color: Colors
                                                                      .redAccent,
                                                                  fontSize:
                                                                      12)),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
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
                            },
                          );
                        })(),
                        if (isExpanded && projectThreads.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 32.0, top: 4.0, bottom: 4.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: projectThreads.map((threadData) {
                                final threadId =
                                    threadData['thread_id'] as String? ?? '';
                                final title = threadData['title'] as String? ??
                                    (threadId.length > 8
                                        ? threadId.substring(0, 8) + '...'
                                        : threadId);
                                final isThreadActive =
                                    state.threadId == threadId;

                                bool isHovered = false;
                                return StatefulBuilder(
                                    builder: (context, setHoverState) {
                                  return MouseRegion(
                                    onEnter: (_) =>
                                        setHoverState(() => isHovered = true),
                                    onExit: (_) =>
                                        setHoverState(() => isHovered = false),
                                    child: InkWell(
                                      onTap: () =>
                                          viewModel.selectThread(threadId),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: isThreadActive
                                              ? const Color(0xFF2A2A2A)
                                              : Colors.transparent,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                title,
                                                style: TextStyle(
                                                  color: isThreadActive
                                                      ? Colors.white
                                                      : const Color(0xFFB4B4B4),
                                                  fontSize: 13,
                                                  fontWeight: isThreadActive
                                                      ? FontWeight.w500
                                                      : FontWeight.normal,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Visibility(
                                              visible:
                                                  isHovered || isThreadActive,
                                              maintainSize: true,
                                              maintainAnimation: true,
                                              maintainState: true,
                                              child: Theme(
                                                data:
                                                    Theme.of(context).copyWith(
                                                  hoverColor:
                                                      Colors.transparent,
                                                  splashColor:
                                                      Colors.transparent,
                                                  highlightColor:
                                                      Colors.transparent,
                                                ),
                                                child: SizedBox(
                                                  width: 24,
                                                  height: 24,
                                                  child:
                                                      PopupMenuButton<String>(
                                                    icon: Icon(Icons.more_horiz,
                                                        color: isThreadActive
                                                            ? Colors.white
                                                            : const Color(
                                                                0xFFB4B4B4),
                                                        size: 16),
                                                    color:
                                                        const Color(0xFF2A2A2A),
                                                    shape:
                                                        RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        8)),
                                                    padding: EdgeInsets.zero,
                                                    itemBuilder: (context) {
                                                      final isPinned =
                                                          threadData[
                                                                  'is_pinned'] ==
                                                              true;
                                                      final isArchived =
                                                          threadData[
                                                                  'is_archived'] ==
                                                              true;
                                                      return [
                                                        _buildPopupMenuItem(
                                                            'Share',
                                                            Icons.share),
                                                        _buildPopupMenuItem(
                                                            isPinned
                                                                ? 'Unpin'
                                                                : 'Pin',
                                                            isPinned
                                                                ? Icons.push_pin
                                                                : Icons
                                                                    .push_pin_outlined),
                                                        _buildPopupMenuItem(
                                                            'Rename',
                                                            Icons
                                                                .edit_outlined),
                                                        _buildPopupMenuItem(
                                                            'Duplicate',
                                                            Icons
                                                                .copy_outlined),
                                                        _buildPopupMenuItem(
                                                            'Change project',
                                                            Icons
                                                                .folder_outlined),
                                                        _buildPopupMenuItem(
                                                            isArchived
                                                                ? 'Unarchive'
                                                                : 'Archive',
                                                            isArchived
                                                                ? Icons
                                                                    .unarchive
                                                                : Icons
                                                                    .archive_outlined),
                                                        _buildPopupMenuItem(
                                                            'Delete',
                                                            Icons
                                                                .delete_outline,
                                                            isDestructive:
                                                                true),
                                                      ];
                                                    },
                                                    onSelected: (value) async {
                                                      final viewModel = ref.read(
                                                          chatViewModelProvider
                                                              .notifier);
                                                      if (value == 'Share') {
                                                        _showShareDialog(
                                                            context,
                                                            viewModel,
                                                            threadId);
                                                      } else if (value ==
                                                              'Pin' ||
                                                          value == 'Unpin') {
                                                        await viewModel
                                                            .togglePinThread(
                                                                threadId);
                                                      } else if (value ==
                                                          'Rename') {
                                                        _showRenameDialog(
                                                            context,
                                                            viewModel,
                                                            threadId,
                                                            title);
                                                      } else if (value ==
                                                          'Duplicate') {
                                                        await viewModel
                                                            .duplicateThread(
                                                                threadId);
                                                      } else if (value ==
                                                          'Change project') {
                                                        _showChangeProjectDialog(
                                                            context,
                                                            viewModel,
                                                            threadId);
                                                      } else if (value ==
                                                              'Archive' ||
                                                          value ==
                                                              'Unarchive') {
                                                        await viewModel
                                                            .toggleArchiveThread(
                                                                threadId);
                                                      } else if (value ==
                                                          'Delete') {
                                                        await viewModel
                                                            .deleteThread(
                                                                threadId);
                                                      }
                                                    },
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                });
                              }).toList(),
                            ),
                          ),
                      ],
                    );
                  }).toList(),
                ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  InkWell(
                    onTap: () =>
                        setState(() => _chatsExpanded = !_chatsExpanded),
                    child: Row(
                      children: [
                        Text('Chats',
                            style: TextStyle(
                                color: const Color(0xFF878787),
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Icon(
                            _chatsExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            color: const Color(0xFF878787),
                            size: 16),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      viewModel.startNewChat();
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(Icons.edit_square,
                          color: const Color(0xFFB4B4B4), size: 16),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_chatsExpanded)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      if (state.isLoadingThreads) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.only(top: 24.0),
                            child: CupertinoActivityIndicator(radius: 10),
                          ),
                        );
                      }

                      final timelineChats = state.pastThreads
                          .where((t) => t['is_archived'] != true)
                          .toList();
                      if (timelineChats.isEmpty) {
                        return const SizedBox.shrink();
                      }

                      final now = DateTime.now();
                      final today = DateTime(now.year, now.month, now.day);
                      final yesterday = today.subtract(const Duration(days: 1));
                      final lastWeek = today.subtract(const Duration(days: 7));

                      final todayChats = <Map<String, dynamic>>[];
                      final yesterdayChats = <Map<String, dynamic>>[];
                      final lastWeekChats = <Map<String, dynamic>>[];
                      final olderChats = <Map<String, dynamic>>[];

                      for (final chat in timelineChats) {
                        final tsRaw = chat['_timestamp'];
                        final tsSec = tsRaw is num ? tsRaw.toDouble() : 0.0;
                        final date = tsSec > 0
                            ? DateTime.fromMillisecondsSinceEpoch(
                                (tsSec * 1000).toInt())
                            : DateTime.now();
                        final justDate =
                            DateTime(date.year, date.month, date.day);

                        if (!justDate.isBefore(today)) {
                          todayChats.add(chat);
                        } else if (!justDate.isBefore(yesterday)) {
                          yesterdayChats.add(chat);
                        } else if (!justDate.isBefore(lastWeek)) {
                          lastWeekChats.add(chat);
                        } else {
                          olderChats.add(chat);
                        }
                      }

                      final flatItems = <dynamic>[];
                      if (todayChats.isNotEmpty) {
                        flatItems.add('Today');
                        flatItems.addAll(todayChats);
                      }
                      if (yesterdayChats.isNotEmpty) {
                        flatItems.add('Yesterday');
                        flatItems.addAll(yesterdayChats);
                      }
                      if (lastWeekChats.isNotEmpty) {
                        flatItems.add('Previous 7 days');
                        flatItems.addAll(lastWeekChats);
                      }
                      if (olderChats.isNotEmpty) {
                        flatItems.add('Older');
                        flatItems.addAll(olderChats);
                      }

                      return ListView.builder(
                        itemCount: flatItems.length,
                        itemBuilder: (context, index) {
                          final item = flatItems[index];
                          if (item is String) {
                            return Padding(
                              padding: const EdgeInsets.only(
                                  top: 16.0, bottom: 8.0, left: 8.0),
                              child: Text(
                                item,
                                style: const TextStyle(
                                  color: Color(0xFF676767),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            );
                          }

                          final threadData = item as Map<String, dynamic>;
                          final threadId =
                              threadData['thread_id'] as String? ?? '';
                          final title = threadData['title'] as String? ??
                              (threadId.length > 8
                                  ? threadId.substring(0, 8) + '...'
                                  : threadId);
                          final isSelected = state.threadId == threadId;
                          bool isHovered = false;

                          return StatefulBuilder(builder: (context, setState) {
                            return MouseRegion(
                              onEnter: (_) => setState(() => isHovered = true),
                              onExit: (_) => setState(() => isHovered = false),
                              child: InkWell(
                                onTap: () {
                                  viewModel.selectThread(threadId);
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? const Color(0xFF2A2A2A)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 8.0, horizontal: 8.0),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: TextStyle(
                                            color: isSelected
                                                ? Colors.white
                                                : const Color(0xFFB4B4B4),
                                            fontSize: 13,
                                            fontWeight: isSelected
                                                ? FontWeight.w500
                                                : FontWeight.normal,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Visibility(
                                        visible: isHovered || isSelected,
                                        maintainSize: true,
                                        maintainAnimation: true,
                                        maintainState: true,
                                        child: Theme(
                                          data: Theme.of(context).copyWith(
                                            hoverColor: Colors.transparent,
                                            splashColor: Colors.transparent,
                                            highlightColor: Colors.transparent,
                                          ),
                                          child: SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: PopupMenuButton<String>(
                                              icon: Icon(Icons.more_horiz,
                                                  color: isSelected
                                                      ? Colors.white
                                                      : const Color(0xFFB4B4B4),
                                                  size: 16),
                                              color: const Color(0xFF2A2A2A),
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8)),
                                              padding: EdgeInsets.zero,
                                              itemBuilder: (context) {
                                                final isPinned =
                                                    threadData['is_pinned'] ==
                                                        true;
                                                final isArchived =
                                                    threadData['is_archived'] ==
                                                        true;
                                                return [
                                                  _buildPopupMenuItem(
                                                      'Share', Icons.share),
                                                  _buildPopupMenuItem(
                                                      isPinned
                                                          ? 'Unpin'
                                                          : 'Pin',
                                                      isPinned
                                                          ? Icons.push_pin
                                                          : Icons
                                                              .push_pin_outlined),
                                                  _buildPopupMenuItem('Rename',
                                                      Icons.edit_outlined),
                                                  _buildPopupMenuItem(
                                                      'Duplicate',
                                                      Icons.copy_outlined),
                                                  _buildPopupMenuItem(
                                                      'Change project',
                                                      Icons.folder_outlined),
                                                  _buildPopupMenuItem(
                                                      isArchived
                                                          ? 'Unarchive'
                                                          : 'Archive',
                                                      isArchived
                                                          ? Icons.unarchive
                                                          : Icons
                                                              .archive_outlined),
                                                  _buildPopupMenuItem('Delete',
                                                      Icons.delete_outline,
                                                      isDestructive: true),
                                                ];
                                              },
                                              onSelected: (value) async {
                                                final viewModel = ref.read(
                                                    chatViewModelProvider
                                                        .notifier);
                                                if (value == 'Share') {
                                                  _showShareDialog(context,
                                                      viewModel, threadId);
                                                } else if (value == 'Pin' ||
                                                    value == 'Unpin') {
                                                  await viewModel
                                                      .togglePinThread(
                                                          threadId);
                                                } else if (value == 'Rename') {
                                                  _showRenameDialog(
                                                      context,
                                                      viewModel,
                                                      threadId,
                                                      title);
                                                } else if (value ==
                                                    'Duplicate') {
                                                  await viewModel
                                                      .duplicateThread(
                                                          threadId);
                                                } else if (value ==
                                                    'Change project') {
                                                  _showChangeProjectDialog(
                                                      context,
                                                      viewModel,
                                                      threadId);
                                                } else if (value == 'Archive' ||
                                                    value == 'Unarchive') {
                                                  await viewModel
                                                      .toggleArchiveThread(
                                                          threadId);
                                                } else if (value == 'Delete') {
                                                  await viewModel
                                                      .deleteThread(threadId);
                                                }
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          });
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget build(BuildContext context) {
    final state = ref.watch(chatViewModelProvider);
    final isSidebarOpen = ref.watch(sidebarStateProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;

    // Auto-scroll when messages change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isScrolledUp) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      key: _scaffoldKey, // Add a key to access the scaffold
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: Builder(builder: (context) {
        final isMobile = MediaQuery.of(context).size.width < 800;
        if (!isMobile) return const SizedBox.shrink();
        final state = ref.watch(chatViewModelProvider);
        final viewModel = ref.read(chatViewModelProvider.notifier);
        final theme = Theme.of(context);
        final ext = theme.extension<AppThemeExtension>()!;
        return Drawer(
          backgroundColor: const Color(0xFF171717),
          child:
              _buildSidebarContent(context, state, viewModel, true, ext, true),
        );
      }),
      endDrawer: Consumer(
        builder: (context, ref, child) {
          final sources = ref.watch(activeSourcesProvider);
          return SourcesSidebar(sources: sources);
        },
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          return Row(
            children: [
              // Inner Navigation Sidebar (Projects / Chats)
              isMobile
                  ? const SizedBox.shrink()
                  : _buildSidebarContent(
                      context, state, viewModel, isSidebarOpen, ext, false),
              // Main Chat Area
              Expanded(
                child: SafeArea(
                  child: Stack(
                    children: [
                      // Main Content
                      Column(
                        children: [
                          if (isMobile)
                            Container(
                              height: 56,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              decoration: const BoxDecoration(
                                border: Border(
                                    bottom:
                                        BorderSide(color: Color(0xFF2A2A2A))),
                              ),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.menu,
                                        color: Colors.white),
                                    onPressed: () =>
                                        Scaffold.of(context).openDrawer(),
                                  ),
                                  const SizedBox(width: 8),
                                  const Text('Veraxi',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          Expanded(
                            child: state.showAllProjectsDashboard
                                ? const AllProjectsDashboardView()
                                : state.showProjectDashboard
                                    ? const ProjectDashboardView()
                                    : state.isLoadingHistory
                                        ? const Center(
                                            child: SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.0,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                            Color>(
                                                        Color(0xFF878787)),
                                              ),
                                            ),
                                          )
                                        : state.messages.isEmpty
                                            ? _buildEmptyState(
                                                theme, ext, state, viewModel)
                                            : ListView.builder(
                                                controller: _scrollController,
                                                padding: const EdgeInsets.only(
                                                    left: 16,
                                                    right: 16,
                                                    top: 80,
                                                    bottom: 300),
                                                itemCount:
                                                    state.messages.length,
                                                itemBuilder: (context, index) {
                                                  final msg =
                                                      state.messages[index];
                                                  return _buildChatMessage(
                                                      msg, theme, ext,
                                                      showTelemetry:
                                                          state.showTelemetry);
                                                },
                                              ),
                          ),
                        ],
                      ),

                      // Full-screen tap catcher to dismiss popup
                      if (_isModelSelectorOpen)
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _isModelSelectorOpen = false;
                                _hoveredProvider = null;
                                _hoveredGearProvider = null;
                                _searchQuery = '';
                                _searchController.clear();
                                _globalSearchQuery = '';
                                _globalSearchController.clear();
                                _hoveredModel = null;
                              });
                            },
                            child: Container(color: Colors.transparent),
                          ),
                        ),

                      // Removed overlapping Positioned toggle icon

                      // Top Bar: Model Selector (like LibreChat)
                      Positioned(
                        top: 12,
                        left: 16,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            GestureDetector(
                              key: _modelSelectorKey,
                              onTap: () {
                                setState(() {
                                  _isModelSelectorOpen = !_isModelSelectorOpen;
                                  if (_isModelSelectorOpen) {
                                    _hoveredProvider = _selectedProvider;
                                  } else {
                                    _hoveredProvider = null;
                                    _hoveredGearProvider = null;
                                  }
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E1E),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: const Color(0xFF2A2A2A)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_selectedModel != 'Select a model') ...[
                                      _providerDotFor(_selectedModel, size: 16),
                                      const SizedBox(width: 8),
                                    ],
                                    Text(_selectedModel,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500)),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.keyboard_arrow_down,
                                        size: 16, color: Colors.white),
                                  ],
                                ),
                              ),
                            ),
                            // Telemetry toggle — flush next to the model pill
                            const SizedBox(width: 4),
                            Tooltip(
                              message: state.showTelemetry
                                  ? 'Response Telemetry (On)'
                                  : 'Show Response Telemetry',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () => viewModel.toggleTelemetry(),
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Icon(
                                    state.showTelemetry
                                        ? Icons.analytics
                                        : Icons.analytics_outlined,
                                    size: 18,
                                    color: state.showTelemetry
                                        ? ext.primaryGradientStart
                                        : const Color(0xFF878787),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Temporary Chat Toggle
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Tooltip(
                          message: state.isTemporary
                              ? 'Temporary Chat (Enabled)'
                              : 'Temporary Chat',
                          child: IconButton(
                            icon: Icon(
                              Icons.data_usage,
                              color: state.isTemporary
                                  ? ext.primaryGradientStart
                                  : const Color(0xFF878787),
                              size: 20,
                            ),
                            onPressed: () => viewModel.toggleTemporaryChat(),
                          ),
                        ),
                      ),

                      // Solid background at bottom behind input
                      if (state.messages.isNotEmpty)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          height: 160,
                          child: Container(
                            color: theme.scaffoldBackgroundColor,
                          ),
                        ),

                      // Floating scroll to bottom button
                      if (_isScrolledUp && state.messages.isNotEmpty)
                        Positioned(
                          bottom: 120,
                          right: 32,
                          child: GestureDetector(
                            onTap: () {
                              _scrollToBottom();
                            },
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A2A2A),
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: const Color(0xFF3F3F3F)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.2),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  )
                                ],
                              ),
                              child: const Icon(Icons.arrow_downward,
                                  color: Colors.white, size: 16),
                            ),
                          ),
                        ),

                      // Floating Input Area at Bottom (only if messages exist)
                      if (state.messages.isNotEmpty)
                        Positioned(
                          bottom: 40,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 800),
                              child: ChatInput(
                                projectName: state.activeProjectName,
                                isLoading: state.isLoading,
                                onSend: (text, {attachments}) =>
                                    viewModel.sendMessage(text,
                                        model:
                                            _selectedModel == 'Select a model'
                                                ? null
                                                : _selectedModel,
                                        attachments: attachments),
                                errorText: state.error,
                                onDismissError: () => viewModel.clearError(),
                              ),
                            ),
                          ),
                        ),

                      // Footer Legal Text
                      Positioned(
                        bottom: 12,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Text(
                            'Veraxi v0.1.0 - Sovereign Intelligence. Privacy policy | Terms of service',
                            style: TextStyle(
                                color: const Color(0xFF878787), fontSize: 12),
                          ),
                        ),
                      ),

                      // The actual popup menu - opens downward from the top bar button
                      if (_isModelSelectorOpen)
                        Positioned(
                          top: 56,
                          left: 16,
                          child: ModelSelectorPopup(
                            selectedModel: _selectedModel,
                            pinnedModels: _pinnedModels.toList(),
                            onModelSelected: (model) {
                              setState(() {
                                _selectedModel = model;
                                _isModelSelectorOpen = false;
                              });
                              _saveSelectedModel(_selectedModel, _selectedProvider);
                            },
                            onModelPinned: (model) {
                              setState(() => _pinnedModels.add(model));
                            },
                            onModelUnpinned: (model) {
                              setState(() => _pinnedModels.remove(model));
                            },
                            onClose: () {
                              setState(() => _isModelSelectorOpen = false);
                            },
                          ).animate().fade(duration: 200.ms),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppThemeExtension ext,
      ChatState state, ChatViewModel viewModel) {
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
          const SizedBox(height: 32),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ChatInput(
              projectName: state.activeProjectName,
              isLoading: state.isLoading,
              onSend: (text, {attachments}) => viewModel.sendMessage(text,
                  model: _selectedModel, attachments: attachments),
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

  Widget _buildChatMessage(
      ChatMessage msg, ThemeData theme, AppThemeExtension ext,
      {bool showTelemetry = false}) {
    final isUser = msg.role == 'user';
    final name = isUser
        ? resolveDisplayName()
        : (msg.modelName != null && msg.modelName!.isNotEmpty
            ? msg.modelName!
            : 'AI Assistant');
    final avatar = isUser
        ? Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(6)),
            child: const Icon(Icons.person, color: Colors.white, size: 18),
          )
        : Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.transparent),
            child: msg.modelName != null && msg.modelName!.isNotEmpty
                ? _providerDotFor(msg.modelName!, size: 16)
                : Icon(Icons.auto_awesome,
                    color: ext.primaryGradientStart, size: 20),
          );

    return Center(
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                        const SizedBox(height: 8),
                        if (isUser)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                msg.content,
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(height: 1.5),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Tooltip(
                                      message: 'Copy message',
                                      child: InkWell(
                                        onTap: () => Clipboard.setData(
                                            ClipboardData(text: msg.content)),
                                        child: Icon(Icons.copy_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        else if (msg.isError)
                          Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(
                                  0xFF3F1515), // Dark red background
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: const Color(0xFFB91C1C)), // Red border
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.refresh,
                                    color: Color(0xFFFCA5A5), size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    msg.content,
                                    style: const TextStyle(
                                        color: Color(0xFFFCA5A5),
                                        fontSize: 14), // Light red text
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 1. Thinking / Active Tool Indicator
                              if (msg.isStreaming && msg.content.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: ext.primaryGradientStart),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Thinking...',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                                color: ext.primaryGradientStart,
                                                fontWeight: FontWeight.w500,
                                                fontStyle: FontStyle.italic),
                                      ),
                                    ],
                                  )
                                      .animate(
                                          onPlay: (controller) =>
                                              controller.repeat())
                                      .shimmer(
                                          duration: 1.seconds,
                                          color: Colors.white30),
                                ),

                              // 3. Completed Tool Events
                              if (msg.toolEvents.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: msg.toolEvents
                                        .map((te) => AgenticToolLog(event: te))
                                        .toList(),
                                  ),
                                ),

                              if (msg.content.isNotEmpty)
                                MarkdownBody(
                                  data: msg.content,
                                  extensionSet: md.ExtensionSet(
                                    md.ExtensionSet.gitHubFlavored.blockSyntaxes,
                                    [
                                      CitationSyntax(),
                                      ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
                                    ],
                                  ),
                                  builders: {
                                    'code': CodeElementBuilder(context),
                                    'a': CitationElementBuilder(message: msg),
                                    'cite': CitationElementBuilder(message: msg),
                                  },
                                  styleSheet: MarkdownStyleSheet(
                                    p: theme.textTheme.bodyLarge
                                        ?.copyWith(height: 1.5),
                                    code: GoogleFonts.firaCode(
                                        backgroundColor: Colors.transparent,
                                        color: ext.primaryGradientStart),
                                    codeblockPadding: EdgeInsets.zero,
                                    codeblockDecoration:
                                        const BoxDecoration(), // Handled by builder
                                  ),
                                ),
                              if (!msg.isStreaming &&
                                  !msg.isError &&
                                  msg.content.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Tooltip(
                                        message: 'Read aloud',
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          onTap: () => ref
                                              .read(chatViewModelProvider
                                                  .notifier)
                                              .playAudio(msg.content,
                                                  messageId: msg.id ??
                                                      msg.hashCode.toString()),
                                          child: Icon(
                                              ref
                                                          .watch(
                                                              chatViewModelProvider)
                                                          .currentlyPlayingMessageId ==
                                                      (msg.id ??
                                                          msg.hashCode
                                                              .toString())
                                                  ? Icons.stop_circle_outlined
                                                  : Icons.volume_up_outlined,
                                              size: 16,
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.5)),
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      InkWell(
                                        onTap: () => Clipboard.setData(
                                            ClipboardData(text: msg.content)),
                                        child: Icon(Icons.copy_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                      const SizedBox(width: 16),
                                      InkWell(
                                        onTap: () {
                                          // In a real app, open an edit dialog here
                                        },
                                        child: Icon(Icons.edit_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                      const SizedBox(width: 16),
                                      InkWell(
                                        onTap: () {
                                          if (msg.id != null) {
                                            ref
                                                .read(chatViewModelProvider
                                                    .notifier)
                                                .submitFeedback(msg.id!,
                                                    msg.feedback == 1 ? 0 : 1);
                                          }
                                        },
                                        child: Icon(
                                            msg.feedback == 1
                                                ? Icons.thumb_up
                                                : Icons.thumb_up_outlined,
                                            size: 16,
                                            color: msg.feedback == 1
                                                ? theme.colorScheme.primary
                                                : theme.colorScheme.onSurface
                                                    .withValues(alpha: 0.5)),
                                      ),
                                      const SizedBox(width: 16),
                                      InkWell(
                                        onTap: () {
                                          if (msg.id != null) {
                                            ref
                                                .read(chatViewModelProvider
                                                    .notifier)
                                                .submitFeedback(
                                                    msg.id!,
                                                    msg.feedback == -1
                                                        ? 0
                                                        : -1);
                                          }
                                        },
                                        child: Icon(
                                            msg.feedback == -1
                                                ? Icons.thumb_down
                                                : Icons.thumb_down_outlined,
                                            size: 16,
                                            color: msg.feedback == -1
                                                ? theme.colorScheme.error
                                                : theme.colorScheme.onSurface
                                                    .withValues(alpha: 0.5)),
                                      ),
                                      const SizedBox(width: 16),
                                      InkWell(
                                        onTap: () => ref
                                            .read(
                                                chatViewModelProvider.notifier)
                                            .regenerateResponse(),
                                        child: Icon(Icons.refresh_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                      if (msg.toolEvents.any((e) =>
                                          (e.name.contains('web_search') ||
                                              e.name.contains('merge_rank')) &&
                                          e.result != null)) ...[
                                        const SizedBox(width: 16),
                                        SourcesButton(
                                          message: msg,
                                          onSourceClicked: () {
                                            ref
                                                    .read(activeSourcesProvider
                                                        .notifier)
                                                    .state =
                                                SourcesButton.extractSources(
                                                    msg);
                                            _scaffoldKey.currentState
                                                ?.openEndDrawer();
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              if (!isUser &&
                                  showTelemetry &&
                                  msg.metrics != null &&
                                  msg.metrics!.isNotEmpty)
                                ChatMessageMetrics(metrics: msg.metrics!),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            )));
  }

  // Removed hardcoded _allProviderModels

  void _showRenameDialog(BuildContext context, ChatViewModel viewModel,
      String threadId, String currentTitle) {
    final controller = TextEditingController(text: currentTitle);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Rename Chat',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Enter new title',
              hintStyle: TextStyle(color: Color(0xFF6E6E6E)),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF2A2A2A))),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF3A3A3A))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFFB4B4B4))),
            ),
            TextButton(
              onPressed: () async {
                final newTitle = controller.text.trim();
                if (newTitle.isNotEmpty) {
                  await viewModel.renameThread(threadId, newTitle);
                }
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showShareDialog(
      BuildContext context, ChatViewModel viewModel, String threadId) async {
    final shareId = await viewModel.shareThread(threadId);
    if (!context.mounted) return;

    if (shareId != null) {
      // Use standard Dart web library for host if possible, or fallback to current host pattern
      // For cross-platform support without dart:html, we can just use the current flutter web url base
      // But since we can't easily access the base URL without router config, we'll hardcode it to the
      // current app domain or localhost for now, but provide a copy button.
      // Better: Use Uri.base from dart:core
      final baseUrl = Uri.base.origin;
      final url = '$baseUrl/#/share/$shareId';
      
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text('Share Link',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Anyone with this link can view the shared conversation.',
                    style: TextStyle(color: Color(0xFFB4B4B4), fontSize: 13)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          url,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18, color: Color(0xFFB4B4B4)),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: url));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Link copied to clipboard', style: TextStyle(color: Colors.white)),
                              backgroundColor: Color(0xFF4CAF50),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close',
                    style: TextStyle(color: Color(0xFFB4B4B4))),
              ),
            ],
          );
        },
      );
    }
  }

  void _showChangeProjectDialog(
      BuildContext context, ChatViewModel viewModel, String threadId) async {
    final projects = await viewModel.getProjects();
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Assign Project',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: SizedBox(
            width: 300,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: projects.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    title: const Text('No Project',
                        style: TextStyle(color: Colors.white)),
                    onTap: () async {
                      await viewModel.assignThreadToProject(threadId, null);
                      if (context.mounted) Navigator.pop(context);
                    },
                  );
                }
                final project = projects[index - 1];
                return ListTile(
                  title: Text(project['name'] as String,
                      style: const TextStyle(color: Colors.white)),
                  onTap: () async {
                    await viewModel.assignThreadToProject(
                        threadId, project['id'] as String);
                    if (context.mounted) Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close',
                  style: TextStyle(color: Color(0xFFB4B4B4))),
            ),
          ],
        );
      },
    );
  }
}

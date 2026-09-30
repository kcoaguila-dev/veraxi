import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/knowledge_hub_view_model.dart';

import 'package:veraxi_app/features/chat/views/widgets/chat_sidebar.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'widgets/schema_visual_builder.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:veraxi_app/core/widgets/model_selector_popup.dart';

class KnowledgeHubScreen extends ConsumerStatefulWidget {
  const KnowledgeHubScreen({super.key});

  @override
  ConsumerState<KnowledgeHubScreen> createState() => _KnowledgeHubScreenState();
}

class _KnowledgeHubScreenState extends ConsumerState<KnowledgeHubScreen> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _customStopWordsController = TextEditingController();
  final TextEditingController _schemaSampleTextController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  bool _fastExtractionEnabled = false;
  String _selectedLanguage = 'English';
  String _selectedModel = 'gemini-1.5-pro-002';

  void _submitUrl() {
    if (_urlController.text.isNotEmpty) {
      ref.read(knowledgeHubViewModelProvider.notifier).autoGenerateSchema(_urlController.text);
      _urlController.clear();
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _customStopWordsController.dispose();
    _schemaSampleTextController.dispose();
    _urlController.dispose();
    super.dispose();
  }

Widget _buildSchemaCard(ThemeData theme) {
    final state = ref.watch(knowledgeHubViewModelProvider);
    final viewModel = ref.read(knowledgeHubViewModelProvider.notifier);

    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color:
            Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Theme.of(context)
                .extension<AppThemeExtension>()!
                .borderColorStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Information Extraction Rules',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 18)),
          SizedBox(height: 4),
          Text(
              'Define the entities and relationships that the AI should extract during ingestion.',
              style: TextStyle(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .iconColor,
                  fontSize: 14)),
          SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Auto-Generate from Sample',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w500)),
                    SizedBox(height: 8),
                    TextField(
                      controller: _schemaSampleTextController,
                      maxLines: 7,
                      style: TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText:
                            'Paste a sample of your text here (e.g., an abstract or executive summary). The AI will auto-generate an appropriate schema.',
                        hintStyle: TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .cardBackground,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: state.isIngesting
                          ? null
                          : () {
                              if (_schemaSampleTextController.text
                                  .trim()
                                  .isNotEmpty) {
                                viewModel.autoGenerateSchema(
                                    _schemaSampleTextController.text.trim());
                              }
                            },
                      icon: state.isIngesting
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.auto_awesome, size: 18),
                      label: Text('Auto-Generate'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade600,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 24),
              Expanded(
                flex: 1,
                child: SchemaVisualBuilder(
                  initialSchema: state.schema,
                  isSaving: state.isIngesting,
                  onSave: (schema) {
                    viewModel.saveSchema(schema);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

Widget _buildIngestionCard(ThemeData theme) {
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color:
            Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Theme.of(context)
                .extension<AppThemeExtension>()!
                .borderColorStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Global Ingestion',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 18)),
          SizedBox(height: 4),
          Text(
              'Upload documents or provide a URL. This data will be available to all AI agents.',
              style: TextStyle(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .iconColor,
                  fontSize: 14)),
          SizedBox(height: 24),
          Text('Upload Files',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 14)),
          SizedBox(height: 8),
          InkWell(
            onTap: () async {
              try {
                final result = await FilePicker.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: [
                    'pdf',
                    'txt',
                    'md',
                    'csv',
                    'html',
                    'doc',
                    'docx',
                    'ppt',
                    'pptx',
                    'xls',
                    'xlsx',
                    'png',
                    'jpg',
                    'jpeg',
                    'tiff',
                    'bmp',
                  ],
                );
                if (result.isNotEmpty && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Uploading file...')));
                  final viewModel =
                      ref.read(knowledgeHubViewModelProvider.notifier);
                  final fileBytes = await result.first.readAsBytes();
                  final fileName = result.first.name;
                  if (fileBytes.isNotEmpty) {
                    await viewModel.ingestUpload(
                      fileBytes,
                      fileName,
                      fastExtraction: _fastExtractionEnabled,
                      language: _selectedLanguage,
                      model: _selectedModel,
                      customStopWords: _customStopWordsController.text.trim(),
                    );
                    if (mounted)
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('File queued for ingestion!')));
                  }
                }
              } catch (e) {
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Upload failed: $e')));
              }
            },
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: 32),
              decoration: BoxDecoration(
                border: Border.all(
                    color: Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .borderColorStrong,
                    style: BorderStyle.solid),
                borderRadius: BorderRadius.circular(8),
                color: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .sidebarBackground
                    .withValues(alpha: 0.5),
              ),
              child: Column(
                children: [
                  Icon(Icons.cloud_upload_outlined,
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .textTertiary,
                      size: 32),
                  SizedBox(height: 12),
                  Text('Click to select a file',
                      style: TextStyle(
                          color: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .iconColor,
                          fontSize: 14)),
                  SizedBox(height: 4),
                  Text('PDF, TXT, MD, CSV, DOCX, Images (PNG/JPG) (Max 50MB)',
                      style: TextStyle(
                          color: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .textTertiary,
                          fontSize: 12)),
                ],
              ),
            ),
          ),
          SizedBox(height: 24),
          Text('Or ingest a URL',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 14)),
          SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  style: TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: InputDecoration(
                    hintText: 'https://example.com/article',
                    hintStyle: TextStyle(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .textTertiary),
                    filled: true,
                    fillColor: Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .sidebarBackground,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                  ),
                  onSubmitted: (val) => _submitUrl(),
                ),
              ),
              SizedBox(width: 12),
              ElevatedButton(
                onPressed: _submitUrl,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: Text('Ingest'),
              ),
            ],
          ),
          SizedBox(height: 32),
          // AI Model Selection
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .extension<AppThemeExtension>()!
                  .sidebarBackground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .borderColorStrong),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Extraction Model',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text('Select the AI model used for knowledge graph extraction.',
                    style: TextStyle(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .iconColor,
                        fontSize: 12)),
                SizedBox(height: 16),
                InkWell(
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => ModelSelectorPopup(
                        selectedModel: _selectedModel,
                        onModelSelected: (model) {
                          setState(() => _selectedModel = model);
                        },
                        onClose: () => Navigator.of(context).pop(),
                      ),
                    );
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .cardBackground,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .borderColorStrong),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_selectedModel,
                            style: TextStyle(color: Colors.white)),
                        Icon(Icons.arrow_drop_down, color: Colors.white54),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .extension<AppThemeExtension>()!
                  .sidebarBackground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .borderColorStrong),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Fast Extraction Mode',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      SizedBox(height: 4),
                      Text(
                          'Uses a hybrid 90% fast NLP and 10% AI approach. Highly recommended for large datasets.',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .extension<AppThemeExtension>()!
                                  .iconColor,
                              fontSize: 12)),
                    ],
                  ),
                ),
                Switch(
                  value: _fastExtractionEnabled,
                  onChanged: (val) {
                    setState(() {
                      _fastExtractionEnabled = val;
                    });
                  },
                  activeTrackColor: Theme.of(context).colorScheme.primary,
                  inactiveThumbColor: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .iconColor,
                  inactiveTrackColor: const Color(0xFF424242),
                ),
              ],
            ),
          ),
          if (_fastExtractionEnabled) ...[
            SizedBox(height: 16),
            Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: Text('Advanced Settings',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                iconColor: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .textTertiary,
                collapsedIconColor: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .textTertiary,
                tilePadding: EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: EdgeInsets.all(16),
                backgroundColor: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .cardBackground,
                collapsedBackgroundColor: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .cardBackground,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .borderColorStrong)),
                collapsedShape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .borderColorStrong)),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Language',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .extension<AppThemeExtension>()!
                                        .iconColor,
                                    fontSize: 12)),
                            SizedBox(height: 8),
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .sidebarBackground,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: Theme.of(context)
                                        .extension<AppThemeExtension>()!
                                        .borderColorStrong),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _selectedLanguage,
                                  isExpanded: true,
                                  dropdownColor: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .cardBackground,
                                  style: TextStyle(color: Colors.white),
                                  items: [
                                    DropdownMenuItem(
                                        value: 'en', child: Text('English')),
                                    DropdownMenuItem(
                                        value: 'es', child: Text('Spanish')),
                                    DropdownMenuItem(
                                        value: 'fr', child: Text('French')),
                                    DropdownMenuItem(
                                        value: 'de', child: Text('German')),
                                  ],
                                  onChanged: (val) {
                                    if ((val ?? '').isNotEmpty) {
                                      setState(() => _selectedLanguage = val!);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Custom Stop Words (comma separated)',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .extension<AppThemeExtension>()!
                                        .iconColor,
                                    fontSize: 12)),
                            SizedBox(height: 8),
                            TextField(
                              controller: _customStopWordsController,
                              style: TextStyle(color: Colors.white),
                              cursorColor: Colors.white,
                              decoration: InputDecoration(
                                hintText: 'e.g. client, company, confidential',
                                hintStyle: TextStyle(
                                    color: Theme.of(context)
                                        .extension<AppThemeExtension>()!
                                        .textTertiary),
                                filled: true,
                                fillColor: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .sidebarBackground,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 14),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .borderColorStrong)),
                                enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .borderColorStrong)),
                                focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .borderColorStrong)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

Widget _buildDatabaseMonitorCard(ThemeData theme, String title,
      String subtitle, String url, IconData icon) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:
            Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Theme.of(context)
                .extension<AppThemeExtension>()!
                .borderColorStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon,
                  color: Theme.of(context).colorScheme.primary, size: 24),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16)),
                  Text(subtitle,
                      style: TextStyle(
                          color: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .textTertiary,
                          fontSize: 12)),
                ],
              ),
            ],
          ),
          SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri);
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Could not launch dashboard')));
                }
              }
            },
            icon: Icon(Icons.open_in_new, size: 16, color: Colors.white),
            label:
                Text('Open Dashboard', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

Widget _buildDataPipeline(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Knowledge Hub',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
          'Manage your custom library and reference materials.',
          style: TextStyle(
              color:
                  Theme.of(context).extension<AppThemeExtension>()!.iconColor,
              fontSize: 14),
        ),
        SizedBox(height: 32),
        _buildSchemaCard(theme),
        SizedBox(height: 32),
        _buildIngestionCard(theme),
        SizedBox(height: 48),
        Text('Database Monitors',
            style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20)),
        SizedBox(height: 8),
        Text(
          'Launch web dashboards to inspect the raw databases.',
          style: TextStyle(
              color:
                  Theme.of(context).extension<AppThemeExtension>()!.iconColor,
              fontSize: 14),
        ),
        SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildDatabaseMonitorCard(
                theme,
                'Qdrant',
                'Vector Database',
                const String.fromEnvironment('QDRANT_DASHBOARD_URL',
                    defaultValue: 'http://localhost:6333/dashboard'),
                Icons.data_array,
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: _buildDatabaseMonitorCard(
                theme,
                'Neo4j',
                'Knowledge Graph',
                const String.fromEnvironment('NEO4J_DASHBOARD_URL',
                    defaultValue: 'http://localhost:7474'),
                Icons.hub,
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSidebarOpen = ref.watch(sidebarStateProvider);

    ref.listen<KnowledgeHubState>(knowledgeHubViewModelProvider, (previous, next) {
      if (previous?.successMessage != next.successMessage && next.successMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!), backgroundColor: Colors.green.shade800));
      }
      if (previous?.error != next.error && next.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: ${next.error}'), backgroundColor: Colors.red.shade800));
      }
    });

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: const ChatSidebar(isSidebarOpen: true, isMobile: true),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          return Row(
            children: [
              if (!isMobile) ChatSidebar(isSidebarOpen: isSidebarOpen, isMobile: false),
              Expanded(
                child: SafeArea(
                  child: Column(
                    children: [
                      if (isMobile)
                        Container(
                          height: 56,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A))),
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.menu, color: Colors.white),
                                onPressed: () => Scaffold.of(context).openDrawer(),
                              ),
                              const SizedBox(width: 8),
                              const Text('Veraxi', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(isMobile ? 16.0 : 48.0),
                          child: _buildDataPipeline(theme),
                        ),
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
}

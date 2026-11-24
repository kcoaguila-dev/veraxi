import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/knowledge_hub_view_model.dart';

import 'package:veraxi_app/features/chat/views/widgets/chat_sidebar.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'widgets/corpus_briefing_panel.dart';
import 'widgets/database_monitor_card.dart';
import 'widgets/repo_xray_panel.dart';
import 'widgets/schema_visual_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:veraxi_app/core/widgets/model_selector_popup.dart';
import 'package:veraxi_app/core/widgets/veraxi_switch.dart';

class KnowledgeHubScreen extends ConsumerStatefulWidget {
  const KnowledgeHubScreen({super.key});

  @override
  ConsumerState<KnowledgeHubScreen> createState() => _KnowledgeHubScreenState();
}

class _KnowledgeHubScreenState extends ConsumerState<KnowledgeHubScreen> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _customStopWordsController =
      TextEditingController();
  final TextEditingController _schemaSampleTextController =
      TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _sourceSearchController = TextEditingController();

  /// Repo path shared with the embedded Repo X-Ray tab (Phase 6).
  final TextEditingController _hubRepoPathController = TextEditingController();
  bool _fastExtractionEnabled = false;
  final String _selectedLanguage = 'English';
  String _selectedModel = 'gemini-1.5-pro-002';
  int _activeTab = 0;
  String _sourceCategoryFilter = 'ALL';
  String? _activeQueueItem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final q = ref.read(knowledgeHubViewModelProvider).queue;
      if (q.isNotEmpty) {
        ref.read(ingestionQueueProvider.notifier).state = q
            .map((j) => IngestionQueueItem(
                  jobId: j.jobId,
                  source: j.source,
                  stage: j.stage,
                  progress: j.progress,
                ))
            .toList();
      }
    });
  }

  void _submitUrl() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _activeQueueItem = url;
    });
    ref.read(knowledgeHubViewModelProvider.notifier).ingestUrl(
          url,
          fastExtraction: _fastExtractionEnabled,
          language: _selectedLanguage,
          model: _selectedModel,
          customStopWords: _customStopWordsController.text.trim(),
        );
    _urlController.clear();
  }

  @override
  void dispose() {
    _textController.dispose();
    _customStopWordsController.dispose();
    _schemaSampleTextController.dispose();
    _urlController.dispose();
    _sourceSearchController.dispose();
    _hubRepoPathController.dispose();
    super.dispose();
  }

  Widget _buildSchemaCard(ThemeData theme) {
    final state = ref.watch(knowledgeHubViewModelProvider);
    final viewModel = ref.read(knowledgeHubViewModelProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Information Extraction Rules',
            style: TextStyle(
              color: Color(0xFFF4F4F5),
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Define the entities and relationships that the AI should extract during ingestion.',
            style: TextStyle(
              color: Color(0xFFA1A1AA),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 860;
              final autoGenerateSection = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Auto-Generate from Sample',
                    style: TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _schemaSampleTextController,
                    maxLines: 7,
                    style:
                        const TextStyle(color: Color(0xFFF4F4F5), fontSize: 13),
                    decoration: InputDecoration(
                      hintText:
                          'Paste a sample of your text here (e.g., an abstract or executive summary). The AI will auto-generate an appropriate schema.',
                      hintStyle: const TextStyle(
                        color: Color(0xFF71717A),
                        fontSize: 12.5,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF141416),
                      contentPadding: const EdgeInsets.all(14),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF2D2D32)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF3F3F46)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
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
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.auto_awesome,
                            size: 15,
                            color: Color(0xFFA78BFA),
                          ),
                    label: const Text('Auto-Generate'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF27272B),
                      foregroundColor: const Color(0xFFE4E4E7),
                      disabledBackgroundColor: const Color(0xFF1F1F23),
                      disabledForegroundColor: const Color(0xFF71717A),
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                        side: const BorderSide(
                          color: Color(0xFF3A3A40),
                          width: 0.8,
                        ),
                      ),
                    ),
                  ),
                ],
              );
              final schemaVisualSection = SchemaVisualBuilder(
                initialSchema: state.schema,
                isSaving: state.isIngesting,
                onSave: (schema) {
                  viewModel.saveSchema(schema);
                },
              );

              if (isMobile) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    autoGenerateSection,
                    SizedBox(height: 32),
                    schemaVisualSection,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: autoGenerateSection),
                  const SizedBox(width: 24),
                  Expanded(flex: 3, child: schemaVisualSection),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCorpusHealthPill(KnowledgeHubState state) {
    final stats = state.stats;
    final vectorCount = stats?.vectorCount ?? 0;
    final nodeCount = stats?.nodeCount ?? 0;
    final sourceCount = (stats != null && stats.sourceCount > 0)
        ? stats.sourceCount
        : state.sources.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF18181B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Color(0xFFD4D4D8), fontSize: 11.5),
              children: [
                TextSpan(
                  text: '$sourceCount',
                  style: const TextStyle(
                      color: Color(0xFF34D399), fontWeight: FontWeight.w600),
                ),
                const TextSpan(text: ' sources'),
              ],
            ),
          ),
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Color(0xFFD4D4D8), fontSize: 11.5),
              children: [
                TextSpan(
                  text: '$vectorCount',
                  style: const TextStyle(
                      color: Color(0xFF93C5FD), fontWeight: FontWeight.w600),
                ),
                const TextSpan(text: ' Qdrant pts'),
              ],
            ),
          ),
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Color(0xFFD4D4D8), fontSize: 11.5),
              children: [
                TextSpan(
                  text: '$nodeCount',
                  style: const TextStyle(
                      color: Color(0xFFC4B5FD), fontWeight: FontWeight.w600),
                ),
                const TextSpan(text: ' Neo4j nodes'),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: state.isIngesting
                      ? const Color(0xFFFBBF24)
                      : const Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                state.isIngesting ? 'Syncing' : 'Synced',
                style: TextStyle(
                  color: state.isIngesting
                      ? const Color(0xFFFBBF24)
                      : const Color(0xFF34D399),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAdminHeader(KnowledgeHubState state, bool isMobile) {
    Widget tabButton(int index, String label, {bool showDot = false}) {
      final selected = _activeTab == index;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _activeTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF27272B) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: selected
                ? Border.all(color: const Color(0xFF3A3A40), width: 0.8)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : const Color(0xFFA1A1AA),
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (showDot) ...[
                const SizedBox(width: 8),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 36,
        isMobile ? 10 : 18,
        isMobile ? 16 : 36,
        14,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF212121),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2B2B2E), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!isMobile)
                const Text(
                  'Knowledge Hub',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              _buildCorpusHealthPill(state),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              tabButton(0, 'Sources & Ingestion'),
              tabButton(1, 'Repo X-Ray'),
              tabButton(2, 'Corpus & Lineage'),
              tabButton(3, 'Schema & Extraction'),
              tabButton(4, 'Infra & Monitors', showDot: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSourcesAndIngestionTab(
      ThemeData theme, KnowledgeHubState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCompactIngestionBar(theme, state),
        if (state.isIngesting || state.queue.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildLiveIngestionQueueCard(state),
        ],
        const SizedBox(height: 20),
        _buildIndexedSourcesTable(state),
      ],
    );
  }

  Widget _buildCompactIngestionBar(ThemeData theme, KnowledgeHubState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 820;
          final dropzone = InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _pickAndUploadFile,
            child: Container(
              height: 116,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF151518),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF3A3A40)),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.upload_rounded,
                      color: Color(0xFF9CA3AF), size: 24),
                  SizedBox(height: 8),
                  Text(
                    'Drop files to ingest (PDF, MD, TXT, CSV, DOCX, Images)',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Dual-writes to Qdrant (dense + SPLADE) & Neo4j with linked IDs',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF71717A), fontSize: 11),
                  ),
                ],
              ),
            ),
          );

          final urlAndModelControls = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ingest URL or Git Repo',
                style: TextStyle(
                  color: Color(0xFFA1A1AA),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _urlController,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12.5),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          hintText: 'https://example.com/docs or /path/to/repo',
                          hintStyle: const TextStyle(
                              color: Color(0xFF71717A), fontSize: 12.5),
                          filled: true,
                          fillColor: const Color(0xFF151518),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                const BorderSide(color: Color(0xFF2E2E34)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                const BorderSide(color: Color(0xFF2E2E34)),
                          ),
                        ),
                        onSubmitted: (_) => _submitUrl(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 36,
                    child: ElevatedButton(
                      onPressed: state.isIngesting ? null : _submitUrl,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text(
                        'Ingest',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 20,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Extraction Model',
                        style: TextStyle(
                          color: Color(0xFFA1A1AA),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          showDialog(
                            context: context,
                            builder: (context) => ModelSelectorPopup(
                              selectedModel: _selectedModel,
                              onModelSelected: (model) {
                                setState(() => _selectedModel = model);
                                Navigator.of(context).pop();
                              },
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF232327),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF323238)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _selectedModel,
                                style: const TextStyle(
                                    color: Color(0xFFE4E4E7), fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.keyboard_arrow_down,
                                  size: 15, color: Color(0xFF9CA3AF)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Fast Extraction (90% NLP)',
                        style: TextStyle(
                          color: Color(0xFFA1A1AA),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 8),
                      VeraxiSwitch(
                        value: _fastExtractionEnabled,
                        onChanged: (v) =>
                            setState(() => _fastExtractionEnabled = v),
                        semanticLabel: 'Fast Extraction (90% NLP)',
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                dropzone,
                const SizedBox(height: 16),
                urlAndModelControls,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: dropzone),
              const SizedBox(width: 20),
              Expanded(child: urlAndModelControls),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickAndUploadFile() async {
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
        final fileName = result.first.name;
        setState(() => _activeQueueItem = fileName);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Uploading file...')));
        final viewModel = ref.read(knowledgeHubViewModelProvider.notifier);
        final fileBytes = await result.first.readAsBytes();
        if (fileBytes.isNotEmpty) {
          await viewModel.ingestUpload(
            fileBytes,
            fileName,
            fastExtraction: _fastExtractionEnabled,
            language: _selectedLanguage,
            model: _selectedModel,
            customStopWords: _customStopWordsController.text.trim(),
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('File queued for ingestion!')));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Widget _buildLiveIngestionQueueCard(KnowledgeHubState state) {
    final activeTitle = state.queue.isNotEmpty
        ? state.queue.first.source
        : (_activeQueueItem ?? 'Ingesting document...');
    final activeStage = state.queue.isNotEmpty
        ? state.queue.first.stage
        : 'Chunking + Dual-Write';
    final progress = state.queue.isNotEmpty && state.queue.first.progress > 0
        ? state.queue.first.progress
        : null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F23),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2E2E34)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'INGESTION QUEUE',
                style: TextStyle(
                  color: Color(0xFF8E8E93),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  activeTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFF4F4F5),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                activeStage,
                style: const TextStyle(color: Color(0xFF34D399), fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: const Color(0xFF2A2A2F),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndexedSourcesTable(KnowledgeHubState hubState) {
    final sources = hubState.sources;
    final query = _sourceSearchController.text.trim().toLowerCase();
    final filtered = sources.where((s) {
      if (_sourceCategoryFilter == 'REPOS' && s.category != 'repo') {
        return false;
      }
      if (_sourceCategoryFilter == 'DOCS' && s.category != 'doc') {
        return false;
      }
      if (_sourceCategoryFilter == 'STALE' && !s.isStale) {
        return false;
      }
      if (query.isNotEmpty) {
        final hay = '${s.name} ${s.type} ${s.isStale ? 'stale' : 'indexed'}'
            .toLowerCase();
        if (!hay.contains(query)) return false;
      }
      return true;
    }).toList();

    final repoCount = sources.where((s) => s.category == 'repo').length;
    final docCount = sources.where((s) => s.category == 'doc').length;
    final staleCount = sources.where((s) => s.isStale).length;

    Widget chip(String key, String label, {bool isWarning = false}) {
      final selected = _sourceCategoryFilter == key;
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _sourceCategoryFilter = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isWarning
                ? const Color(0xFF272017)
                : (selected
                    ? const Color(0xFF2A2A2F)
                    : const Color(0xFF18181B)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isWarning
                  ? const Color(0xFF92400E)
                  : (selected
                      ? const Color(0xFF52525B)
                      : const Color(0xFF2F2F35)),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isWarning
                  ? const Color(0xFFFBBF24)
                  : (selected ? Colors.white : const Color(0xFFA1A1AA)),
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Indexed Sources',
                  style: TextStyle(
                    color: Color(0xFFF4F4F5),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(
                  width: 260,
                  height: 30,
                  child: TextField(
                    controller: _sourceSearchController,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      hintText: 'Filter sources by name, type, or status...',
                      hintStyle: const TextStyle(
                          color: Color(0xFF71717A), fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF151518),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: const BorderSide(color: Color(0xFF2E2E34)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: const BorderSide(color: Color(0xFF2E2E34)),
                      ),
                    ),
                  ),
                ),
                chip('ALL', 'All (${sources.length})'),
                chip('REPOS', 'Repos ($repoCount)'),
                chip('DOCS', 'Docs ($docCount)'),
                chip('STALE', 'Stale ($staleCount)', isWarning: true),
              ],
            ),
          ),
          const Divider(color: Color(0xFF2B2B30), height: 1),
          if (!hubState.sourcesLoaded)
            _buildSourcesLoadingSkeleton()
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                sources.isEmpty
                    ? 'No indexed sources yet. Upload a document or ingest a URL above.'
                    : 'No sources match the current filter.',
                style:
                    const TextStyle(color: Color(0xFF71717A), fontSize: 12.5),
              ),
            )
          else
            for (final row in filtered)
              _buildSourceRow(
                row,
                isBusy: hubState.busySourceId == row.id,
              ),
        ],
      ),
    );
  }

  Widget _buildSourcesLoadingSkeleton() {
    return Column(
      children: [
        for (int i = 0; i < 3; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: Border(
                bottom: i < 2
                    ? const BorderSide(color: Color(0xFF242428), width: 1)
                    : BorderSide.none,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 160,
                  height: 12,
                  decoration: BoxDecoration(
                    color: const Color(0xFF27272B),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const Spacer(),
                Container(
                  width: 72,
                  height: 12,
                  decoration: BoxDecoration(
                    color: const Color(0xFF232327),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _confirmDeleteSource(
    BuildContext context,
    IndexedSourceItem row,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2E2E34)),
        ),
        title: const Text(
          'Delete Indexed Source?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Permanently purge "${row.name}" from both Neo4j and Qdrant? This cannot be undone.',
          style: const TextStyle(
            color: Color(0xFFA1A1AA),
            fontSize: 13,
            height: 1.45,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFFA1A1AA)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7F1D1D),
              foregroundColor: const Color(0xFFFCA5A5),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Source'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(knowledgeHubViewModelProvider.notifier).deleteSource(row);
    }
  }

  Widget _buildSourceRow(IndexedSourceItem row, {required bool isBusy}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFF242428), width: 1),
        ),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          SizedBox(
            width: 240,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  style: const TextStyle(
                    color: Color(0xFFF4F4F5),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  row.subtitle,
                  style: const TextStyle(
                    color: Color(0xFF71717A),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF27272A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              row.type,
              style: const TextStyle(color: Color(0xFFD4D4D8), fontSize: 11),
            ),
          ),
          Text(
            row.counts,
            style: const TextStyle(color: Color(0xFFD4D4D8), fontSize: 12.5),
          ),
          Text(
            row.lastSynced,
            style: TextStyle(
              color: row.isStale
                  ? const Color(0xFFFBBF24)
                  : const Color(0xFFA1A1AA),
              fontSize: 12,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: row.isStale
                  ? const Color(0xFF272017)
                  : const Color(0xFF064E3B),
              borderRadius: BorderRadius.circular(6),
              border: row.isStale
                  ? Border.all(color: const Color(0xFF92400E), width: 0.8)
                  : null,
            ),
            child: Text(
              row.isStale ? 'Stale' : 'Indexed',
              style: TextStyle(
                color: row.isStale
                    ? const Color(0xFFFBBF24)
                    : const Color(0xFF34D399),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: isBusy
                    ? null
                    : () => ref
                        .read(knowledgeHubViewModelProvider.notifier)
                        .reindexSource(row),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF27272A),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: const Color(0xFF3F3F46), width: 0.8),
                  ),
                  child: Text(
                    isBusy ? 'Working…' : 'Re-index',
                    style: const TextStyle(
                        color: Color(0xFFD4D4D8), fontSize: 11.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: isBusy ? null : () => _confirmDeleteSource(context, row),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF27272A),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: const Color(0xFF3F3F46), width: 0.8),
                  ),
                  child: const Text(
                    'Del',
                    style: TextStyle(color: Color(0xFFFCA5A5), fontSize: 11.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfraMonitorsTab(ThemeData theme) {
    final stats = ref.watch(knowledgeHubViewModelProvider).stats;
    final qdrantTelemetry = stats != null
        ? '${stats.vectorCount} vectors · ${stats.sourceCount} indexed sources'
        : null;
    final neo4jTelemetry =
        stats != null ? '${stats.nodeCount} graph nodes' : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Database Monitors',
          style: TextStyle(
            color: Color(0xFFF4F4F5),
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Launch web dashboards to inspect the raw Qdrant and Neo4j databases.',
          style: TextStyle(
            color: Color(0xFFA1A1AA),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final qdrantCard = DatabaseMonitorCard(
              title: 'Qdrant',
              subtitle: 'Vector Database',
              url: const String.fromEnvironment('QDRANT_DASHBOARD_URL',
                  defaultValue: 'http://localhost:6333/dashboard'),
              icon: Icons.data_array,
              telemetry: qdrantTelemetry,
            );
            final neo4jCard = DatabaseMonitorCard(
              title: 'Neo4j',
              subtitle: 'Knowledge Graph',
              url: const String.fromEnvironment('NEO4J_DASHBOARD_URL',
                  defaultValue: 'http://localhost:7474'),
              icon: Icons.hub,
              telemetry: neo4jTelemetry,
            );
            if (constraints.maxWidth < 600) {
              return Column(
                children: [
                  qdrantCard,
                  const SizedBox(height: 16),
                  neo4jCard,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: qdrantCard),
                const SizedBox(width: 16),
                Expanded(child: neo4jCard),
              ],
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSidebarOpen = ref.watch(sidebarStateProvider);
    final hubState = ref.watch(knowledgeHubViewModelProvider);

    ref.listen<KnowledgeHubState>(knowledgeHubViewModelProvider,
        (previous, next) {
      if (previous?.queue != next.queue ||
          previous?.isIngesting != next.isIngesting) {
        final mapped = next.queue
            .map((j) => IngestionQueueItem(
                  jobId: j.jobId,
                  source: j.source,
                  stage: j.stage,
                  progress: j.progress,
                ))
            .toList();
        if (mapped.isEmpty && next.isIngesting) {
          mapped.add(IngestionQueueItem(
            jobId: 'active',
            source: _activeQueueItem ?? 'Ingesting document...',
            stage: 'Chunking + Dual-Write',
            progress: 0.5,
          ));
        }
        ref.read(ingestionQueueProvider.notifier).state = mapped;
      }
      if (previous?.successMessage != next.successMessage &&
          next.successMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(next.successMessage!),
            backgroundColor: Colors.green.shade800));
      }
      if (previous?.error != next.error && next.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error: ${next.error}'),
            backgroundColor: Colors.red.shade800));
      }
    });

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: Builder(builder: (context) {
        return SizedBox(
          width: MediaQuery.sizeOf(context).width,
          child: Drawer(
            backgroundColor: const Color(0xFF171717),
            shape:
                const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: const ChatSidebar(
              isSidebarOpen: true,
              isMobile: true,
              isKnowledgeHubRoute: true,
            ),
          ),
        );
      }),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          return Row(
            children: [
              if (!isMobile)
                ChatSidebar(
                  isSidebarOpen: isSidebarOpen,
                  isMobile: false,
                  isKnowledgeHubRoute: true,
                ),
              Expanded(
                child: SafeArea(
                  child: Column(
                    children: [
                      if (isMobile)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.menu,
                                    color: Color(0xFFB4B4B4)),
                                onPressed: () =>
                                    Scaffold.of(context).openDrawer(),
                              ),
                              const SizedBox(width: 8),
                              const Text('Knowledge Hub',
                                  style: TextStyle(
                                      color: Color(0xFFE0E0E0),
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      _buildAdminHeader(hubState, isMobile),
                      Expanded(
                        child: IndexedStack(
                          index: _activeTab,
                          children: [
                            SingleChildScrollView(
                              padding: EdgeInsets.all(isMobile ? 16.0 : 36.0),
                              child:
                                  _buildSourcesAndIngestionTab(theme, hubState),
                            ),
                            SingleChildScrollView(
                              padding: EdgeInsets.all(isMobile ? 16.0 : 36.0),
                              child: RepoXrayPanel(
                                repoPathController: _hubRepoPathController,
                              ),
                            ),
                            SingleChildScrollView(
                              padding: EdgeInsets.all(isMobile ? 16.0 : 36.0),
                              child: const CorpusBriefingPanel(),
                            ),
                            SingleChildScrollView(
                              padding: EdgeInsets.all(isMobile ? 16.0 : 36.0),
                              child: _buildSchemaCard(theme),
                            ),
                            SingleChildScrollView(
                              padding: EdgeInsets.all(isMobile ? 16.0 : 36.0),
                              child: _buildInfraMonitorsTab(theme),
                            ),
                          ],
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

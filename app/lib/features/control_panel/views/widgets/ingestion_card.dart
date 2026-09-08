import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:veraxi_app/core/widgets/model_selector_popup.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class IngestionCard extends ConsumerStatefulWidget {
  const IngestionCard({super.key});

  @override
  ConsumerState<IngestionCard> createState() => _IngestionCardState();
}

class _IngestionCardState extends ConsumerState<IngestionCard> {
  bool _fastExtractionEnabled = false;
  String _selectedLanguage = 'en';
  String _selectedModel = 'gemini-2.5-flash-lite';
  final TextEditingController _customStopWordsController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    _customStopWordsController.dispose();
    super.dispose();
  }

  void _submitUrl() {
    final url = _urlController.text.trim();
    if (url.isNotEmpty) {
      final viewModel = ref.read(controlPanelViewModelProvider.notifier);
      viewModel.ingestUrl(
        url,
        fastExtraction: _fastExtractionEnabled,
        language: _selectedLanguage,
        model: _selectedModel,
        customStopWords: _customStopWordsController.text.trim(),
      );
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('URL queued for ingestion!')));
      _urlController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
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
              style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14)),
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
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: [
                    'pdf', 'txt', 'md', 'csv', 'html', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'png', 'jpg', 'jpeg', 'tiff', 'bmp',
                  ],
                  withData: true,
                );
                if (result != null && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Uploading file...')));
                  final viewModel =
                      ref.read(controlPanelViewModelProvider.notifier);
                  final fileBytes = result.files.first.bytes;
                  final fileName = result.files.first.name;
                  if (fileBytes != null) {
                    await viewModel.ingestUpload(
                      fileBytes,
                      fileName,
                      fastExtraction: _fastExtractionEnabled,
                      language: _selectedLanguage,
                      model: _selectedModel,
                      customStopWords: _customStopWordsController.text.trim(),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('File queued for ingestion!')));
                    }
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Upload failed: $e')));
                }
              }
            },
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: 32),
              decoration: BoxDecoration(
                border: Border.all(
                    color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong, style: BorderStyle.solid),
                borderRadius: BorderRadius.circular(8),
                color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground.withValues(alpha: 0.5),
              ),
              child: Column(
                children: [
                  Icon(Icons.cloud_upload_outlined,
                      color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 32),
                  SizedBox(height: 12),
                  Text('Click to select a file',
                      style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14)),
                  SizedBox(height: 4),
                  Text('PDF, TXT, MD, CSV, DOCX, Images (PNG/JPG) (Max 50MB)',
                      style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12)),
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
                    hintStyle: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                    filled: true,
                    fillColor: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
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
                  padding:
                      EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
              color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
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
                Text(
                    'Select the AI model used for knowledge graph extraction.',
                    style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 12)),
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
                    padding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_selectedModel,
                            style: TextStyle(color: Colors.white)),
                        Icon(Icons.arrow_drop_down,
                            color: Colors.white54),
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
              color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
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
                              color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 12)),
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
                  inactiveThumbColor: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
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
                iconColor: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                collapsedIconColor: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                tilePadding: EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: EdgeInsets.all(16),
                backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                collapsedBackgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong)),
                collapsedShape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong)),
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
                                    color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 12)),
                            SizedBox(height: 8),
                            Container(
                              padding:
                                  EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                                borderRadius: BorderRadius.circular(8),
                                border:
                                    Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _selectedLanguage,
                                  isExpanded: true,
                                  dropdownColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
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
                                    if (val != null) {
                                      setState(() => _selectedLanguage = val);
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
                                    color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 12)),
                            SizedBox(height: 8),
                            TextField(
                              controller: _customStopWordsController,
                              style: TextStyle(color: Colors.white),
                              cursorColor: Colors.white,
                              decoration: InputDecoration(
                                hintText: 'e.g. client, company, confidential',
                                hintStyle:
                                    TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                                filled: true,
                                fillColor: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 14),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                        color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong)),
                                enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                        color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong)),
                                focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                        color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong)),
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
}

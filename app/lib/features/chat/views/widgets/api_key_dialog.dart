import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/model_download_provider.dart';

class ApiKeyDialog extends ConsumerStatefulWidget {
  final String providerName;

  const ApiKeyDialog({super.key, required this.providerName});

  @override
  ConsumerState<ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends ConsumerState<ApiKeyDialog> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _baseUrlController =
      TextEditingController(text: 'http://localhost:11434/v1');
  final TextEditingController _modelNameController =
      TextEditingController(text: 'llama3.1');
  final FocusNode _apiKeyFocusNode = FocusNode();
  bool _isApiKeyFocused = false;
  bool _obscureApiKey = true;
  String _expiresIn = 'In 12 hours';

  final TextEditingController _pullCustomController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _apiKeyFocusNode.addListener(() {
      setState(() {
        _isApiKeyFocused = _apiKeyFocusNode.hasFocus;
      });
    });

    // Load existing key
    // use post-frame callback if depending on widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = widget.providerName.toLowerCase();
      ApiKeyStorage().getKey(provider).then((key) {
        if (key != null && mounted) {
          _apiKeyController.text = key;
        }
      });
      if (provider == 'local') {
        ApiKeyStorage().getValue('local_base_url').then((val) {
          if (val != null && val.isNotEmpty && mounted) {
            _baseUrlController.text = val;
          }
        });
        ApiKeyStorage().getValue('local_model_name').then((val) {
          if (val != null && val.isNotEmpty && mounted) {
            _modelNameController.text = val;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelNameController.dispose();
    _pullCustomController.dispose();
    _apiKeyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxWidth: 600),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .extension<AppThemeExtension>()!
              .sidebarBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Theme.of(context)
                  .extension<AppThemeExtension>()!
                  .borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding:
                  EdgeInsets.only(left: 24, right: 16, top: 16, bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Set API Key for ${widget.providerName}',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .textTertiary,
                        size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),

            Divider(
                color: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .borderColor,
                height: 1,
                thickness: 1),

            // Content
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.providerName.toLowerCase() != 'local') ...[
                        Text(
                          'Your key will never expire',
                          style: TextStyle(
                              color: Color(0xFFEF4444),
                              fontSize: 12,
                              fontWeight: FontWeight.w500), // Tailwind Red 500
                        ),
                        SizedBox(height: 12),

                        // Expires dropdown
                        Theme(
                          data: Theme.of(context).copyWith(
                            hoverColor: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .borderColor,
                          ),
                          child: PopupMenuButton<String>(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .sidebarBackground,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .borderColor),
                            ),
                            position: PopupMenuPosition.under,
                            onSelected: (value) {
                              setState(() {
                                _expiresIn = value;
                              });
                            },
                            itemBuilder: (context) {
                              final options = [
                                'In 30 minutes',
                                'In 2 hours',
                                'In 12 hours',
                                'In 1 day',
                                'In 7 days',
                                'In 30 days',
                                'never'
                              ];
                              return options.map((option) {
                                return PopupMenuItem<String>(
                                  value: option,
                                  height: 36,
                                  padding: EdgeInsets.symmetric(horizontal: 16),
                                  child: Row(
                                    children: [
                                      Text(option,
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500)),
                                      if (_expiresIn == option) ...[
                                        const Spacer(),
                                        Icon(Icons.check,
                                            color: Colors.white, size: 16),
                                      ]
                                    ],
                                  ),
                                );
                              }).toList();
                            },
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .surfaceHighlight,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                      _expiresIn == 'never'
                                          ? 'never'
                                          : 'Expires ${_expiresIn.toLowerCase()}',
                                      style: TextStyle(
                                          color: Colors.white, fontSize: 13)),
                                  SizedBox(width: 4),
                                  Icon(Icons.keyboard_arrow_down,
                                      color: Colors.white, size: 16),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      SizedBox(height: 24),
                      if (widget.providerName.toLowerCase() == 'google') ...[
                        // Field 1: Service Account Key
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                                child: Text(
                                    '${widget.providerName} Service Account Key',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500))),
                            SizedBox(width: 8),
                            Flexible(
                                child: Text(
                                    '(from ${widget.providerName} Cloud Platform)',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .textTertiary,
                                        fontSize: 11),
                                    textAlign: TextAlign.right)),
                          ],
                        ),
                        SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .borderColor,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF3A3A3A)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.note_add_outlined,
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  size: 16),
                              SizedBox(width: 8),
                              Text('Import Service Account JSON Key.',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .extension<AppThemeExtension>()!
                                          .textTertiary,
                                      fontSize: 13)),
                            ],
                          ),
                        ),

                        SizedBox(height: 24),
                      ],
                      if (widget.providerName.toLowerCase() == 'local') ...[
                        // Field: Base URL
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                                child: Text('Base URL',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500))),
                            SizedBox(width: 8),
                            Flexible(
                                child: Text('[OpenAI-Compatible Endpoint]',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .textTertiary,
                                        fontSize: 11),
                                    textAlign: TextAlign.right)),
                          ],
                        ),
                        SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .cardBackground,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF3A3A3A)),
                          ),
                          child: TextField(
                            controller: _baseUrlController,
                            style: TextStyle(color: Colors.white, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'e.g., http://localhost:11434/v1',
                              hintStyle: TextStyle(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  fontSize: 13),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                            ),
                          ),
                        ),
                        SizedBox(height: 16),

                        // Field: Model Name
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                                child: Text('Model Name',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500))),
                            SizedBox(width: 8),
                            Flexible(
                                child: Text('[Required by Endpoint]',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .textTertiary,
                                        fontSize: 11),
                                    textAlign: TextAlign.right)),
                          ],
                        ),
                        SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .cardBackground,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF3A3A3A)),
                          ),
                          child: TextField(
                            controller: _modelNameController,
                            style: TextStyle(color: Colors.white, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'e.g., llama3.1',
                              hintStyle: TextStyle(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  fontSize: 13),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                            ),
                          ),
                        ),
                        SizedBox(height: 16),
                      ],
                      if (widget.providerName.toLowerCase() == 'local') ...[
                        Text('Model Manager (Download & Pull)',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        SizedBox(height: 8),
                        Text(
                            'Download a .gguf model directly to your device storage for offline inference.',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .textTertiary,
                                fontSize: 12)),
                        SizedBox(height: 16),
                        Builder(builder: (context) {
                          final dlState = ref.watch(modelDownloadProvider);
                          if (dlState.isDownloading) {
                            return Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .cardBackground,
                                borderRadius: BorderRadius.circular(6),
                                border:
                                    Border.all(color: const Color(0xFF3A3A3A)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.cloud_download_outlined,
                                          size: 14,
                                          color:
                                              Theme.of(context).primaryColor),
                                      SizedBox(width: 8),
                                      Text('Downloading...',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500)),
                                    ],
                                  ),
                                  SizedBox(height: 12),
                                  LinearProgressIndicator(
                                    value: dlState.progress,
                                    backgroundColor: const Color(0xFF2A2A2A),
                                    color: Theme.of(context).primaryColor,
                                  ),
                                  SizedBox(height: 8),
                                  Text(dlState.status,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .extension<AppThemeExtension>()!
                                              .textTertiary,
                                          fontSize: 11)),
                                ],
                              ),
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _buildModelCard(
                                      'Llama 3.2 1B',
                                      'Meta • 1.3 GB',
                                      'https://huggingface.co/hugging-quants/Llama-3.2-1B-Instruct-Q8_0-GGUF/resolve/main/llama-3.2-1b-instruct-q8_0.gguf',
                                      'llama-3.2-1b-instruct-q8_0.gguf',
                                    ),
                                    _buildModelCard(
                                      'Llama 3.1 8B',
                                      'Meta • 4.7 GB',
                                      'https://huggingface.co/QuantFactory/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct.Q4_K_M.gguf',
                                      'llama-3.1-8b-instruct-q4_k_m.gguf',
                                    ),
                                    _buildModelCard(
                                      'Phi-3 Mini 4K',
                                      'Microsoft • 2.4 GB',
                                      'https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf',
                                      'phi-3-mini-4k-instruct-q4.gguf',
                                    ),
                                    _buildModelCard(
                                      'Gemma-2 2B',
                                      'Google • 1.6 GB',
                                      'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf',
                                      'gemma-2-2b-it-q4_k_m.gguf',
                                    ),
                                    _buildModelCard(
                                      'Pixtral 12B',
                                      'Mistral • 6.8 GB',
                                      'https://huggingface.co/bartowski/Pixtral-12B-2409-GGUF/resolve/main/Pixtral-12B-2409-Q4_K_M.gguf',
                                      'pixtral-12b-2409-q4_k_m.gguf',
                                      isVision: true,
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: 16),
                              Text('Pull via Ollama',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500)),
                              SizedBox(height: 8),
                              Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .cardBackground,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: const Color(0xFF3A3A3A)),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _pullCustomController,
                                        style: TextStyle(
                                            color: Colors.white, fontSize: 13),
                                        decoration: InputDecoration(
                                          hintText: 'e.g. mistral',
                                          hintStyle: TextStyle(
                                              color: Theme.of(context)
                                                  .extension<
                                                      AppThemeExtension>()!
                                                  .textTertiary,
                                              fontSize: 13),
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 12),
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        final url = _pullCustomController.text;
                                        if (url.isNotEmpty) {
                                          // Call a pull provider here if desired
                                        }
                                      },
                                      style: TextButton.styleFrom(
                                        foregroundColor:
                                            Theme.of(context).primaryColor,
                                      ),
                                      child: Text('Pull'),
                                    )
                                  ],
                                ),
                              ),
                            ],
                          );
                        }),
                      ] else ...[
                        // Field 2: API Key
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                                child: Text('${widget.providerName} API Key',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500))),
                            SizedBox(width: 8),
                            Flexible(
                                child: Text('[${widget.providerName} API]',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .textTertiary,
                                        fontSize: 11),
                                    textAlign: TextAlign.right)),
                          ],
                        ),
                        SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .cardBackground,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF3A3A3A)),
                          ),
                          child: TextField(
                            controller: _apiKeyController,
                            focusNode: _apiKeyFocusNode,
                            obscureText: _obscureApiKey,
                            style: TextStyle(color: Colors.white, fontSize: 14),
                            decoration: InputDecoration(
                              hintText:
                                  'Enter value for ${widget.providerName} API Key',
                              hintStyle: TextStyle(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  fontSize: 13),
                              border: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              filled: false,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                              suffixIcon: _isApiKeyFocused
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: Icon(
                                            _obscureApiKey
                                                ? Icons.visibility_off_outlined
                                                : Icons.visibility_outlined,
                                            color: Theme.of(context)
                                                .extension<AppThemeExtension>()!
                                                .textTertiary,
                                            size: 18,
                                          ),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                              minWidth: 32, minHeight: 32),
                                          onPressed: () {
                                            setState(() {
                                              _obscureApiKey = !_obscureApiKey;
                                            });
                                          },
                                        ),
                                        SizedBox(width: 4),
                                      ],
                                    )
                                  : null,
                            ),
                          ),
                        ),

                        SizedBox(height: 24),

                        if (widget.providerName.toLowerCase() == 'google') ...[
                          // Help Text
                          RichText(
                            text: TextSpan(
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  fontSize: 12,
                                  height: 1.5),
                              children: [
                                TextSpan(
                                    text:
                                        '${widget.providerName} Service Account Key: You need to '),
                                _linkSpan('Enable Vertex AI',
                                    url:
                                        'https://console.cloud.google.com/vertex-ai'),
                                const TextSpan(
                                    text: ' API on Google Cloud, then '),
                                _linkSpan('Create a Service Account',
                                    url:
                                        'https://console.cloud.google.com/projectselector/iam-admin/serviceaccounts/create?walkthrough_id=iam--create-service-account#step_index=1'),
                                const TextSpan(
                                    text:
                                        '. Make sure to click \'Create and Continue\' to give at least the \'Vertex AI User\' role. Lastly, create a JSON key to import here.'),
                              ],
                            ),
                          ),
                          SizedBox(height: 12),
                          RichText(
                            text: TextSpan(
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  fontSize: 12,
                                  height: 1.5),
                              children: [
                                TextSpan(
                                    text:
                                        '${widget.providerName} API Key: To get your Generative Language API key (for Gemini), '),
                                _linkSpan('Click Here',
                                    url:
                                        'https://makersuite.google.com/app/apikey'),
                              ],
                            ),
                          ),
                        ] else if (widget.providerName.toLowerCase() ==
                            'groq') ...[
                          RichText(
                            text: TextSpan(
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  fontSize: 12,
                                  height: 1.5),
                              children: [
                                TextSpan(
                                    text:
                                        'To get your ${widget.providerName} API Key, '),
                                _linkSpan('Click Here',
                                    url: 'https://console.groq.com/keys'),
                                const TextSpan(
                                    text: ' and create a new API key.'),
                              ],
                            ),
                          ),
                        ] else ...[
                          RichText(
                            text: TextSpan(
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary,
                                  fontSize: 12,
                                  height: 1.5),
                              children: [
                                TextSpan(
                                    text:
                                        'Please enter your ${widget.providerName} API Key to use their models. Your key is stored securely in your browser and is only used to communicate with ${widget.providerName}.'),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),

            Divider(
                color: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .borderColor,
                height: 1,
                thickness: 1),

            // Footer (Actions)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () async {
                      final provider = widget.providerName.toLowerCase();
                      await ApiKeyStorage().clearKey(provider);
                      if (provider == 'local') {
                        await ApiKeyStorage().saveValue('local_base_url', '');
                        await ApiKeyStorage().saveValue('local_model_name', '');
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    style: TextButton.styleFrom(
                      backgroundColor:
                          const Color(0xFFB91C1C), // Tailwind Red 700
                      foregroundColor: Colors.white,
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                    ),
                    child: Text('Revoke',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                  ),
                  SizedBox(width: 12),
                  TextButton(
                    onPressed: () async {
                      final provider = widget.providerName.toLowerCase();
                      await ApiKeyStorage().saveKey(
                          provider, _apiKeyController.text,
                          expiresIn: _expiresIn);
                      if (provider == 'local') {
                        await ApiKeyStorage().saveValue(
                            'local_base_url', _baseUrlController.text);
                        await ApiKeyStorage().saveValue(
                            'local_model_name', _modelNameController.text);
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .secondary, // ChatGPT Green
                      foregroundColor: Colors.white,
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                    ),
                    child: Text('Submit',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelCard(
      String title, String details, String url, String filename,
      {bool isVision = false}) {
    return Container(
      width: 240, // Fixed width for horizontal scrolling
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(Icons.psychology,
                    size: 20, color: Theme.of(context).primaryColor),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    SizedBox(height: 2),
                    Text(details,
                        style: TextStyle(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .textTertiary,
                            fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isVision
                      ? Colors.purple.withValues(alpha: 0.2)
                      : Colors.blue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(isVision ? 'Vision' : 'Text-only',
                    style: TextStyle(
                        color: isVision ? Colors.purple[300] : Colors.blue[300],
                        fontSize: 10,
                        fontWeight: FontWeight.w600)),
              ),
              SizedBox(
                height: 28,
                child: TextButton(
                  onPressed: () {
                    ref
                        .read(modelDownloadProvider.notifier)
                        .downloadLocalModel(url, filename);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).primaryColor,
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  ),
                  child: Text('Download', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  TextSpan _linkSpan(String text, {String? url}) {
    return TextSpan(
      text: text,
      style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline), // Tailwind Blue 500
      recognizer: TapGestureRecognizer()
        ..onTap = () async {
          if (url != null) {
            final uri = Uri.parse(url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri);
            }
          }
        },
    );
  }
}

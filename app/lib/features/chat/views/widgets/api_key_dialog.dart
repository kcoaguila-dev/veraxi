import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/api_key_storage.dart';

class ApiKeyDialog extends StatefulWidget {
  final String providerName;

  const ApiKeyDialog({super.key, required this.providerName});

  @override
  State<ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends State<ApiKeyDialog> {
  final TextEditingController _apiKeyController = TextEditingController();
  final FocusNode _apiKeyFocusNode = FocusNode();
  bool _isApiKeyFocused = false;
  bool _obscureApiKey = true;
  String _expiresIn = 'In 12 hours';

  @override
  void initState() {
    super.initState();
    _apiKeyFocusNode.addListener(() {
      setState(() {
        _isApiKeyFocused = _apiKeyFocusNode.hasFocus;
      });
    });
    
    // Load existing key
    ApiKeyStorage().getGeminiKey().then((key) {
      if (key != null && mounted) {
        _apiKeyController.text = key;
      }
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _apiKeyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxWidth: 600),
        decoration: BoxDecoration(
          color: const Color(0xFF171717),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF2A2A2A)),
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
              padding: const EdgeInsets.only(left: 24, right: 16, top: 16, bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Set API Key for ${widget.providerName}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF878787), size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
            
            const Divider(color: Color(0xFF2A2A2A), height: 1, thickness: 1),
            
            // Content
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Your key will never expire',
                    style: TextStyle(color: Color(0xFFEF4444), fontSize: 12, fontWeight: FontWeight.w500), // Tailwind Red 500
                  ),
                  const SizedBox(height: 12),
                  
                  // Expires dropdown
                  Theme(
                    data: Theme.of(context).copyWith(
                      hoverColor: const Color(0xFF2A2A2A),
                    ),
                    child: PopupMenuButton<String>(
                      color: const Color(0xFF171717),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
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
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Text(option, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                                if (_expiresIn == option) ...[
                                  const Spacer(),
                                  const Icon(Icons.check, color: Colors.white, size: 16),
                                ]
                              ],
                            ),
                          );
                        }).toList();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2F2F2F),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_expiresIn == 'never' ? 'never' : 'Expires ${_expiresIn.toLowerCase()}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Field 1: Service Account Key
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${widget.providerName} Service Account Key', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                      Text('(from ${widget.providerName} Cloud Platform)', style: const TextStyle(color: Color(0xFF878787), fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF3A3A3A)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.note_add_outlined, color: Color(0xFF878787), size: 16),
                        SizedBox(width: 8),
                        Text('Import Service Account JSON Key.', style: TextStyle(color: Color(0xFF878787), fontSize: 13)),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Field 2: API Key
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${widget.providerName} API Key', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                      const Text('[Gemini API]', style: TextStyle(color: Color(0xFF878787), fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF3A3A3A)),
                    ),
                    child: TextField(
                      controller: _apiKeyController,
                      focusNode: _apiKeyFocusNode,
                      obscureText: _obscureApiKey,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Enter value for ${widget.providerName} API Key',
                        hintStyle: const TextStyle(color: Color(0xFF878787), fontSize: 13),
                        border: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        suffixIcon: _isApiKeyFocused
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      _obscureApiKey ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                      color: const Color(0xFF878787),
                                      size: 18,
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                    onPressed: () {
                                      setState(() {
                                        _obscureApiKey = !_obscureApiKey;
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 4),
                                ],
                              )
                            : null,
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Help Text
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(color: Color(0xFF878787), fontSize: 12, height: 1.5),
                      children: [
                        TextSpan(text: '${widget.providerName} Service Account Key: You need to '),
                        _linkSpan('Enable Vertex AI', url: 'https://console.cloud.google.com/vertex-ai'),
                        const TextSpan(text: ' API on Google Cloud, then '),
                        _linkSpan('Create a Service Account', url: 'https://console.cloud.google.com/projectselector/iam-admin/serviceaccounts/create?walkthrough_id=iam--create-service-account#step_index=1'),
                        const TextSpan(text: '. Make sure to click \'Create and Continue\' to give at least the \'Vertex AI User\' role. Lastly, create a JSON key to import here.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(color: Color(0xFF878787), fontSize: 12, height: 1.5),
                      children: [
                        TextSpan(text: '${widget.providerName} API Key: To get your Generative Language API key (for Gemini), '),
                        _linkSpan('Click Here', url: 'https://makersuite.google.com/app/apikey'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            
            const Divider(color: Color(0xFF2A2A2A), height: 1, thickness: 1),
            
            // Footer (Actions)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () async {
                      await ApiKeyStorage().clearGeminiKey();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFFB91C1C), // Tailwind Red 700
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    child: const Text('Revoke', style: TextStyle(fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () async {
                      await ApiKeyStorage().saveGeminiKey(_apiKeyController.text, expiresIn: _expiresIn);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFF10A37F), // ChatGPT Green
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    child: const Text('Submit', style: TextStyle(fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextSpan _linkSpan(String text, {String? url}) {
    return TextSpan(
      text: text,
      style: const TextStyle(color: Color(0xFF3B82F6), decoration: TextDecoration.underline), // Tailwind Blue 500
      recognizer: TapGestureRecognizer()..onTap = () async {
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

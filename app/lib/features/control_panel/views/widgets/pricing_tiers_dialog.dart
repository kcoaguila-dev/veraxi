import 'package:flutter/material.dart';

class PricingTiersDialog extends StatelessWidget {
  const PricingTiersDialog({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 800,
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: const Color(0xFF131313),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 32,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF878787)),
                onPressed: () => Navigator.of(context).pop(),
                splashRadius: 20,
              ),
            ),
            const Text(
              'Plans that grow with you',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w500,
                fontFamily: 'serif',
              ),
            ),
            const SizedBox(height: 24),
            // Fake Segmented Control
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Individual',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: const Text(
                      'Team and Enterprise',
                      style: TextStyle(color: Color(0xFF878787), fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
            // Pricing Cards
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPricingCard(
                  context,
                  title: 'Free',
                  subtitle: 'Local-First & BYOK',
                  price: '\$0',
                  buttonText: 'Current Plan',
                  isPrimary: false,
                  features: [
                    'Bring your own LLM API Keys',
                    'Run your own local Neo4j & Qdrant',
                    'Basic chat, Web search, and iOS/Android',
                    'Generate code and visualize data',
                    '5MB file upload limit',
                  ],
                ),
                const SizedBox(width: 24),
                _buildPricingCard(
                  context,
                  title: 'Pro',
                  subtitle: 'Fully Cloud Hosted',
                  price: '\$19',
                  priceSubtext: 'USD / month',
                  buttonText: 'Get Pro plan',
                  isPrimary: true,
                  features: [
                    'We host the AI models & Databases',
                    'Advanced Agentic Workflows & Cowork',
                    '50MB file upload limit',
                    '2GB Total Knowledge Base Storage',
                    'Priority support and early access',
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPricingCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String price,
    String? priceSubtext,
    required String buttonText,
    required bool isPrimary,
    required List<String> features,
  }) {
    return Container(
      width: 320,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isPrimary ? Icons.auto_awesome : Icons.eco, color: Colors.white, size: 28),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF878787), fontSize: 14),
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                price,
                style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold),
              ),
              if (priceSubtext != null) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Text(
                    priceSubtext,
                    style: const TextStyle(color: Color(0xFF878787), fontSize: 13),
                  ),
                ),
              ]
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isPrimary ? Colors.white : const Color(0xFF2A2A2A),
                foregroundColor: isPrimary ? Colors.black : Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: isPrimary ? () {
                // Future checkout integration
              } : null,
              child: Text(
                buttonText,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isPrimary ? Colors.black : const Color(0xFF878787),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          ...features.map((feature) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check, color: Color(0xFF878787), size: 18),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        feature,
                        style: TextStyle(
                          color: feature.startsWith('Everything in') ? Colors.white : const Color(0xFFB4B4B4),
                          fontSize: 13,
                          height: 1.4,
                          fontWeight: feature.startsWith('Everything in') ? FontWeight.w500 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

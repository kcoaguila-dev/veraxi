import 'package:flutter/material.dart';
import 'pricing_tiers_dialog.dart';

class BillingView extends StatelessWidget {
  const BillingView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Billing & Plans',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Manage your subscription and billing details.',
            style: TextStyle(
              color: Color(0xFF878787),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 32),

          // Current Plan Card
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: const Color(0xFF131313), // Match Pic 2 aesthetic
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(Icons.eco_outlined,
                            color: Colors.white, size: 36),
                        const SizedBox(width: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Free plan',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Local-First & BYOK',
                              style: TextStyle(
                                color: Color(0xFF878787),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => const PricingTiersDialog(),
                        );
                      },
                      child: const Text(
                        'Upgrade plan',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // Feature List
                _buildFeatureRow('Bring your own LLM API Keys'),
                _buildFeatureRow('Run your own local Neo4j & Qdrant'),
                _buildFeatureRow('Basic chat, Web search, and iOS/Android'),
                _buildFeatureRow('Generate code and visualize data'),
                _buildFeatureRow('5MB file upload limit'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureRow(String feature) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.check, color: Color(0xFF878787), size: 18),
          const SizedBox(width: 12),
          Text(
            feature,
            style: const TextStyle(
              color: Color(0xFFB4B4B4),
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'pricing_tiers_dialog.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class BillingView extends StatelessWidget {
  const BillingView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Billing & Plans',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Manage your subscription and billing details.',
            style: TextStyle(
              color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
              fontSize: 14,
            ),
          ),
          SizedBox(height: 32),

          // Current Plan Card
          Container(
            padding: EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground, // Match Pic 2 aesthetic
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
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
                        Icon(Icons.eco_outlined,
                            color: Colors.white, size: 36),
                        SizedBox(width: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                                color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
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
                        padding: EdgeInsets.symmetric(
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
                      child: Text(
                        'Upgrade plan',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 32),

                // Feature List
                _buildFeatureRow(context, 'Bring your own LLM API Keys'),
                _buildFeatureRow(context, 'Run your own local Neo4j & Qdrant'),
                _buildFeatureRow(context, 'Basic chat, Web search, and iOS/Android'),
                _buildFeatureRow(context, 'Generate code and visualize data'),
                _buildFeatureRow(context, '50MB file upload limit'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureRow(BuildContext context, String feature) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.check, color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 18),
          SizedBox(width: 12),
          Text(
            feature,
            style: TextStyle(
              color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

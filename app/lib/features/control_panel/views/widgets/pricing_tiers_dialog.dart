import 'package:flutter/material.dart';
import 'package:veraxi_app/features/control_panel/views/checkout_screen.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class PricingTiersDialog extends StatefulWidget {
  const PricingTiersDialog({Key? key}) : super(key: key);

  @override
  State<PricingTiersDialog> createState() => _PricingTiersDialogState();
}

class _PricingTiersDialogState extends State<PricingTiersDialog> {
  bool _isEnterprise = false;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.all(24),
      child: Container(
        width: 800,
        constraints: const BoxConstraints(maxHeight: 850),
        padding: EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 32,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: Icon(Icons.close, color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                  onPressed: () => Navigator.of(context).pop(),
                  splashRadius: 20,
                ),
              ),
              Text(
                'Plans that grow with you',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'serif',
                ),
              ),
              SizedBox(height: 24),
              // Fake Segmented Control
              Container(
                padding: EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () => setState(() => _isEnterprise = false),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 20, vertical: 8),
                        decoration: BoxDecoration(
                          color: !_isEnterprise
                              ? Theme.of(context).extension<AppThemeExtension>()!.borderColor
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Individual',
                          style: TextStyle(
                              color: !_isEnterprise
                                  ? Colors.white
                                  : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _isEnterprise = true),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 20, vertical: 8),
                        decoration: BoxDecoration(
                          color: _isEnterprise
                              ? Theme.of(context).extension<AppThemeExtension>()!.borderColor
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Team and Enterprise',
                          style: TextStyle(
                              color: _isEnterprise
                                  ? Colors.white
                                  : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 48),
              // Pricing Cards
              IntrinsicHeight(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: !_isEnterprise
                      ? [
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
                              '50MB file upload limit',
                            ],
                          ),
                          SizedBox(width: 24),
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
                        ]
                      : [
                          _buildPricingCard(
                            context,
                            title: 'Team',
                            subtitle: 'Secure Collaborative Workspace',
                            price: '\$25',
                            priceSubtext: 'USD / user / mo',
                            buttonText: 'Upgrade to Team',
                            isPrimary: true,
                            features: [
                              'Everything in Pro',
                              'Centralized Admin Console & Billing',
                              'Collaborative Agent Workspaces',
                              'Zero data retention for training',
                            ],
                          ),
                          SizedBox(width: 24),
                          _buildPricingCard(
                            context,
                            title: 'Enterprise',
                            subtitle: 'Large-Scale & Compliant',
                            price: 'Custom',
                            buttonText: 'Contact Sales',
                            isPrimary: false,
                            features: [
                              'Everything in Team',
                              'Single Sign-On (SAML/SSO)',
                              'Dedicated Account Manager & SLA',
                              'Custom data residency & compliance',
                            ],
                          ),
                        ],
                ),
              ),
            ],
          ),
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
      padding: EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isPrimary ? Icons.auto_awesome : Icons.eco,
              color: Colors.white, size: 28),
          SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 14),
          ),
          SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                price,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.bold),
              ),
              if (priceSubtext != null) ...[
                SizedBox(width: 8),
                Padding(
                  padding: EdgeInsets.only(bottom: 8.0),
                  child: Text(
                    priceSubtext,
                    style:
                        TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
                  ),
                ),
              ]
            ],
          ),
          SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isPrimary ? Colors.white : Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                foregroundColor: isPrimary ? Colors.black : Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: isPrimary
                  ? () {
                      Navigator.of(context).pop(); // Close dialog
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (context) => const CheckoutScreen()),
                      );
                    }
                  : null,
              child: Text(
                buttonText,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isPrimary ? Colors.black : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                ),
              ),
            ),
          ),
          SizedBox(height: 32),
          ...features.map((feature) => Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check, color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 18),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        feature,
                        style: TextStyle(
                          color: feature.startsWith('Everything in')
                              ? Colors.white
                              : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                          fontSize: 15,
                          height: 1.5,
                          fontWeight: feature.startsWith('Everything in')
                              ? FontWeight.w500
                              : FontWeight.normal,
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/features/control_panel/data/payment_repository.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  bool _isAnnual = false;
  bool _termsAccepted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
      appBar: AppBar(
        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('Upgrade',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding:
                EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth > 800) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: _buildLeftColumn()),
                        SizedBox(width: 64),
                        Expanded(flex: 2, child: _buildRightColumn()),
                      ],
                    );
                  } else {
                    return Column(
                      children: [
                        _buildLeftColumn(),
                        SizedBox(height: 48),
                        _buildRightColumn(),
                      ],
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeftColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Configure your plan',
          style: TextStyle(
              color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 24),

        // Plan Toggles
        Row(
          children: [
            Expanded(
              child: _buildPlanToggle(
                title: 'Pro monthly',
                price: 'USD 19.00',
                subtitle: 'Billed monthly',
                isSelected: !_isAnnual,
                onTap: () => setState(() => _isAnnual = false),
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: _buildPlanToggle(
                title: 'Pro annual',
                price: 'USD 190.00',
                subtitle: 'Billed yearly',
                badge: 'Save 17%',
                isSelected: _isAnnual,
                onTap: () => setState(() => _isAnnual = true),
              ),
            ),
          ],
        ),
        SizedBox(height: 48),

        Text(
          'Billing information',
          style: TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 16),
        _buildTextField('Full name'),
        SizedBox(height: 16),
        _buildDropdownField(
            'Country or region',
            [
              'United States',
              'Canada',
              'United Kingdom',
              'Japan',
              'Germany',
              'France',
              'Australia'
            ],
            'United States'),
        SizedBox(height: 16),
        _buildTextField('Postal code'),
        SizedBox(height: 16),
        _buildTextField('Business name (optional)'),
        SizedBox(height: 48),

        Text(
          'Payment method',
          style: TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 16),
        _buildTextField('Card number', hint: '1234 1234 1234 1234'),
        SizedBox(height: 16),
        Row(
          children: [
            Expanded(
                child: _buildTextField('Expiration date', hint: 'MM / YY')),
            SizedBox(width: 16),
            Expanded(child: _buildTextField('Security code', hint: 'CVC')),
          ],
        ),
      ],
    );
  }

  Widget _buildRightColumn() {
    final subtotal = _isAnnual ? 190.00 : 19.00;
    final tax = subtotal * 0.10; // Dummy 10% tax for display
    final total = subtotal + tax;

    return Container(
      padding: EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pro plan',
            style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                fontFamily: 'serif'), // Anthropic-style serif touch
          ),
          SizedBox(height: 32),
          _buildSummaryRow(_isAnnual ? 'Pro annual' : 'Pro monthly',
              '\$${subtotal.toStringAsFixed(2)}'),
          SizedBox(height: 12),
          _buildSummaryRow('Subtotal', '\$${subtotal.toStringAsFixed(2)}'),
          SizedBox(height: 12),
          _buildSummaryRow('Tax', '\$${tax.toStringAsFixed(2)}'),
          SizedBox(height: 16),
          Divider(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
          SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total due today',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              Text('\$${total.toStringAsFixed(2)}',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          SizedBox(height: 32),

          // Disclaimer Box
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 18),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Your subscription will auto-renew on ${DateTime.now().add(_isAnnual ? const Duration(days: 365) : const Duration(days: 30)).toString().substring(0, 10)}. You will be charged \$${subtotal.toStringAsFixed(2)}/${_isAnnual ? "year" : "month"} + tax.',
                    style:
                        TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 24),

          // Terms Checkbox
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _termsAccepted,
                  onChanged: (val) =>
                      setState(() => _termsAccepted = val ?? false),
                  fillColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? Theme.of(context).colorScheme.secondary
                          : Colors.transparent),
                  side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'You agree that Veraxi will charge your card in the amount above now and on a recurring basis until you cancel in accordance with our terms. You can cancel at any time in your account settings.',
                  style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12),
                ),
              ),
            ],
          ),
          SizedBox(height: 32),

          // Subscribe Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _termsAccepted ? Colors.white : (Theme.of(context).extension<AppThemeExtension>()?.textTertiary.withValues(alpha: 0.5) ?? Colors.grey),
                foregroundColor: Colors.black,
                padding: EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              onPressed: _termsAccepted
                  ? () async {
                      try {
                        final paymentRepo = ref.read(paymentRepositoryProvider);
                        final checkoutUrl = await paymentRepo.createCheckoutSession(
                          plan: _isAnnual ? 'annual' : 'monthly',
                        );

                        if (checkoutUrl != null) {
                          final uri = Uri.parse(checkoutUrl);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Could not launch payment portal.')),
                              );
                            }
                          }
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    'Error creating checkout session: $e')),
                          );
                        }
                      }
                    }
                  : null,
              child: Text('Subscribe',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String amount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 14)),
        Text(amount,
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 14)),
      ],
    );
  }

  Widget _buildPlanToggle({
    required String title,
    required String price,
    required String subtitle,
    String? badge,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1A2235)
              : Theme.of(context).extension<AppThemeExtension>()!.cardBackground, // Subtle blue tint when selected
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                isSelected ? Theme.of(context).colorScheme.primary : Theme.of(context).extension<AppThemeExtension>()!.borderColor,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                  size: 20,
                ),
                if (badge != null)
                  Text(badge,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
              ],
            ),
            SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500)),
            SizedBox(height: 8),
            Text(price,
                style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14)),
            SizedBox(height: 4),
            Text(subtitle,
                style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(String label, {String? hint, String? initialValue}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        SizedBox(height: 8),
        TextFormField(
          initialValue: initialValue,
          style: TextStyle(color: Colors.white, fontSize: 14),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: (Theme.of(context).extension<AppThemeExtension>()?.textTertiary.withValues(alpha: 0.5) ?? Colors.grey)),
            filled: true,
            fillColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdownField(
      String label, List<String> options, String initialValue) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: initialValue,
          dropdownColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          style: TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          icon: Icon(Icons.keyboard_arrow_down, color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
          items: options.map((String value) {
            return DropdownMenuItem<String>(
              value: value,
              child: Text(value),
            );
          }).toList(),
          onChanged: (String? newValue) {},
        ),
      ],
    );
  }
}

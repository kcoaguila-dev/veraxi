import 'package:flutter/material.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({Key? key}) : super(key: key);

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _isAnnual = false;
  bool _termsAccepted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF131313),
      appBar: AppBar(
        backgroundColor: const Color(0xFF131313),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Upgrade', style: TextStyle(color: Colors.white, fontSize: 16)),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth > 800) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: _buildLeftColumn()),
                        const SizedBox(width: 64),
                        Expanded(flex: 2, child: _buildRightColumn()),
                      ],
                    );
                  } else {
                    return Column(
                      children: [
                        _buildLeftColumn(),
                        const SizedBox(height: 48),
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
        const Text(
          'Configure your plan',
          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 24),
        
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
            const SizedBox(width: 16),
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
        const SizedBox(height: 48),

        const Text(
          'Billing information',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        _buildTextField('Full name'),
        const SizedBox(height: 16),
        _buildDropdownField('Country or region', ['United States', 'Canada', 'United Kingdom', 'Japan', 'Germany', 'France', 'Australia'], 'United States'),
        const SizedBox(height: 16),
        _buildTextField('Postal code'),
        const SizedBox(height: 16),
        _buildTextField('Business name (optional)'),
        const SizedBox(height: 48),

        const Text(
          'Payment method',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        _buildTextField('Card number', hint: '1234 1234 1234 1234'),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _buildTextField('Expiration date', hint: 'MM / YY')),
            const SizedBox(width: 16),
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
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pro plan',
            style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold, fontFamily: 'serif'), // Anthropic-style serif touch
          ),
          const SizedBox(height: 32),
          _buildSummaryRow(_isAnnual ? 'Pro annual' : 'Pro monthly', '\$${subtotal.toStringAsFixed(2)}'),
          const SizedBox(height: 12),
          _buildSummaryRow('Subtotal', '\$${subtotal.toStringAsFixed(2)}'),
          const SizedBox(height: 12),
          _buildSummaryRow('Tax', '\$${tax.toStringAsFixed(2)}'),
          const SizedBox(height: 16),
          const Divider(color: Color(0xFF333333)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total due today', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              Text('\$${total.toStringAsFixed(2)}', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 32),
          
          // Disclaimer Box
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, color: Color(0xFF878787), size: 18),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Your subscription will auto-renew on ${DateTime.now().add(_isAnnual ? const Duration(days: 365) : const Duration(days: 30)).toString().substring(0, 10)}. You will be charged \$${subtotal.toStringAsFixed(2)}/${_isAnnual ? "year" : "month"} + tax.',
                    style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          // Terms Checkbox
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _termsAccepted,
                  onChanged: (val) => setState(() => _termsAccepted = val ?? false),
                  fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? const Color(0xFF10A37F) : Colors.transparent),
                  side: const BorderSide(color: Color(0xFF878787)),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'You agree that Veraxi will charge your card in the amount above now and on a recurring basis until you cancel in accordance with our terms. You can cancel at any time in your account settings.',
                  style: TextStyle(color: Color(0xFF878787), fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          
          // Subscribe Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _termsAccepted ? Colors.white : const Color(0xFF4A4A4A),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              onPressed: _termsAccepted ? () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Stripe integration pending...')),
                );
              } : null,
              child: const Text('Subscribe', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
        Text(label, style: const TextStyle(color: Color(0xFF878787), fontSize: 14)),
        Text(amount, style: const TextStyle(color: Color(0xFF878787), fontSize: 14)),
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
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1A2235) : const Color(0xFF1E1E1E), // Subtle blue tint when selected
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFF2A2A2A),
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
                  isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFF878787),
                  size: 20,
                ),
                if (badge != null)
                  Text(badge, style: const TextStyle(color: Color(0xFF3B82F6), fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text(price, style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 14)),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: Color(0xFF878787), fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(String label, {String? hint, String? initialValue}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: initialValue,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF4A4A4A)),
            filled: true,
            fillColor: const Color(0xFF1E1E1E),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdownField(String label, List<String> options, String initialValue) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: initialValue,
          dropdownColor: const Color(0xFF1E1E1E),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF1E1E1E),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFF878787)),
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

final paymentRepositoryProvider = Provider<PaymentRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return PaymentRepository(apiClient: apiClient);
});

/// Repository for Stripe payment/checkout operations.
class PaymentRepository {
  final ApiClient apiClient;

  PaymentRepository({required this.apiClient});

  /// Creates a Stripe checkout session and returns the checkout URL.
  Future<String?> createCheckoutSession({required String plan}) async {
    final response = await apiClient.post(
      '/v1/payments/create-checkout-session',
      body: {'plan': plan},
    );
    return response['checkout_url'] as String?;
  }
}

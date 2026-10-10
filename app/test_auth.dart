import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  SupabaseClient client = SupabaseClient('a', 'b');
  client.auth.signInWithOAuth(OAuthProvider.google,
      authScreenLaunchMode: LaunchMode.externalApplication);
}

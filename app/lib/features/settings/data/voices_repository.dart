import 'package:supabase_flutter/supabase_flutter.dart';

class SavedVoice {
  final String id;
  final String userId;
  final String name;
  final String referenceId;
  final DateTime createdAt;

  SavedVoice({
    required this.id,
    required this.userId,
    required this.name,
    required this.referenceId,
    required this.createdAt,
  });

  factory SavedVoice.fromJson(Map<String, dynamic> json) {
    return SavedVoice(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      referenceId: json['reference_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'reference_id': referenceId,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

class VoicesRepository {
  final SupabaseClient _supabase;

  VoicesRepository(this._supabase);

  Future<List<SavedVoice>> getSavedVoices() async {
    final response = await _supabase
        .from('saved_voices')
        .select()
        .order('created_at', ascending: false);

    return (response as List<dynamic>)
        .map((e) => SavedVoice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SavedVoice> saveVoice(String name, String referenceId) async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      throw Exception('Must be logged in to save a voice.');
    }

    final response = await _supabase
        .from('saved_voices')
        .insert({
          'user_id': user.id,
          'name': name,
          'reference_id': referenceId,
        })
        .select()
        .single();

    return SavedVoice.fromJson(response);
  }

  Future<void> deleteVoice(String id) async {
    await _supabase.from('saved_voices').delete().eq('id', id);
  }
}

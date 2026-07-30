import 'dart:convert';

void main() {
  final jsonStr = '{"threads": [{"thread_id": "abc", "title": "New Chat"}]}';
  final data = jsonDecode(jsonStr);
  
  try {
    final threads = List<Map<String, dynamic>>.from(data['threads'] ?? []);
    print("Success: ${threads.length} threads, first id: ${threads[0]['thread_id']}");
  } catch (e) {
    print("Error: $e");
  }
}

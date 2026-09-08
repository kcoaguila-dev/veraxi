import 'package:flutter_riverpod/flutter_riverpod.dart';

final activeSourcesProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

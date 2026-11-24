/// Thinking/reasoning capability descriptor for a cloud or local LLM.
class ModelThinkingCapability {
  final String mode;
  final List<String> levels;
  final String? defaultLevel;
  final bool supportsReasoning;
  final String? runtime;

  const ModelThinkingCapability({
    required this.mode,
    required this.levels,
    required this.defaultLevel,
    required this.supportsReasoning,
    this.runtime,
  });

  static const ModelThinkingCapability none = ModelThinkingCapability(
    mode: 'none',
    levels: [],
    defaultLevel: null,
    supportsReasoning: false,
  );

  factory ModelThinkingCapability.fromJson(Map<String, dynamic> json) {
    final rawLevels = json['levels'];
    final levels = rawLevels is List
        ? rawLevels.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    final mode = json['mode']?.toString() ?? 'none';
    final supports = json['supports_reasoning'] == true && levels.isNotEmpty;
    return ModelThinkingCapability(
      mode: mode,
      levels: levels,
      defaultLevel: json['default_level']?.toString(),
      supportsReasoning: supports,
      runtime: json['runtime']?.toString(),
    );
  }

  /// Offline / immediate heuristic fallback before `/api/models/capabilities`
  /// resolves, or for on-device `.gguf` files.
  factory ModelThinkingCapability.forModel(String? modelName) {
    if (modelName == null ||
        modelName.isEmpty ||
        modelName == 'Select a model') {
      return none;
    }
    final m = modelName.toLowerCase();

    // On-device GGUF or local models
    if (m.endsWith('.gguf') || m.startsWith('local::')) {
      if (m.contains('gpt-oss')) {
        return const ModelThinkingCapability(
          mode: 'effort',
          levels: ['low', 'medium', 'high'],
          defaultLevel: 'medium',
          supportsReasoning: true,
          runtime: 'local',
        );
      }
      if (_hasLocalReasoningMarker(m)) {
        return const ModelThinkingCapability(
          mode: 'effort',
          levels: ['off', 'low', 'medium', 'high'],
          defaultLevel: 'medium',
          supportsReasoning: true,
          runtime: 'local',
        );
      }
      return none;
    }

    if (m.startsWith('gpt-5')) {
      if (m.contains('-chat')) return none;
      if (m.contains('-pro')) {
        return const ModelThinkingCapability(
          mode: 'effort',
          levels: ['low', 'medium', 'high', 'max'],
          defaultLevel: 'medium',
          supportsReasoning: true,
        );
      }
      return const ModelThinkingCapability(
        mode: 'effort',
        levels: ['off', 'minimal', 'low', 'medium', 'high', 'max'],
        defaultLevel: 'medium',
        supportsReasoning: true,
      );
    }

    if (m.startsWith('o1') || m.startsWith('o3') || m.startsWith('o4')) {
      return const ModelThinkingCapability(
        mode: 'effort',
        levels: ['low', 'medium', 'high'],
        defaultLevel: 'medium',
        supportsReasoning: true,
      );
    }

    if (m.startsWith('claude-')) {
      if (m.contains('claude-3-5') ||
          m.contains('claude-3-opus') ||
          m.contains('claude-3-sonnet') ||
          m.contains('claude-3-haiku')) {
        return none;
      }
      if (m.contains('claude-3-7') || m.contains('20250514')) {
        return const ModelThinkingCapability(
          mode: 'budget',
          levels: ['off', 'low', 'medium', 'high'],
          defaultLevel: 'medium',
          supportsReasoning: true,
        );
      }
      return const ModelThinkingCapability(
        mode: 'adaptive_effort',
        levels: ['off', 'low', 'medium', 'high', 'max'],
        defaultLevel: 'medium',
        supportsReasoning: true,
      );
    }

    if (m.startsWith('gemini-3')) {
      if (m.contains('pro')) {
        return const ModelThinkingCapability(
          mode: 'level',
          levels: ['low', 'medium', 'high'],
          defaultLevel: 'medium',
          supportsReasoning: true,
        );
      }
      return const ModelThinkingCapability(
        mode: 'level',
        levels: ['minimal', 'low', 'medium', 'high'],
        defaultLevel: 'medium',
        supportsReasoning: true,
      );
    }

    if (m.startsWith('gemini-2.5')) {
      if (m.contains('pro')) {
        return const ModelThinkingCapability(
          mode: 'budget',
          levels: ['low', 'medium', 'high'],
          defaultLevel: 'medium',
          supportsReasoning: true,
        );
      }
      return const ModelThinkingCapability(
        mode: 'budget',
        levels: ['off', 'low', 'medium', 'high'],
        defaultLevel: 'medium',
        supportsReasoning: true,
      );
    }

    if (m.startsWith('deepseek-reasoner') || m.startsWith('deepseek-r1')) {
      return const ModelThinkingCapability(
        mode: 'toggle',
        levels: ['on'],
        defaultLevel: 'on',
        supportsReasoning: true,
      );
    }

    if (m.startsWith('deepseek') ||
        m.contains('qwen3') ||
        m.startsWith('magistral') ||
        m == 'mistral-large-latest') {
      return const ModelThinkingCapability(
        mode: 'toggle',
        levels: ['off', 'on'],
        defaultLevel: 'off',
        supportsReasoning: true,
      );
    }

    if (m.contains('gpt-oss')) {
      return const ModelThinkingCapability(
        mode: 'effort',
        levels: ['low', 'medium', 'high'],
        defaultLevel: 'medium',
        supportsReasoning: true,
      );
    }

    return none;
  }

  static bool _hasLocalReasoningMarker(String lower) {
    const markers = [
      'qwen3',
      'qwq',
      'deepseek-r1',
      'r1-distill',
      'phi-4-reasoning',
      'magistral',
      'cogito',
    ];
    return markers.any(lower.contains);
  }

  /// Clamp [requested] to a supported level for this model, or null if none.
  String? clampLevel(String? requested) {
    if (!supportsReasoning || levels.isEmpty) return null;
    if (requested == null || requested.trim().isEmpty) {
      return defaultLevel ?? levels.first;
    }
    final norm = requested.trim().toLowerCase();
    if (levels.contains(norm)) return norm;

    if (mode == 'toggle') {
      if (norm == 'off' && levels.contains('off')) return 'off';
      return levels.contains('on') ? 'on' : (defaultLevel ?? levels.first);
    }

    if (norm == 'on') {
      return defaultLevel ?? levels.first;
    }

    const scale = ['off', 'minimal', 'low', 'medium', 'high', 'max'];
    final reqIdx = scale.indexOf(norm);
    if (reqIdx == -1) return defaultLevel ?? levels.first;

    var best = levels.first;
    var bestDist = 999;
    for (final cand in levels) {
      final candIdx = scale.indexOf(cand);
      if (candIdx == -1) continue;
      final dist = (candIdx - reqIdx).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = cand;
      }
    }
    return best;
  }
}

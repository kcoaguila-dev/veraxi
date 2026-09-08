/// Maps AI model names to their corresponding provider identifiers.
///
/// This is a pure utility — no dependencies, no state. Used by the
/// data layer to resolve API keys and by any future UI that needs
/// provider-aware behaviour (icons, branding, etc.).
class ModelProviderMapper {
  ModelProviderMapper._();

  /// Returns the provider key for a given model name.
  ///
  /// Example: `"claude-3.5-sonnet"` → `"anthropic"`
  static String resolve(String? model) {
    if (model == null || model.isEmpty) return 'unknown';
    final normalized = model.toLowerCase();
    if (normalized.startsWith('gemini')) return 'google';
    if (normalized.startsWith('gpt') ||
        normalized.startsWith('o1') ||
        normalized.startsWith('o3')) return 'openai';
    if (normalized.startsWith('claude')) return 'anthropic';
    if (normalized.startsWith('deepseek')) return 'deepseek';
    if (normalized.startsWith('moonshot')) return 'kimi';
    if (normalized.startsWith('llama') ||
        normalized.startsWith('qwen') ||
        normalized.startsWith('allam') ||
        normalized.startsWith('canopy') ||
        normalized.startsWith('groq') ||
        normalized.startsWith('meta')) return 'groq';
    if (normalized == 'local-model') return 'local';
    return 'unknown';
  }
}

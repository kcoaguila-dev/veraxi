class LocalChatDataSource {
  const LocalChatDataSource._();

  static LocalChatDataSource forModel() => const LocalChatDataSource._();

  Stream<Map<String, dynamic>> streamChat(String question, String modelName) {
    return Stream.error(
      UnsupportedError('Local models are not supported on Flutter Web.'),
    );
  }

  Future<String> generateText(String prompt, String modelName) {
    return Future.error(
      UnsupportedError('Local models are not supported on Flutter Web.'),
    );
  }

  Future<int?> countTokensTotal(List<String> texts, String modelName) async {
    return null;
  }
}

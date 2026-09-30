import 'package:shared_preferences/shared_preferences.dart';

class LocalModeStorage {
  static const _key = 'is_local_mode';

  Future<bool> isLocalMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> setLocalMode(bool isLocal) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, isLocal);
  }
}

import 'package:zxcvbnm/zxcvbnm.dart';
import 'package:zxcvbnm/languages/en.dart';
void main() {
  final z = Zxcvbnm(dictionaries: en.dictionaries);
  final result = z('password123');
  print('Score: ${result.score}');
}

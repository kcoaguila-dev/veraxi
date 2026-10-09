import 'package:zxcvbnm/zxcvbnm.dart';
void main() {
  final z = Zxcvbnm();
  final result = z('password123');
  print('Score: ${result.score}');
}

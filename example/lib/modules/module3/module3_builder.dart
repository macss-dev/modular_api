import 'package:modular_api/modular_api.dart';
import 'package:example/modules/module3/usecases/usecase_3.dart';
import 'package:example/modules/module3/usecases/usecase_4.dart';

void module3Builder(ModuleBuilder m) {
  m.usecase('lowercase', LowerCase.fromJson);
  m.usecase('multiply', MultiplyCase.fromJson);
}

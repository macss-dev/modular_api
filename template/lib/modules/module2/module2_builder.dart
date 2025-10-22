import 'package:modular_api/modular_api.dart';
import 'package:example/modules/module2/usecases/usecase_1.dart';
import 'package:example/modules/module2/usecases/usecase_2.dart';

void module2Builder(ModuleBuilder m) {
  m.usecase('sum', SumCase.fromJson);
  m.usecase('uppercase', UpperCase.fromJson);
}

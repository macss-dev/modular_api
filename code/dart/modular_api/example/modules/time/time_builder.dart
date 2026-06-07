import 'package:modular_api/modular_api.dart';

import 'usecases/current_time.dart';

void buildTimeModule(ModuleBuilder m) {
  m.usecase(
    'current-time',
    CurrentTime.fromJson,
    inputExample: CurrentTimeInput.example,
    outputExample: CurrentTimeOutput.example,
    method: 'GET',
  );
}

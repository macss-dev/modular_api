import 'package:modular_api/modular_api.dart';

import 'usecases/hello_world.dart';

void buildGreetingsModule(ModuleBuilder m) {
  m.usecase(
    'hello-world',
    HelloWorld.fromJson,
    inputExample: HelloWorldInput.example,
    outputExample: HelloWorldOutput.example,
  );
}

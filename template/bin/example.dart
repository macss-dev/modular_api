import 'dart:io';
import 'package:modular_api/modular_api.dart';
import 'package:example/modules/module1/hello_world.dart';
import 'package:example/modules/module2/module2_builder.dart';
import 'package:example/modules/module3/module3_builder.dart';

Future<void> main(List<String> args) async {
  final port = Env.getInt('PORT');

  final api = ModularApi(basePath: '/api');

  // Direct
  // POST by default
  // POST api/module1/hello-world
  api.module('module1', (m) {
    m.usecase('hello-world', HelloWorld.fromJson);
  });

  // Modular builder from external file
  api.module('module2', module2Builder);
  api.module('module3', module3Builder);

  // Middlewares
  api
  // .use(anotherMiddleware())
  .use(exampleCorsMiddleware());

  await api.serve(port: port,);

  /// OpenAPI docs URL
  /// You can access the docs at http://localhost:<port>/docs
  stdout.writeln('Docs on http://localhost:$port/docs');
}

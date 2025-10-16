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
  // POST api/example/example-case
  api.module('module1', (m) {
    m.usecase('hello-world', HelloWorld.fromJson);
  });

  // Modular builder from external file
  api.module('module2', module2Builder);
  api.module('module3', module3Builder);

  // Middlewares
  api
  // .use(anotherMiddleware())
  .use(cors());

  await api.serve(
    port: port,
    onBeforeServe: (root) async {
      await OpenApi.init(
        title: 'Example API',
        // Customize as needed
        // servers: [
        //   {
        //     'url': 'http://192.168.10.18:$port',
        //     'description': 'PROD'
        //   }
        // ],
      );
      root.get('/docs', OpenApi.docs);
      // No yet implemented, coming soon
      // root.get('/openapi.json', OpenApiSpecification.openapiJson);
    },
  );

  stdout.writeln('Docs on http://localhost:$port/docs');
}

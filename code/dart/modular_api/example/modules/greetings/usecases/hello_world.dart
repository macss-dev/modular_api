// ─── Input DTO ────────────────────────────────────────────────────────────────

import 'package:modular_api/modular_api.dart';

class HelloWorldInput extends Input {
  final String name;

  HelloWorldInput({required this.name});

  @override
  Map<String, dynamic> toJson() => {'name': name};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name',
            description: 'Name to greet', example: 'World'),
      ];

  /// Example instance for schema extraction and Swagger UI.
  static HelloWorldInput get example => HelloWorldInput(name: 'World');
}

// ─── Output DTO ───────────────────────────────────────────────────────────────

class HelloWorldOutput extends Output {
  final String message;

  HelloWorldOutput({required this.message});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'message': message};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('message',
            description: 'Greeting message', example: 'Hello, World!'),
      ];

  /// Example instance for schema extraction and Swagger UI.
  static HelloWorldOutput get example =>
      HelloWorldOutput(message: 'Hello, World!');
}

// ─── UseCase ──────────────────────────────────────────────────────────────────

class HelloWorld implements UseCase<HelloWorldInput, HelloWorldOutput> {
  @override
  final HelloWorldInput input;

  @override
  ModularLogger? logger;

  HelloWorld({required this.input});

  static HelloWorld fromJson(Map<String, dynamic> json) {
    return HelloWorld(
        input: HelloWorldInput(
      name: json['name'],
    ));
  }

  @override
  String? validate() {
    if (input.name.isEmpty) {
      return 'name is required';
    }
    return null;
  }

  @override
  Future<HelloWorldOutput> execute() async {
    logger?.info('Greeting user: ${input.name}');
    return HelloWorldOutput(message: 'Hello, ${input.name}!');
  }
}

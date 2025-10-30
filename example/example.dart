import 'package:modular_api/modular_api.dart';

Future<void> main(List<String> args) async {
  final api = ModularApi(basePath: '/api');

  // POST api/module1/hello-world
  api.module('module1', (m) {
    m.usecase('hello-world', HelloWorld.factory);
  });

  /// Get the port from the environment (.env) file.
  /// No default is provided; the PORT environment variable must be set.
  /// try final port = 1234 to use a fixed port.
  final port = Env.getInt('PORT');

  /// Start the server
  await api.serve(
    port: port,
  );

  print('Docs on http://localhost:$port/docs');
}

/// Input for HelloWorld: a single word used in the greeting.
class HelloInput implements Input {
  final String word;

  HelloInput({required this.word});

  factory HelloInput.fromJson(Map<String, dynamic> json) =>
      HelloInput(word: (json['word'] ?? '').toString());

  @override
  Map<String, dynamic> toJson() => {'word': word};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'word': {'type': 'string'},
        },
        'required': ['word'],
      };
}

/// Output for HelloWorld: the composed greeting.
class HelloOutput implements Output {
  final String output;

  HelloOutput({this.output = ''});

  factory HelloOutput.fromJson(Map<String, dynamic> json) =>
      HelloOutput(output: (json['output'] ?? '').toString());

  @override
  Map<String, dynamic> toJson() => {'output': output};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'output': {'type': 'string'},
        },
        'required': ['output'],
      };
}

/// HelloWorld use case: returns 'Hello, $word!'
class HelloWorld implements UseCase<HelloInput, HelloOutput> {
  @override
  final HelloInput input;

  @override
  late HelloOutput output;

  HelloWorld({required this.input}) {
    output = HelloOutput();
  }

  /// Factory method to create HelloWorld from JSON input.
  factory HelloWorld.factory(Map<String, dynamic> json) {
    final uc = HelloWorld(input: HelloInput.fromJson(json));
    return uc;
  }

  @override
  String? validate() {
    if (input.word.isEmpty) {
      return 'The word cannot be empty.';
    }
    return null;
  }

  @override
  Future<void> execute() async {
    // put your business logic here
    final world = input.word;

    output = HelloOutput(output: 'Hello, $world!');
  }

  @override
  Map<String, dynamic> toJson() => output.toJson();
}

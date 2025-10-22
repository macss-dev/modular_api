import 'package:modular_api/modular_api.dart';

/// Simple use case: converts a string to uppercase.
class UpperInput implements Input {
  final String text;

  UpperInput({required this.text});

  factory UpperInput.fromJson(Map<String, dynamic> json) {
    return UpperInput(text: (json['text'] ?? '').toString());
  }

  @override
  Map<String, dynamic> toJson() => {'text': text};

  @override
  Map<String, dynamic> toSchema() => {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
    'required': ['text'],
  };
}

class UpperOutput implements Output {
  final String result;

  UpperOutput({required this.result});

  factory UpperOutput.fromJson(Map<String, dynamic> json) {
    return UpperOutput(result: (json['result'] ?? '').toString());
  }

  @override
  Map<String, dynamic> toJson() => {'result': result};

  @override
  Map<String, dynamic> toSchema() => {
    'type': 'object',
    'properties': {
      'result': {'type': 'string'},
    },
    'required': ['result'],
  };
}

class UpperCase implements UseCase<UpperInput, UpperOutput> {
  @override
  final UpperInput input;

  @override
  late UpperOutput output;

  UpperCase({required this.input}) {
    output = UpperOutput(result: '');
  }

  factory UpperCase.fromJson(Map<String, dynamic> json) {
    final uc = UpperCase(input: UpperInput.fromJson(json));
    uc.output = UpperOutput(result: '');
    return uc;
  }

  @override
  String? validate() => null;

  @override
  Future<void> execute() async {
    output = UpperOutput(result: input.text.toUpperCase());
  }

  @override
  Map<String, dynamic> toJson() => output.toJson();
}

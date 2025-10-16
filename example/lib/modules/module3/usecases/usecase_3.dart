import 'package:modular_api/modular_api.dart';

/// Converts a string to lowercase.
class LowerInput implements Input {
  final String text;

  LowerInput({required this.text});

  factory LowerInput.fromJson(Map<String, dynamic> json) =>
      LowerInput(text: (json['text'] ?? '').toString());

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

class LowerOutput implements Output {
  final String result;

  LowerOutput({required this.result});

  factory LowerOutput.fromJson(Map<String, dynamic> json) =>
      LowerOutput(result: (json['result'] ?? '').toString());

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

class LowerCase implements UseCase<LowerInput, LowerOutput> {
  @override
  final LowerInput input;

  @override
  late LowerOutput output;

  LowerCase({required this.input}) {
    output = LowerOutput(result: '');
  }

  factory LowerCase.fromJson(Map<String, dynamic> json) {
    final uc = LowerCase(input: LowerInput.fromJson(json));
    uc.output = LowerOutput(result: '');
    return uc;
  }

  @override
  String? validate() => null;

  @override
  Future<void> execute() async {
    output = LowerOutput(result: input.text.toLowerCase());
  }

  @override
  Map<String, dynamic> toJson() => output.toJson();
}

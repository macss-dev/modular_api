import 'package:modular_api/modular_api.dart';

/// Simple use case: sums two numbers provided in the input and returns the result.
class SumInput implements Input {
  final num a;
  final num b;

  SumInput({required this.a, required this.b});

  factory SumInput.fromJson(Map<String, dynamic> json) {
    return SumInput(
      a: (json['a'] is num)
          ? json['a'] as num
          : num.tryParse((json['a'] ?? '0').toString()) ?? 0,
      b: (json['b'] is num)
          ? json['b'] as num
          : num.tryParse((json['b'] ?? '0').toString()) ?? 0,
    );
  }

  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b};

  @override
  Map<String, dynamic> toSchema() => {
    'type': 'object',
    'properties': {
      'a': {'type': 'number'},
      'b': {'type': 'number'},
    },
    'required': ['a', 'b'],
  };
}

class SumOutput implements Output {
  final num result;

  SumOutput({required this.result});

  factory SumOutput.fromJson(Map<String, dynamic> json) {
    return SumOutput(
      result: (json['result'] is num)
          ? json['result'] as num
          : num.tryParse((json['result'] ?? '0').toString()) ?? 0,
    );
  }

  @override
  Map<String, dynamic> toJson() => {'result': result};

  @override
  Map<String, dynamic> toSchema() => {
    'type': 'object',
    'properties': {
      'result': {'type': 'number'},
    },
    'required': ['result'],
  };
}

class SumCase implements UseCase<SumInput, SumOutput> {
  @override
  final SumInput input;

  @override
  late SumOutput output;

  SumCase({required this.input}) {
    output = SumOutput(result: 0);
  }

  factory SumCase.fromJson(Map<String, dynamic> json) {
    final uc = SumCase(input: SumInput.fromJson(json));
    uc.output = SumOutput(result: 0);
    return uc;
  }

  @override
  String? validate() {
    if (input.a < 0 || input.b < 0) {
      return 'Both numbers must be non-negative.';
    }
    return null;
  }

  @override
  Future<void> execute() async {
    output = SumOutput(result: input.a + input.b);
  }

  @override
  Map<String, dynamic> toJson() => output.toJson();
}

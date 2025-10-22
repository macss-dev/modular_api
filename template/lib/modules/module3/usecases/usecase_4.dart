import 'package:modular_api/modular_api.dart';

class MultiplyInput implements Input {
  final num x;
  final num y;

  MultiplyInput({required this.x, required this.y});

  factory MultiplyInput.fromJson(Map<String, dynamic> json) {
    return MultiplyInput(
      x: (json['x'] is num)
          ? json['x'] as num
          : num.tryParse((json['x'] ?? '0').toString()) ?? 0,
      y: (json['y'] is num)
          ? json['y'] as num
          : num.tryParse((json['y'] ?? '0').toString()) ?? 0,
    );
  }

  @override
  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  @override
  Map<String, dynamic> toSchema() => {
    'type': 'object',
    'properties': {
      'x': {'type': 'number'},
      'y': {'type': 'number'},
    },
    'required': ['x', 'y'],
  };
}

class MultiplyOutput implements Output {
  final num result;

  MultiplyOutput({required this.result});

  factory MultiplyOutput.fromJson(Map<String, dynamic> json) => MultiplyOutput(
    result: (json['result'] is num)
        ? json['result'] as num
        : num.tryParse((json['result'] ?? '0').toString()) ?? 0,
  );

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

class MultiplyCase implements UseCase<MultiplyInput, MultiplyOutput> {
  @override
  final MultiplyInput input;

  @override
  late MultiplyOutput output;

  MultiplyCase({required this.input}) {
    output = MultiplyOutput(result: 0);
  }

  factory MultiplyCase.fromJson(Map<String, dynamic> json) {
    final uc = MultiplyCase(input: MultiplyInput.fromJson(json));
    uc.output = MultiplyOutput(result: 0);
    return uc;
  }

  @override
  String? validate() => null;

  @override
  Future<void> execute() async {
    output = MultiplyOutput(result: input.x * input.y);
  }

  @override
  Map<String, dynamic> toJson() => output.toJson();
}

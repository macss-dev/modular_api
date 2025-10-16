abstract class UseCase<I extends Input, O extends Output> {
  /// DTO entrada
  /// Debe ser inicializado en el constructor
  /// si no se inicializa en el contructor no se puede inferir el esquema
  /// para OpenApi
  I get input;

  /// DTO salida
  /// Debe ser inicializado en el constructor
  /// si no se inicializa en el contructor no se puede inferir el esquema
  /// para OpenApi
  late O output;

  /// Read from DTO
  /// Deserialize the use case data from JSON
  factory UseCase.fromJson(Map<String, dynamic> json) {
    throw UnimplementedError('Must implement fromJson');
  }

  /// Validate the use case data
  String? validate();

  /// Execute the use case logic
  /// Bussiness logic should be implemented here
  Future<void> execute();

  /// Write to DTO
  /// Serialize the use case data to JSON
  Map<String, dynamic> toJson();
}

abstract class Input {
  /// El contrato no impone fromJson;
  factory Input.fromJson(Map<String, dynamic> json) {
    throw UnimplementedError('Must implement fromJson');
  }
  Map<String, dynamic> toJson();

  /// Schema
  /// Required for OpenApi specification
  Map<String, dynamic> toSchema();
}

abstract class Output {
  Map<String, dynamic> toJson();

  /// Schema
  /// Required for OpenApi specification
  Map<String, dynamic> toSchema();
}

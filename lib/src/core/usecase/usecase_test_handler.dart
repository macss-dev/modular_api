import 'usecase.dart';

/// Handler for unit testing UseCases
/// Returns a function that runs the unit test flow for a UseCase
Function(Map<String, dynamic>) useCaseTestHandler(
  UseCase Function(Map<String, dynamic>) fromJson,
) {
  return (Map<String, dynamic> inputJson) async {
    try {
      /// 1. Build the UseCase from JSON
      final useCase = fromJson(inputJson);

      /// 2. Valida los datos
      final validationError = useCase.validate();
      if (validationError != null) {
        return false;
      }

      /// 3. Execute the use case
      await useCase.execute();

      // 4. Convert the response to JSON (optional, for inspection)
      useCase.toJson();

      // 5. Everything went well
      return true;
    } catch (e) {
      // You can log the error if needed
      return false;
    }
  };
}

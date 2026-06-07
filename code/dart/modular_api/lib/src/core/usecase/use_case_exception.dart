/// Exception thrown during UseCase execution to control HTTP responses.
///
/// Allows UseCases to return specific HTTP status codes and structured error
/// responses instead of generic 500 errors.
///
/// Example:
/// ```dart
/// @override
/// Future<void> execute() async {
///   if (user == null) {
///     throw UseCaseException(
///       statusCode: 404,
///       message: 'User not found',
///       errorCode: 'USER_NOT_FOUND',
///     );
///   }
/// }
/// ```
class UseCaseException implements Exception {
  /// HTTP status code to return (e.g., 400, 404, 422, 500)
  final int statusCode;

  /// Human-readable error message
  final String message;

  /// Optional error code for client-side handling (e.g., 'INVALID_INPUT')
  final String? errorCode;

  /// Optional additional details (e.g., validation errors, stack info)
  final Map<String, dynamic>? details;

  UseCaseException({
    required this.statusCode,
    required this.message,
    this.errorCode,
    this.details,
  });

  /// Convert to JSON for HTTP response body
  Map<String, dynamic> toJson() {
    return {
      'error': errorCode ?? 'error',
      'message': message,
      if (details != null) 'details': details,
    };
  }

  @override
  String toString() =>
      'UseCaseException($statusCode): $message${errorCode != null ? ' [$errorCode]' : ''}';
}

import 'package:modular_api/src/core/health/health_check.dart';

final class GraphqlRuntimeState {
  GraphqlRuntimeState.disabled() : _output = 'disabled';

  String _output;

  String get output => _output;

  void markDisabled() {
    _output = 'disabled';
  }

  void markReady() {
    _output = 'ready';
  }
}

final class GraphqlRuntimeHealthCheck extends HealthCheck {
  GraphqlRuntimeHealthCheck(this._state);

  final GraphqlRuntimeState _state;

  @override
  String get name => 'graphql';

  @override
  Future<HealthCheckResult> check() async {
    return HealthCheckResult(
      status: HealthStatus.pass,
      output: _state.output,
    );
  }
}
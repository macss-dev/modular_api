import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  group('Plugin host lifecycle', () {
    test('plugin setup does not run during registration', () {
      final plugin = RecordingPlugin(id: 'acme.lifecycle');
      final api = ModularApi(basePath: '/api', title: 'Lifecycle API', version: '1.2.3');

      api.plugin(plugin);

      expect(plugin.setupCalls, 0);
      expect(plugin.observedMetadata, isNull);
    });

    test('plugin setup runs during serve and receives host metadata', () async {
      final plugin = RecordingPlugin(id: 'acme.lifecycle');
      final api = ModularApi(basePath: '/api', title: 'Lifecycle API', version: '1.2.3')
        ..plugin(plugin);

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      expect(plugin.setupCalls, 1);
      expect(plugin.observedMetadata?.basePath, '/api');
      expect(plugin.observedMetadata?.title, 'Lifecycle API');
      expect(plugin.observedMetadata?.version, '1.2.3');
      expect(plugin.observedMetadata?.hostApiVersion, hostApiVersion);
    });

    test('duplicate plugin ids fail startup', () async {
      final api = ModularApi(basePath: '/api')
        ..plugin(RecordingPlugin(id: 'acme.duplicate'))
        ..plugin(RecordingPlugin(id: 'acme.duplicate'));

      expect(
        () => api.serve(port: 0),
        throwsA(
          isA<PluginHostError>().having((error) => error.code, 'code', 'PLUGIN_ID_CONFLICT'),
        ),
      );
    });

    test('dependency order controls setup order and registration order breaks ties', () async {
      final events = <String>[];
      final api = ModularApi(basePath: '/api')
        ..plugin(DependentPlugin(id: 'acme.child-b', dependencyId: 'acme.root', events: events))
        ..plugin(DependentPlugin(id: 'acme.child-a', dependencyId: 'acme.root', events: events))
        ..plugin(RecordingPlugin(id: 'acme.root', events: events));

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      expect(events, ['setup:acme.root', 'setup:acme.child-b', 'setup:acme.child-a']);
    });

    test('plugin validation runs after setup and aborts startup', () async {
      final plugin = InvalidatingPlugin(id: 'acme.invalid');
      final api = ModularApi(basePath: '/api')..plugin(plugin);

      try {
        final server = await api.serve(port: 0);
        await server.close(force: true);
        fail('Expected startup to fail during validate phase');
      } on PluginHostError catch (error) {
        expect(error.code, 'PLUGIN_VALIDATION_FAILED');
      }
      expect(plugin.setupCalls, 1);
      expect(plugin.validateCalls, 1);
    });

    test('shutdown runs in reverse setup order', () async {
      final events = <String>[];
      final api = ModularApi(basePath: '/api')
        ..plugin(ShutdownPlugin(id: 'acme.child', events: events, dependencyId: 'acme.root'))
        ..plugin(ShutdownPlugin(id: 'acme.root', events: events));

      final server = await api.serve(port: 0);
      await server.close(force: true);

      expect(events, [
        'setup:acme.root',
        'setup:acme.child',
        'shutdown:acme.child',
        'shutdown:acme.root',
      ]);
    });

    test('shutdown runs for already setup plugins when validation aborts startup', () async {
      final events = <String>[];
      final api = ModularApi(basePath: '/api')
        ..plugin(ShutdownPlugin(id: 'acme.root', events: events))
        ..plugin(FailingShutdownPlugin(id: 'acme.invalid', events: events));

      try {
        final server = await api.serve(port: 0);
        await server.close(force: true);
        fail('Expected startup to fail during validate phase');
      } on PluginHostError catch (error) {
        expect(error.code, 'PLUGIN_VALIDATION_FAILED');
      }

      expect(events, [
        'setup:acme.root',
        'setup:acme.invalid',
        'shutdown:acme.invalid',
        'shutdown:acme.root',
      ]);
    });

    test('late host registration is rejected after startup freeze', () async {
      final plugin = LateRegistrationPlugin(id: 'acme.late');
      final api = ModularApi(basePath: '/api')..plugin(plugin);

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      expect(
        plugin.registerLateRoute,
        throwsA(
          isA<PluginHostError>().having((error) => error.code, 'code', 'PLUGIN_VALIDATION_FAILED'),
        ),
      );
    });
  });
}

class RecordingPlugin implements Plugin {
  int setupCalls = 0;
  HostMetadata? observedMetadata;
  final List<String>? events;
  final PluginManifest _manifest;

  @override
  PluginManifest get manifest => _manifest;

  RecordingPlugin({required String id, this.events, PluginManifest? manifest})
      : _manifest = manifest ?? PluginManifest(
          id: id,
          displayName: 'Recording Plugin',
          version: '0.1.0',
          hostApiVersion: '>=0.1.0 <0.2.0',
        );

  @override
  void setup(PluginHost host) {
    setupCalls += 1;
    observedMetadata = host.metadata();
    events?.add('setup:${manifest.id}');
  }
}

class DependentPlugin extends RecordingPlugin {
  DependentPlugin({required super.id, required String dependencyId, required super.events})
      : super(
          manifest: PluginManifest(
          id: id,
          displayName: 'Recording Plugin',
          version: '0.1.0',
          hostApiVersion: '>=0.1.0 <0.2.0',
          requires: [PluginRequirement(type: 'plugin', id: dependencyId)],
        ),
        );
}

class InvalidatingPlugin extends RecordingPlugin implements ValidatingPlugin {
  int validateCalls = 0;

  InvalidatingPlugin({required super.id});

  @override
  List<PluginValidationResult> validate(PluginHost host) {
    validateCalls += 1;
    return [
      PluginValidationResult(
        code: 'PLUGIN_VALIDATION_FAILED',
        message: 'invalid plugin',
        pluginId: manifest.id,
      ),
    ];
  }
}

class ShutdownPlugin extends RecordingPlugin implements ShutdownAwarePlugin {
  ShutdownPlugin({required super.id, required super.events, String? dependencyId})
      : super(
          manifest: PluginManifest(
          id: id,
          displayName: 'Recording Plugin',
          version: '0.1.0',
          hostApiVersion: '>=0.1.0 <0.2.0',
          requires: dependencyId == null
              ? const []
              : [PluginRequirement(type: 'plugin', id: dependencyId)],
        ),
        );

  @override
  Future<void> shutdown() async {
    events?.add('shutdown:${manifest.id}');
  }
}

class FailingShutdownPlugin extends ShutdownPlugin implements ValidatingPlugin {
  FailingShutdownPlugin({required super.id, required super.events});

  @override
  List<PluginValidationResult> validate(PluginHost host) {
    return [
      PluginValidationResult(
        code: 'PLUGIN_VALIDATION_FAILED',
        message: 'invalid plugin',
        pluginId: manifest.id,
      ),
    ];
  }
}

class LateRegistrationPlugin extends RecordingPlugin {
  PluginHost? _host;

  LateRegistrationPlugin({required super.id});

  @override
  void setup(PluginHost host) {
    super.setup(host);
    _host = host;
  }

  void registerLateRoute() {
    _host!.registerRoute(
      PluginRoute(
        id: 'late-route',
        method: 'GET',
        path: '/late',
        visibility: 'custom',
        handler: (_) => Response.ok('ok'),
      ),
    );
  }
}
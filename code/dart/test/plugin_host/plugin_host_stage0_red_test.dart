import 'dart:io';

import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  group('Stage 0 red baseline - plugin host', () {
    test('ModularApi should expose plugin registration and public plugin types', () {
      final api = ModularApi(basePath: '/api');

      final ProbePlugin plugin = ProbePlugin();

      expect(api.plugin(plugin), same(api));
      expect(plugin.manifest.id, 'acme.echo');
    });

    test('plugin routes should resolve under the shared basePath', () async {
      final api = ModularApi(basePath: '/api')..plugin(ProbePlugin());

      final server = await api.serve(port: 0);
      addTearDown(server.close);

      final client = HttpClient();
      final prefixed = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/api/plugin-probe'));
      final prefixedResponse = await prefixed.close();
      expect(prefixedResponse.statusCode, 200);

      final root = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/plugin-probe'));
      final rootResponse = await root.close();
      expect(rootResponse.statusCode, 404);
    });
  });
}

class ProbePlugin implements Plugin {
  @override
  final PluginManifest manifest = PluginManifest(
    id: 'acme.echo',
    displayName: 'Echo Probe',
    version: '0.1.0',
    hostApiVersion: '>=0.1.0 <0.2.0',
  );

  @override
  void setup(PluginHost host) {
    host.registerRoute(
      PluginRoute(
        id: 'probe-route',
        method: 'GET',
        path: '/plugin-probe',
        visibility: 'custom',
        handler: (_) => Response.ok('ok'),
      ),
    );
  }
}
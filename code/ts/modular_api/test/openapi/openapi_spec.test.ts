import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import request from 'supertest';
import type { Server } from 'http';
import { ModularApi, Input, Output, UseCase } from '../../src';
import { apiRegistry } from '../../src/core/registry';
import { jsonToYaml } from '../../src/openapi/openapi';

// ── Minimal UseCase for integration tests ────────────────────

class PingInput extends Input {
  toJson() {
    return {};
  }
  toSchema() {
    return { type: 'object', properties: {} };
  }
}

class PingOutput extends Output {
  get statusCode() {
    return 200;
  }
  toJson() {
    return { pong: true };
  }
  toSchema() {
    return {
      type: 'object',
      properties: { pong: { type: 'boolean' } },
    };
  }
}

class PingUseCase extends UseCase<PingInput, PingOutput> {
  readonly input: PingInput;

  constructor(input: PingInput) {
    super();
    this.input = input;
  }

  static fromJson(_json: Record<string, unknown>) {
    return new PingUseCase(new PingInput());
  }

  validate() {
    return null;
  }

  async execute() {
    return new PingOutput();
  }
}

// ── jsonToYaml unit tests ────────────────────────────────────

describe('jsonToYaml', () => {
  it('converts empty object to {}', () => {
    expect(jsonToYaml({}).trim()).toBe('{}');
  });

  it('converts empty array to []', () => {
    expect(jsonToYaml([]).trim()).toBe('[]');
  });

  it('converts scalar values', () => {
    const result = jsonToYaml({ key: 'value', num: 42 });
    expect(result).toContain('key: value');
    expect(result).toContain('num: 42');
  });

  it('converts boolean and null values', () => {
    const result = jsonToYaml({ flag: true, off: false, nothing: null });
    expect(result).toContain('flag: true');
    // 'off' is a YAML reserved word so the key is quoted
    expect(result).toContain("'off': false");
    expect(result).toContain('nothing: null');
  });

  it('converts nested objects', () => {
    const result = jsonToYaml({
      info: { title: 'Test', version: '1.0.0' },
    });
    expect(result).toContain('info:');
    expect(result).toContain('  title: Test');
    expect(result).toContain('  version: 1.0.0');
  });

  it('converts lists', () => {
    const result = jsonToYaml({ tags: ['users', 'admin'] });
    expect(result).toContain('tags:');
    expect(result).toContain('- users');
    expect(result).toContain('- admin');
  });

  it('quotes strings that need quoting', () => {
    const result = jsonToYaml({
      reserved: 'true',
      special: 'value: with colon',
    });
    expect(result).toContain("'true'");
    expect(result).toContain("'value: with colon'");
  });

  it('converts a full OpenAPI-like structure', () => {
    const spec = {
      openapi: '3.0.0',
      info: { title: 'Test API', version: '1.0.0' },
      paths: {
        '/api/test/ping': {
          post: {
            summary: 'Ping endpoint',
            responses: { '200': { description: 'OK' } },
          },
        },
      },
    };

    const yaml = jsonToYaml(spec);
    expect(yaml).toContain('openapi: 3.0.0');
    expect(yaml).toContain('info:');
    expect(yaml).toContain('  title: Test API');
    expect(yaml).toContain('paths:');
    expect(yaml).toContain('/api/test/ping:');
  });
});

// ── Integration tests ────────────────────────────────────────

describe('OpenAPI spec endpoints (TypeScript)', () => {
  let server: Server;

  afterEach(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
    apiRegistry.clear();
  });

  async function startServer() {
    const api = new ModularApi({
      basePath: '/api',
      title: 'Test API',
      version: '1.0.0',
    });
    api.module('test', (m) => {
      m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
    });
    server = await api.serve({ port: 0 });
    return server;
  }

  describe('GET /api/openapi.json', () => {
    beforeEach(async () => {
      await startServer();
    });

    it('returns 200 with application/json content-type', async () => {
      const res = await request(server).get('/api/openapi.json');
      expect(res.status).toBe(200);
      expect(res.headers['content-type']).toContain('application/json');
    });

    it('returns valid OpenAPI spec with correct structure', async () => {
      const res = await request(server).get('/api/openapi.json');
      const spec = res.body;
      expect(spec.openapi).toBe('3.0.0');
      expect(spec.info).toBeDefined();
      expect(spec.info.title).toBe('Test API');
      expect(spec.paths).toBeDefined();
    });

    it('contains registered use case path', async () => {
      const res = await request(server).get('/api/openapi.json');
      const spec = res.body;
      expect(spec.paths).toHaveProperty('/api/test/ping');
    });

    it('spec has servers entry', async () => {
      const res = await request(server).get('/api/openapi.json');
      const spec = res.body;
      expect(Array.isArray(spec.servers)).toBe(true);
      expect(spec.servers.length).toBeGreaterThan(0);
    });
  });

  describe('GET /api/openapi.yaml', () => {
    beforeEach(async () => {
      await startServer();
    });

    it('returns 200 with application/x-yaml content-type', async () => {
      const res = await request(server).get('/api/openapi.yaml');
      expect(res.status).toBe(200);
      expect(res.headers['content-type']).toContain('application/x-yaml');
    });

    it('returns YAML with openapi version', async () => {
      const res = await request(server).get('/api/openapi.yaml');
      expect(res.text).toContain('openapi: 3.0.0');
    });

    it('YAML contains registered use case path', async () => {
      const res = await request(server).get('/api/openapi.yaml');
      expect(res.text).toContain('/api/test/ping');
    });

    it('YAML contains info section', async () => {
      const res = await request(server).get('/api/openapi.yaml');
      expect(res.text).toContain('info:');
      expect(res.text).toContain('title: Test API');
    });

    it('YAML is not JSON (does not start with {)', async () => {
      const res = await request(server).get('/api/openapi.yaml');
      expect(res.text.trimStart().startsWith('{')).toBe(false);
    });
  });

  describe('JSON and YAML consistency', () => {
    it('both endpoints represent the same spec', async () => {
      const api = new ModularApi({
        basePath: '/api',
        title: 'Consistency Test',
        version: '2.0.0',
      });
      api.module('test', (m) => {
        m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
      });
      server = await api.serve({ port: 0 });

      const jsonRes = await request(server).get('/api/openapi.json');
      const yamlRes = await request(server).get('/api/openapi.yaml');

      expect(jsonRes.status).toBe(200);
      expect(yamlRes.status).toBe(200);

      // JSON should be parseable
      expect(jsonRes.body.openapi).toBe('3.0.0');

      // YAML should contain the same title
      expect(yamlRes.text).toContain('title: Consistency Test');
    });
  });

  // ── Custom servers ──────────────────────────────────────────

  describe('Custom servers in OpenAPI spec', () => {
    it('uses localhost default when servers is not provided', async () => {
      const api = new ModularApi({
        basePath: '/api',
        title: 'Default Servers',
        version: '1.0.0',
      });
      api.module('test', (m) => {
        m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
      });
      server = await api.serve({ port: 0 });

      const res = await request(server).get('/api/openapi.json');
      expect(res.body.servers).toHaveLength(1);
      expect(res.body.servers[0].url).toContain('localhost');
    });

    it('propagates custom servers to OpenAPI spec', async () => {
      const api = new ModularApi({
        basePath: '/api',
        title: 'Custom Servers',
        version: '1.0.0',
        servers: [
          { url: 'https://miapi.example.com', description: 'Production' },
        ],
      });
      api.module('test', (m) => {
        m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
      });
      server = await api.serve({ port: 0 });

      const res = await request(server).get('/api/openapi.json');
      expect(res.body.servers).toHaveLength(1);
      expect(res.body.servers[0].url).toBe('https://miapi.example.com');
      expect(res.body.servers[0].description).toBe('Production');
    });

    it('supports multiple servers in the OpenAPI spec', async () => {
      const api = new ModularApi({
        basePath: '/api',
        title: 'Multi Servers',
        version: '1.0.0',
        servers: [
          { url: 'https://prod.example.com', description: 'Production' },
          { url: 'http://192.168.5.82:8080', description: 'LAN' },
        ],
      });
      api.module('test', (m) => {
        m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
      });
      server = await api.serve({ port: 0 });

      const res = await request(server).get('/api/openapi.json');
      expect(res.body.servers).toHaveLength(2);
      expect(res.body.servers[0].url).toBe('https://prod.example.com');
      expect(res.body.servers[1].url).toBe('http://192.168.5.82:8080');
    });

    it('preserves server descriptions in spec output', async () => {
      const api = new ModularApi({
        basePath: '/api',
        title: 'Described Servers',
        version: '1.0.0',
        servers: [
          { url: 'https://api.example.com', description: 'Main API' },
        ],
      });
      api.module('test', (m) => {
        m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
      });
      server = await api.serve({ port: 0 });

      const res = await request(server).get('/api/openapi.json');
      expect(res.body.servers[0].description).toBe('Main API');
    });
  });
});

import { describe, it, expect, beforeEach } from 'vitest';
import { LogLevel, RequestScopedLogger } from '../../src/core/logger/logger';

describe('LogLevel', () => {
  it('has 8 values', () => {
    const values = Object.values(LogLevel).filter((v) => typeof v === 'number');
    expect(values.length).toBe(8);
  });

  it('values map to RFC 5424 numeric severity', () => {
    expect(LogLevel.emergency).toBe(0);
    expect(LogLevel.alert).toBe(1);
    expect(LogLevel.critical).toBe(2);
    expect(LogLevel.error).toBe(3);
    expect(LogLevel.warning).toBe(4);
    expect(LogLevel.notice).toBe(5);
    expect(LogLevel.info).toBe(6);
    expect(LogLevel.debug).toBe(7);
  });
});

describe('RequestScopedLogger filtering', () => {
  let lines: string[];
  const capture = (line: string) => lines.push(line);

  beforeEach(() => {
    lines = [];
  });

  it('logLevel=warning emits emergency, alert, critical, error, warning', () => {
    const logger = new RequestScopedLogger('t', LogLevel.warning, 'svc', capture);
    logger.emergency('e0');
    logger.alert('a1');
    logger.critical('c2');
    logger.error('e3');
    logger.warning('w4');
    expect(lines.length).toBe(5);
  });

  it('logLevel=warning suppresses notice, info, debug', () => {
    const logger = new RequestScopedLogger('t', LogLevel.warning, 'svc', capture);
    logger.notice('n5');
    logger.info('i6');
    logger.debug('d7');
    expect(lines.length).toBe(0);
  });

  it('logLevel=debug emits all 8 levels', () => {
    const logger = new RequestScopedLogger('t', LogLevel.debug, 'svc', capture);
    logger.emergency('e');
    logger.alert('a');
    logger.critical('c');
    logger.error('e');
    logger.warning('w');
    logger.notice('n');
    logger.info('i');
    logger.debug('d');
    expect(lines.length).toBe(8);
  });

  it('logLevel=emergency emits only emergency', () => {
    const logger = new RequestScopedLogger('t', LogLevel.emergency, 'svc', capture);
    logger.emergency('m');
    logger.alert('m');
    logger.critical('m');
    logger.error('m');
    logger.warning('m');
    logger.notice('m');
    logger.info('m');
    logger.debug('m');
    expect(lines.length).toBe(1);
  });
});

describe('RequestScopedLogger JSON format', () => {
  let lines: string[];
  const capture = (line: string) => lines.push(line);

  beforeEach(() => {
    lines = [];
  });

  it('each log is a single valid JSON line', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    logger.info('hello');
    expect(lines.length).toBe(1);
    const json = JSON.parse(lines[0]);
    expect(typeof json).toBe('object');
  });

  it('contains all mandatory fields: ts, level, severity, msg, service', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    logger.info('test');
    const json = JSON.parse(lines[0]);
    expect(json).toHaveProperty('ts');
    expect(json).toHaveProperty('level');
    expect(json).toHaveProperty('severity');
    expect(json).toHaveProperty('msg');
    expect(json).toHaveProperty('service');
  });

  it('ts is a float Unix timestamp', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    const before = Date.now() / 1000;
    logger.info('timing');
    const after = Date.now() / 1000;
    const json = JSON.parse(lines[0]);
    expect(json.ts).toBeGreaterThanOrEqual(before);
    expect(json.ts).toBeLessThanOrEqual(after + 0.01);
  });

  it('level is lowercase string', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    logger.warning('w');
    const json = JSON.parse(lines[0]);
    expect(json.level).toBe('warning');
  });

  it('severity matches the numeric RFC 5424 value', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    logger.error('e');
    expect(JSON.parse(lines[0]).severity).toBe(3);
  });

  it('msg contains the provided message', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    logger.info('my descriptive message');
    expect(JSON.parse(lines[0]).msg).toBe('my descriptive message');
  });

  it('service contains the configured service name', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'payment-svc', capture);
    logger.info('svc test');
    expect(JSON.parse(lines[0]).service).toBe('payment-svc');
  });

  it('trace_id is included in every log', () => {
    const logger = new RequestScopedLogger('my-trace-123', LogLevel.debug, 'svc', capture);
    logger.info('trace test');
    expect(JSON.parse(lines[0]).trace_id).toBe('my-trace-123');
  });

  it('fields are included when provided', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    logger.info('with fields', { userId: 'u123', active: true });
    const json = JSON.parse(lines[0]);
    expect(json.fields).toEqual({ userId: 'u123', active: true });
  });

  it('fields key is absent when not provided', () => {
    const logger = new RequestScopedLogger('trace', LogLevel.debug, 'svc', capture);
    logger.info('no fields');
    expect(JSON.parse(lines[0])).not.toHaveProperty('fields');
  });

  it('each level produces correct level and severity pair', () => {
    const levels: [string, number, (l: RequestScopedLogger) => void][] = [
      ['emergency', 0, (l) => l.emergency('m')],
      ['alert', 1, (l) => l.alert('m')],
      ['critical', 2, (l) => l.critical('m')],
      ['error', 3, (l) => l.error('m')],
      ['warning', 4, (l) => l.warning('m')],
      ['notice', 5, (l) => l.notice('m')],
      ['info', 6, (l) => l.info('m')],
      ['debug', 7, (l) => l.debug('m')],
    ];

    for (const [name, severity, call] of levels) {
      const buf: string[] = [];
      const logger = new RequestScopedLogger('x', LogLevel.debug, 'svc', (l) => buf.push(l));
      call(logger);
      const json = JSON.parse(buf[0]);
      expect(json.level).toBe(name);
      expect(json.severity).toBe(severity);
    }
  });
});

describe('RequestScopedLogger.logRequest / logResponse', () => {
  let lines: string[];
  const capture = (line: string) => lines.push(line);

  beforeEach(() => {
    lines = [];
  });

  it('logRequest emits request fields: method, route', () => {
    const logger = new RequestScopedLogger('trace-req', LogLevel.debug, 'svc', capture);
    logger.logRequest({ method: 'POST', route: '/api/users/create' });
    const json = JSON.parse(lines[0]);
    expect(json.msg).toBe('request received');
    expect(json.level).toBe('info');
    expect(json.method).toBe('POST');
    expect(json.route).toBe('/api/users/create');
    expect(json.trace_id).toBe('trace-req');
  });

  it('logResponse emits response fields: method, route, status, duration_ms', () => {
    const logger = new RequestScopedLogger('trace-res', LogLevel.debug, 'svc', capture);
    logger.logResponse({
      method: 'POST',
      route: '/api/users/create',
      statusCode: 200,
      durationMs: 45.3,
    });
    const json = JSON.parse(lines[0]);
    expect(json.msg).toBe('request completed');
    expect(json.method).toBe('POST');
    expect(json.route).toBe('/api/users/create');
    expect(json.status).toBe(200);
    expect(json.duration_ms).toBe(45.3);
    expect(json.trace_id).toBe('trace-res');
  });

  it('logResponse level is info for 2xx', () => {
    const logger = new RequestScopedLogger('t', LogLevel.debug, 's', capture);
    logger.logResponse({ method: 'GET', route: '/r', statusCode: 200, durationMs: 1 });
    const json = JSON.parse(lines[0]);
    expect(json.level).toBe('info');
    expect(json.severity).toBe(6);
  });

  it('logResponse level is warning for 4xx', () => {
    const logger = new RequestScopedLogger('t', LogLevel.debug, 's', capture);
    logger.logResponse({ method: 'POST', route: '/r', statusCode: 404, durationMs: 2 });
    expect(JSON.parse(lines[0]).level).toBe('warning');
  });

  it('logResponse level is error for 5xx', () => {
    const logger = new RequestScopedLogger('t', LogLevel.debug, 's', capture);
    logger.logResponse({ method: 'POST', route: '/r', statusCode: 500, durationMs: 3 });
    expect(JSON.parse(lines[0]).level).toBe('error');
  });

  it('logResponse level is notice for 1xx', () => {
    const logger = new RequestScopedLogger('t', LogLevel.debug, 's', capture);
    logger.logResponse({ method: 'GET', route: '/r', statusCode: 100, durationMs: 0.5 });
    expect(JSON.parse(lines[0]).level).toBe('notice');
  });

  it('logResponse level is info for 3xx', () => {
    const logger = new RequestScopedLogger('t', LogLevel.debug, 's', capture);
    logger.logResponse({ method: 'GET', route: '/r', statusCode: 301, durationMs: 0.8 });
    expect(JSON.parse(lines[0]).level).toBe('info');
  });

  it('logRequest is suppressed when logLevel < info', () => {
    const logger = new RequestScopedLogger('t', LogLevel.warning, 's', capture);
    logger.logRequest({ method: 'GET', route: '/r' });
    expect(lines.length).toBe(0);
  });

  it('logResponse with 5xx emits even when logLevel=error', () => {
    const logger = new RequestScopedLogger('t', LogLevel.error, 's', capture);
    logger.logResponse({ method: 'POST', route: '/r', statusCode: 503, durationMs: 100 });
    expect(JSON.parse(lines[0]).level).toBe('error');
  });
});

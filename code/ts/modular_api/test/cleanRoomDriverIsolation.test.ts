import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';
import { GraphqlMetadataParser } from '../src';

type PackageJson = {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
  peerDependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
};

function dependencyNames(packageJson: PackageJson): string[] {
  return [
    ...Object.keys(packageJson.dependencies ?? {}),
    ...Object.keys(packageJson.devDependencies ?? {}),
    ...Object.keys(packageJson.peerDependencies ?? {}),
    ...Object.keys(packageJson.optionalDependencies ?? {}),
  ];
}

describe('clean-room driver isolation', () => {
  it('keeps concrete database drivers out of the core package manifest', () => {
    const packageJson = JSON.parse(readFileSync('package.json', 'utf8')) as PackageJson;
    const names = dependencyNames(packageJson);

    expect(names).not.toContain('mssql');
    expect(names).not.toContain('pg');
  });

  it('keeps core imports green without concrete database drivers', () => {
    expect(new GraphqlMetadataParser()).toBeInstanceOf(GraphqlMetadataParser);
  });
});
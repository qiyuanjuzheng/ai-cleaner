import Ajv2020 from 'ajv/dist/2020';
import addFormats from 'ajv-formats';
import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = path.resolve(__dirname, '../../../..');
const schemaPath = path.join(repoRoot, 'protocol/rpc-v1.schema.json');
const fixturesPath = path.join(repoRoot, 'protocol/fixtures/rpc-v1-samples.json');
const rustSidecarPath = path.join(repoRoot, 'apps/desktop/src-tauri/src/sidecar.rs');

describe('RPC v1 schema and cross-language contract conformance', () => {
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const fixtures = JSON.parse(fs.readFileSync(fixturesPath, 'utf8'));

  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  it('validates all shared request fixtures against rpc-v1.schema.json', () => {
    expect(fixtures.requests.length).toBeGreaterThan(0);
    for (const req of fixtures.requests) {
      const ok = validate(req);
      expect(ok, JSON.stringify(validate.errors)).toBe(true);
    }
  });

  it('validates all shared notification fixtures against rpc-v1.schema.json', () => {
    expect(fixtures.notifications.length).toBeGreaterThan(0);
    for (const note of fixtures.notifications) {
      const ok = validate(note);
      expect(ok, JSON.stringify(validate.errors)).toBe(true);
    }
  });

  it('validates all shared error response fixtures against rpc-v1.schema.json', () => {
    expect(fixtures.errors.length).toBeGreaterThan(0);
    for (const errResp of fixtures.errors) {
      const ok = validate(errResp);
      expect(ok, JSON.stringify(validate.errors)).toBe(true);
    }
  });

  it('keeps Rust host ALLOWED_METHODS in exact sync with rpc-v1.schema.json methods', () => {
    const schemaMethods: string[] = [...schema.$defs.method.enum].sort();
    const rustSource = fs.readFileSync(rustSidecarPath, 'utf8');
    const blockMatch = rustSource.match(/pub const ALLOWED_METHODS:\s*&\[&str\]\s*=\s*&\[([\s\S]*?)\];/);
    expect(blockMatch).not.toBeNull();
    const rustMethods = Array.from(blockMatch![1].matchAll(/"([^"]+)"/g), (m) => m[1]).sort();
    expect(rustMethods).toEqual(schemaMethods);
  });
});

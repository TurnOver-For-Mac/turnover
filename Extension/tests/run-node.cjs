// Optional runner only: the same plain-JS suite runs in system JavaScriptCore.
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const assert = require('node:assert/strict');
const { runPassiveExtensionTests } = require('./passive-tests.js');
const source = readFileSync(join(__dirname, '..', 'content.js'), 'utf8');
const manifest = JSON.parse(readFileSync(join(__dirname, '..', 'manifest.json'), 'utf8'));
assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.version, '1.3');
assert.deepEqual(manifest.permissions || [], []);
assert.equal(manifest.background, undefined);
assert.deepEqual(manifest.content_scripts[0].js, ['content.js']);
const results = runPassiveExtensionTests(source);
for (const r of results) console.log((r.passed ? 'PASS ' : 'FAIL ') + r.name + (r.passed ? '' : '\n' + r.error));
const failures = results.filter(r => !r.passed).length;
console.log(results.length + ' synthetic groups, ' + failures + ' failed; manifest checks passed');
process.exitCode = failures ? 1 : 0;

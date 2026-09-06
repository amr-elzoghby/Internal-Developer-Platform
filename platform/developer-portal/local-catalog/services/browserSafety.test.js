const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

test('catalog text escapes quotes before use in HTML attributes', () => {
  const context = vm.createContext({
    localStorage: { getItem: () => null },
    document: { addEventListener: () => {} }
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../public/js/app.js'), 'utf8'), context);
  const escape = vm.runInContext('esc', context);
  assert.equal(escape('api" onmouseover="alert(1)'), 'api&quot; onmouseover=&quot;alert(1)');
  assert.equal(escape("<&'\">"), '&lt;&amp;&#39;&quot;&gt;');
  assert.equal(escape(null), '');
  assert.equal(escape(0), '0');
});

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { listServices } = require('./catalogService');
function write(root, name, text) {
  const target = path.join(root, name); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, text);
}
test('nested monorepo catalog maps only declared same-tenant canonical claims', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'idp-catalog-'));
  try {
    for (const team of ['identity-platform', 'data-platform']) {
      write(root, `apps/${team}/api/catalog-info.yaml`, `apiVersion: backstage.io/v1alpha1\nkind: Component\nmetadata:\n  name: api\n  description: 'a quoted: description'\nspec:\n  owner: ${team}\n  dependsOn:\n    - resource:default/db\n`);
    }
    write(root, 'infrastructure/crossplane/claims/identity-platform/db.yaml', 'apiVersion: idp.io/v1alpha1\nkind: PostgresSQLInstance\nmetadata:\n  name: db\n  namespace: identity-platform\n');
    write(root, 'infrastructure/crossplane/claims/identity-platform/unrelated.yaml', 'apiVersion: idp.io/v1alpha1\nkind: ObjectBucket\nmetadata:\n  name: unrelated\n  namespace: identity-platform\n');
    const services = listServices(root);
    assert.equal(services.length, 2);
    const identity = services.find(service => service.id === 'identity-platform/api');
    assert.equal(identity.argoApplication, 'identity-platform-api');
    assert.deepEqual(identity.infraFiles, ['infrastructure/crossplane/claims/identity-platform/db.yaml']);
    assert.equal(identity.claims.postgres, true);
    assert.equal(identity.claims.s3, false);
    assert.equal(services.find(service => service.id === 'data-platform/api').claims.postgres, false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
test('owner mismatch fails instead of inventing team metadata', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'idp-catalog-'));
  try {
    write(root, 'apps/identity-platform/api/catalog-info.yaml', 'kind: Component\nmetadata: {name: api}\nspec: {owner: data-platform}\n');
    assert.throws(() => listServices(root), /ownership/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
test('catalog discovers nested Golden Path claims without following symlinks', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'idp-catalog-'));
  try {
    write(root, 'apps/identity-platform/api/catalog-info.yaml', 'kind: Component\nmetadata: {name: api}\nspec:\n  owner: identity-platform\n  dependsOn: ["resource:default/db", "resource:default/outside"]\n');
    write(root, 'infrastructure/crossplane/claims/identity-platform/db/claim.yaml', 'apiVersion: idp.io/v1alpha1\nkind: PostgresSQLInstance\nmetadata: {name: db, namespace: identity-platform}\n');
    write(root, 'outside/claim.yaml', 'kind: ObjectBucket\nmetadata: {name: outside, namespace: identity-platform}\n');
    fs.symlinkSync(path.join(root, 'outside'), path.join(root, 'infrastructure/crossplane/claims/identity-platform/link'));
    const [service] = listServices(root);
    assert.deepEqual(service.infraFiles, ['infrastructure/crossplane/claims/identity-platform/db/claim.yaml']);
    assert.equal(service.claims.postgres, true);
    assert.equal(service.claims.s3, false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

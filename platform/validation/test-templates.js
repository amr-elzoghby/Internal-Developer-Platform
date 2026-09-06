const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const yaml = require('yaml');
const { renderTemplate } = require('./render-templates');
const root = path.resolve(__dirname, '../..');
const values = {component_id: 'service-test', owner: 'identity-platform', namespace: 'identity-platform'};
for (const language of ['nodejs-service', 'python-fastapi']) {
  for (const description of ['normal', 'quote " colon: newline\nعربي \\ end', '</script> ${unsafe} ☃']) {
    test(`${language}: serialized description ${JSON.stringify(description)}`, () => {
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'idp-scaffold-'));
      try {
        renderTemplate(path.join(root, 'templates/backstage', language, 'skeleton'), directory, {...values, description});
        const entity = yaml.parse(fs.readFileSync(path.join(directory, 'catalog-info.yaml'), 'utf8'));
        assert.equal(entity.metadata.description, description);
        const kustomization = yaml.parse(fs.readFileSync(path.join(directory, 'kustomization.yaml'), 'utf8'));
        assert.deepEqual(kustomization.resources, []);
        const docs = yaml.parseAllDocuments(fs.readFileSync(path.join(directory, 'deployment.yaml'), 'utf8')).map(doc => {
          assert.equal(doc.errors.length, 0); return doc.toJSON();
        });
        assert.equal(docs.filter(doc => doc.kind === 'Deployment').length, 1);
        assert.equal(docs.filter(doc => doc.kind === 'Service').length, 1);
        JSON.parse(fs.readFileSync(path.join(directory, 'delivery.json'), 'utf8'));
        if (language === 'nodejs-service') {
          assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).description, description);
          const lock = JSON.parse(fs.readFileSync(path.join(directory, 'package-lock.json')));
          assert.equal(lock.name, values.component_id);
          execFileSync('node', ['--check', path.join(directory, 'src/server.js')]);
        } else {
          execFileSync('python3', ['-c', 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())', path.join(directory, 'main.py')]);
        }
      } finally { fs.rmSync(directory, { recursive: true, force: true }); }
    });
  }
}

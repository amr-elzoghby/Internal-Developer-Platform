const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const yaml = require('yaml');
const { renderTemplate } = require('./render-templates');

const root = path.resolve(__dirname, '../..');
const teams = ['identity-platform', 'platform-engineering', 'data-platform'];

for (const team of teams) {
  for (const language of ['nodejs-service', 'python-fastapi']) {
    test(`${team}/${language}: GitOps leaves existing replica counts to the HPA`, () => {
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'idp-hpa-gitops-'));
      try {
        const component = 'autoscaled-service';
        renderTemplate(path.join(root, 'templates/backstage', language, 'skeleton'), directory, {
          component_id: component, owner: team, namespace: team, description: 'HPA integration fixture'
        });
        const resources = yaml.parseAllDocuments(fs.readFileSync(path.join(directory, 'deployment.yaml'), 'utf8'))
          .map(document => { assert.equal(document.errors.length, 0); return document.toJSON(); });
        const appset = yaml.parse(fs.readFileSync(path.join(root,
          'platform/gitops/argocd/applicationsets', `${team}-apps.yaml`), 'utf8'));
        const application = appset.spec.template.spec;
        assert.equal(application.destination.namespace, team);
        assert.ok(appset.spec.generators.some(generator => generator.git?.directories
          ?.some(entry => entry.path === `apps/${team}/*`)), 'The generated service must be discovered');
        assert.equal(application.syncPolicy.automated.selfHeal, true);

        const autoscalers = resources.filter(resource => resource.kind === 'HorizontalPodAutoscaler');
        assert.equal(autoscalers.length, 1);
        for (const hpa of autoscalers) {
          const target = hpa.spec.scaleTargetRef;
          const workload = resources.find(resource => resource.apiVersion === target.apiVersion &&
            resource.kind === target.kind && resource.metadata.name === target.name &&
            resource.metadata.namespace === hpa.metadata.namespace);
          assert.ok(workload, 'The HPA must reference a rendered workload in its namespace');
          assert.equal(workload.spec.replicas, hpa.spec.minReplicas, 'Initial creation retains minimum capacity');
          assert.ok(hpa.spec.maxReplicas > workload.spec.replicas, 'The HPA must be able to scale above Git replicas');

          const group = target.apiVersion.split('/')[0];
          const ignored = (application.ignoreDifferences || []).filter(rule =>
            rule.group === group && rule.kind === target.kind &&
            (!rule.name || rule.name === target.name) &&
            (!rule.namespace || rule.namespace === workload.metadata.namespace));
          assert.ok(ignored.some(rule => rule.jsonPointers?.includes('/spec/replicas')),
            'HPA scale changes must not trigger Argo self-healing');
          assert.ok(application.syncPolicy.syncOptions.includes('RespectIgnoreDifferences=true'),
            'An unrelated application sync must also preserve the live HPA replica count');
          for (const rule of ignored) {
            assert.deepEqual(rule.jsonPointers, ['/spec/replicas'], 'Workload configuration must remain managed by Git');
            assert.equal(rule.jqPathExpressions, undefined);
            assert.equal(rule.managedFieldsManagers, undefined);
          }
        }
      } finally { fs.rmSync(directory, { recursive: true, force: true }); }
    });
  }
}

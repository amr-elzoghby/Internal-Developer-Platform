const fs = require('node:fs');
const path = require('node:path');
const YAML = require('yaml');
const SUPPORTED_CLAIM_TYPES = Object.freeze(['postgres', 'redis', 's3', 'ec2']);
const TEAMS = new Set(['identity-platform', 'platform-engineering', 'data-platform']);
const CLAIM_KINDS = { PostgresSQLInstance: 'postgres', RedisInstance: 'redis', ObjectBucket: 's3', ServerInstance: 'ec2' };

function loadClaimSpecs(claimsDir) {
  const specs = {};
  for (const file of fs.readdirSync(claimsDir).filter(name => name.endsWith('.json'))) {
    const content = JSON.parse(fs.readFileSync(path.join(claimsDir, file), 'utf8'));
    if (SUPPORTED_CLAIM_TYPES.includes(content.claimType)) specs[content.claimType] = content;
  }
  return specs;
}

function directories(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).filter(entry => entry.isDirectory() && !entry.isSymbolicLink());
}

function readYaml(file) {
  if (fs.lstatSync(file).isSymbolicLink()) throw new Error(`Catalog symlink is forbidden: ${file}`);
  return YAML.parseAllDocuments(fs.readFileSync(file, 'utf8')).map(document => {
    if (document.errors.length) throw document.errors[0];
    return document.toJSON();
  });
}

function claimFiles(directory) {
  if (!fs.existsSync(directory) || fs.lstatSync(directory).isSymbolicLink()) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) return [];
    if (entry.isDirectory()) return claimFiles(file);
    return entry.isFile() && /\.ya?ml$/.test(entry.name) ? [file] : [];
  });
}

function listServices(repoRoot) {
  const services = [];
  const apps = path.join(repoRoot, 'apps');
  for (const team of directories(apps).filter(entry => TEAMS.has(entry.name))) {
    for (const service of directories(path.join(apps, team.name))) {
      const catalogPath = path.join(apps, team.name, service.name, 'catalog-info.yaml');
      if (!fs.existsSync(catalogPath)) continue;
      const entity = readYaml(catalogPath).find(document => document?.kind === 'Component');
      if (!entity || entity.metadata?.name !== service.name || entity.spec?.owner !== team.name) {
        throw new Error(`Catalog ownership/name must match apps/${team.name}/${service.name}`);
      }
      const dependencies = new Set(entity.spec.dependsOn || []);
      const claims = Object.fromEntries(Object.values(CLAIM_KINDS).map(kind => [kind, false]));
      const infraFiles = [];
      const claimsDirectory = path.join(repoRoot, 'infrastructure', 'crossplane', 'claims', team.name);
      for (const file of claimFiles(claimsDirectory)) {
        for (const claim of readYaml(file)) {
          const kind = CLAIM_KINDS[claim?.kind];
          if (!kind || claim.metadata?.namespace !== team.name) continue;
          const related = dependencies.has(`resource:default/${claim.metadata.name}`)
            || claim.metadata.labels?.['idp.platform/component'] === service.name;
          if (!related) continue;
          claims[kind] = true;
          const relative = path.relative(repoRoot, file).split(path.sep).join('/');
          if (!infraFiles.includes(relative)) infraFiles.push(relative);
        }
      }
      const deliveryFile = path.join(apps, team.name, service.name, 'delivery.json');
      const delivery = fs.existsSync(deliveryFile) ? JSON.parse(fs.readFileSync(deliveryFile, 'utf8')) : {};
      const manifestFile = path.join(apps, team.name, service.name, 'deployment.yaml');
      const deployment = fs.existsSync(manifestFile) ? readYaml(manifestFile).find(document => document?.kind === 'Deployment') : null;
      const probe = deployment?.spec?.template?.spec?.containers?.[0]?.readinessProbe?.httpGet;
      const healthCheck = delivery.mode === 'source' && probe
        ? `GET ${probe.path} (declared; live response not checked)`
        : 'Unavailable: no verified application health endpoint';
      services.push({
        id: `${team.name}/${service.name}`,
        name: entity.metadata.name,
        owner: entity.spec.owner,
        type: entity.spec.type || 'service',
        system: entity.spec.system || 'platform-services',
        lifecycle: entity.spec.lifecycle || 'experimental',
        path: path.posix.join('apps', team.name, service.name),
        argoApplication: `${team.name}-${service.name}`,
        infraFiles,
        claims,
        healthCheck,
        status: {
          argocd: 'Live Argo CD status is not connected',
          pods: 'Live Kubernetes status is not connected',
          security: 'Live Trivy results are not connected',
          sonarqube: 'SonarQube is not connected',
          cpuUsage: 'Unavailable', memoryUsage: 'Unavailable', restarts: 'Unavailable'
        }
      });
    }
  }
  return services;
}
module.exports = { loadClaimSpecs, listServices };

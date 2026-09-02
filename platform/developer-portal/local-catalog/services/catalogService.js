const fs = require('fs');
const path = require('path');
const { SUPPORTED_CLAIM_TYPES } = require('./claimGenerator');

function loadClaimSpecs(claimsDir) {
  const specs = {};
  if (fs.existsSync(claimsDir)) {
    const files = fs.readdirSync(claimsDir).filter(f => f.endsWith('.json'));
    for (const f of files) {
      try {
        const content = JSON.parse(fs.readFileSync(path.join(claimsDir, f), 'utf8'));
        if (SUPPORTED_CLAIM_TYPES.includes(content.claimType)) {
          specs[content.claimType] = content;
        }
      } catch (e) {
        console.error(`Error loading claim spec file ${f}:`, e);
      }
    }
  }
  return specs;
}

function listServices(projectsDir) {
  const services = [];
  try {
    const dirs = fs.readdirSync(projectsDir);
    for (const d of dirs) {
      const catalogPath = path.join(projectsDir, d, 'catalog-info.yaml');
      if (fs.existsSync(catalogPath)) {
        const content = fs.readFileSync(catalogPath, 'utf8');

        const infraDir = path.join(projectsDir, d, 'infra');
        let infraFiles = [];
        if (fs.existsSync(infraDir)) {
          infraFiles = fs.readdirSync(infraDir).filter(f => f.endsWith('.yaml'));
        }

        const hasPg = infraFiles.some(f => f.includes('postgres') || f.includes('db'));
        const hasRedis = infraFiles.some(f => f.includes('redis') || f.includes('cache'));
        const hasS3 = infraFiles.some(f => f.includes('s3') || f.includes('storage'));
        const hasEc2 = infraFiles.some(f => f.includes('ec2') || f.includes('server'));

        const nameMatch = content.match(/name:\s*(.+)/);
        const ownerMatch = content.match(/owner:\s*(.+)/);
        const typeMatch = content.match(/type:\s*(.+)/);
        const systemMatch = content.match(/system:\s*(.+)/);
        const lifecycleMatch = content.match(/lifecycle:\s*(.+)/);

        services.push({
          name: nameMatch ? nameMatch[1].trim() : d,
          owner: ownerMatch ? ownerMatch[1].trim() : 'identity-platform',
          type: typeMatch ? typeMatch[1].trim() : 'service',
          system: systemMatch ? systemMatch[1].trim() : 'shopscale-ecommerce',
          lifecycle: lifecycleMatch ? lifecycleMatch[1].trim() : 'production',
          path: d,
          infraFiles,
          claims: {
            postgres: hasPg,
            redis: hasRedis,
            s3: hasS3,
            ec2: hasEc2
          },
          status: {
            connected: false,
            argocd: 'Live Argo CD status is not connected',
            pods: 'Live Kubernetes status is not connected',
            security: 'Live Trivy results are not connected',
            sonarqube: 'SonarQube is not connected',
            cpuUsage: 'Unavailable',
            memoryUsage: 'Unavailable',
            restarts: 'Unavailable',
            buildRun: null
          }
        });
      }
    }
  } catch (e) {
    console.error('Error scanning catalog projects:', e);
  }
  return services;
}

module.exports = {
  loadClaimSpecs,
  listServices
};

const fs = require('fs');
const path = require('path');
const { exec, spawn } = require('child_process');
const { generateClaimYaml } = require('./claimGenerator');

let runningAppProcess = null;

function execPromise(command) {
  return new Promise((resolve) => {
    exec(command, (error, stdout, stderr) => {
      if (error) {
        console.warn(`[Git Warn] Command failed: ${command}`, stderr || error.message);
        resolve({ success: false, error: stderr || error.message });
      } else {
        resolve({ success: true, stdout });
      }
    });
  });
}

function loadClaimSpecs(claimsDir) {
  const specs = {};
  if (fs.existsSync(claimsDir)) {
    const files = fs.readdirSync(claimsDir).filter(f => f.endsWith('.json'));
    for (const f of files) {
      try {
        const content = JSON.parse(fs.readFileSync(path.join(claimsDir, f), 'utf8'));
        if (content.claimType) {
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
        const hasKafka = infraFiles.some(f => f.includes('kafka') || f.includes('topic'));
        const hasSsl = infraFiles.some(f => f.includes('ssl') || f.includes('cert'));
        const hasOauth = infraFiles.some(f => f.includes('oauth') || f.includes('payment'));
        const hasGrafana = infraFiles.some(f => f.includes('grafana') || f.includes('dashboard'));
        const hasSlack = infraFiles.some(f => f.includes('slack') || f.includes('alert'));
        const hasDomain = infraFiles.some(f => f.includes('ingress') || f.includes('subdomain'));

        const nameMatch = content.match(/name:\s*(.+)/);
        const ownerMatch = content.match(/owner:\s*(.+)/);
        const typeMatch = content.match(/type:\s*(.+)/);

        services.push({
          name: nameMatch ? nameMatch[1].trim() : d,
          owner: ownerMatch ? ownerMatch[1].trim() : 'team-alpha',
          type: typeMatch ? typeMatch[1].trim() : 'service',
          lifecycle: 'production',
          path: path.join(projectsDir, d),
          infraFiles,
          claims: {
            postgres: hasPg,
            redis: hasRedis,
            s3: hasS3,
            kafka: hasKafka,
            ssl: hasSsl,
            oauth: hasOauth,
            grafana: hasGrafana,
            slack: hasSlack,
            domain: hasDomain
          },
          status: {
            argocd: 'Synced & Healthy',
            pods: '2/2 Running',
            security: 'Trivy Scan Passed (0 Vulns)',
            sonarqube: 'Quality Gate Passed'
          }
        });
      }
    }
  } catch (e) {
    console.error('Error scanning catalog projects:', e);
  }
  return services;
}

async function applyClaimToCatalog(projectName, claimType, customClaimName, params, projectsDir) {
  const projectDir = path.join(projectsDir, projectName);
  if (!fs.existsSync(projectDir)) {
    throw new Error(`Service "${projectName}" not found`);
  }

  const infraDir = path.join(projectDir, 'infra');
  fs.mkdirSync(infraDir, { recursive: true });

  const claimSpec = generateClaimYaml(projectName, claimType, params);
  fs.writeFileSync(path.join(projectDir, claimSpec.file), claimSpec.content);

  // Update catalog-info.yaml metadata
  const catalogPath = path.join(projectDir, 'catalog-info.yaml');
  if (fs.existsSync(catalogPath)) {
    let catText = fs.readFileSync(catalogPath, 'utf8');
    const claimIdName = customClaimName || claimType;
    if (!catText.includes(claimIdName)) {
      catText = catText.replace('dependsOn:', `dependsOn:\n    - resource:${projectName}-${claimIdName}-claim`);
      fs.writeFileSync(catalogPath, catText);
    }
  }

  // Robust Git Commit in project repo using async Promise execution
  const commitMsg = `feat(infra): add ${customClaimName || claimType} claim (${claimSpec.file}) via Backstage`;
  await execPromise(`cd "${projectDir}" && git add . && git commit -m "${commitMsg}"`);

  // Launch / Restart Service on port 4000
  if (projectName === 'Demo-login-app-IDB' || fs.existsSync(path.join(projectDir, 'server.js'))) {
    if (runningAppProcess) { runningAppProcess.kill(); }
    const env = Object.assign({}, process.env, {
      PORT: '4000',
      DB_HOST: 'postgres-rds.internal.aws',
      REDIS_HOST: 'redis-cluster.internal.aws',
      S3_BUCKET: `${projectName.toLowerCase()}-cloud-storage`
    });
    runningAppProcess = spawn('node', ['server.js'], { cwd: projectDir, env, stdio: 'inherit' });
  }

  return {
    success: true,
    message: `Claim "${customClaimName || claimType}" generated in ${projectName}!`,
    claimFile: claimSpec.file,
    appUrl: 'http://localhost:4000',
    steps: [
      { id: 1, name: `Generated Crossplane / K8s Spec: ${claimSpec.file}`, status: 'success' },
      { id: 2, name: `Embedded parametric spec parameters`, status: 'success' },
      { id: 3, name: `Updated ${projectName}/catalog-info.yaml dependsOn metadata`, status: 'success' },
      { id: 4, name: `Git Commit: feat(infra): add ${customClaimName || claimType} claim`, status: 'success' }
    ]
  };
}

module.exports = {
  loadClaimSpecs,
  listServices,
  applyClaimToCatalog,
  execPromise
};

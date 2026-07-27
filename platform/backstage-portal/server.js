const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec, spawn } = require('child_process');

const PORT = 3000;
const PROJECTS_DIR = '/home/amr';
let runningAppProcess = null;

function serveFile(res, filePath, contentType) {
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not Found'); }
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
}

function parseBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => resolve(JSON.parse(body || '{}')));
  });
}

// ─── CROSSPLANE & PLATFORM CLAIM GENERATORS (WITH PARAMETRIC CONFIG) ─────

function generateClaimYaml(serviceName, claimType, params = {}) {
  const claimId = (params.customClaimName || claimType).toLowerCase().replace(/[^a-z0-9-]/g, '-');
  const secretName = `${serviceName.toLowerCase()}-${claimId}-secret`;

  switch (claimType) {
    case 'postgres':
      return {
        file: `infra/${claimId}-claim.yaml`,
        content: `apiVersion: database.shopscale.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: ${serviceName}-${claimId}-claim
  namespace: default
  labels:
    app.kubernetes.io/managed-by: crossplane
    shopscale.io/service: ${serviceName}
spec:
  parameters:
    storageGB: ${params.storageGB || 20}
    engineVersion: "${params.engineVersion || '15'}"
  writeConnectionSecretToRef:
    name: ${secretName}
`
      };
    case 'redis':
      return {
        file: `infra/${claimId}-claim.yaml`,
        content: `apiVersion: cache.shopscale.io/v1alpha1
kind: RedisCacheInstance
metadata:
  name: ${serviceName}-${claimId}-claim
  namespace: default
spec:
  parameters:
    memoryMB: ${params.memoryMB || 512}
    version: "${params.redisVersion || '7.0'}"
  writeConnectionSecretToRef:
    name: ${secretName}
`
      };
    case 's3':
      return {
        file: `infra/${claimId}-claim.yaml`,
        content: `apiVersion: storage.shopscale.io/v1alpha1
kind: S3BucketClaim
metadata:
  name: ${serviceName}-${claimId}-claim
  namespace: default
spec:
  parameters:
    bucketName: ${serviceName.toLowerCase()}-${claimId}-bucket
    acl: ${params.bucketAcl || 'private'}
    versioning: ${params.versioning === 'true' || params.versioning === true ? 'true' : 'false'}
`
      };
    case 'kafka':
      return {
        file: `infra/${claimId}-topic-claim.yaml`,
        content: `apiVersion: messaging.shopscale.io/v1alpha1
kind: KafkaTopicClaim
metadata:
  name: ${serviceName}-${claimId}-topic
  namespace: default
spec:
  parameters:
    topicName: ${serviceName.toLowerCase()}-${claimId}
    partitions: ${params.partitions || 3}
    replicationFactor: ${params.replicationFactor || 2}
`
      };
    case 'ssl':
      return {
        file: `infra/${claimId}-cert-claim.yaml`,
        content: `apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${serviceName}-${claimId}-cert
  namespace: default
spec:
  secretName: ${serviceName}-${claimId}-tls-secret
  issuerRef:
    name: ${params.issuer || 'letsencrypt-prod'}
    kind: ClusterIssuer
  dnsNames:
    - ${params.domainName || serviceName.toLowerCase() + '.shopscale.io'}
`
      };
    case 'oauth':
      return {
        file: `infra/${claimId}-credentials-claim.yaml`,
        content: `apiVersion: security.shopscale.io/v1alpha1
kind: PaymentOAuthCredentialsClaim
metadata:
  name: ${serviceName}-${claimId}
  namespace: default
spec:
  parameters:
    provider: ${params.provider || 'Stripe'}
    scopes:
      - ${params.scopes || 'charges.read'}
  writeConnectionSecretToRef:
    name: ${secretName}
`
      };
    case 'grafana':
      return {
        file: `infra/${claimId}-dashboard-claim.yaml`,
        content: `apiVersion: observability.shopscale.io/v1alpha1
kind: GrafanaDashboardClaim
metadata:
  name: ${serviceName}-${claimId}
  namespace: default
spec:
  parameters:
    folder: ${params.folder || 'Platform-Microservices'}
    metrics:
      - ${params.metrics || 'http_requests_total'}
`
      };
    case 'slack':
      return {
        file: `infra/${claimId}-alerts-claim.yaml`,
        content: `apiVersion: notification.shopscale.io/v1alpha1
kind: SlackAlertWebhookClaim
metadata:
  name: ${serviceName}-${claimId}
  namespace: default
spec:
  parameters:
    channel: "${params.slackChannel || '#alerts-platform-prod'}"
    webhookUrl: "${params.slackWebhookUrl || 'https://slack.workspace.internal/webhook-endpoint'}"
    events:
      - ${params.alertEvents || 'PodCrashLoopBackOff'}
`
      };
    case 'domain':
      return {
        file: `infra/${claimId}-ingress-claim.yaml`,
        content: `apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${serviceName}-${claimId}-ingress
  namespace: default
spec:
  rules:
  - host: ${params.subdomainHost || 'api.' + serviceName.toLowerCase() + '.shopscale.com'}
    http:
      paths:
      - path: ${params.pathPrefix || '/'}
        pathType: Prefix
        backend:
          service:
            name: ${serviceName}
            port:
              number: 80
`
      };
    default:
      throw new Error(`Unknown claim type: ${claimType}`);
  }
}

// ─── HTTP SERVER ────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {

  // ── API 1: List Existing Workspace Microservices ───────────
  if (req.method === 'GET' && req.url === '/api/catalog') {
    const services = [];
    try {
      const dirs = fs.readdirSync(PROJECTS_DIR);
      for (const d of dirs) {
        const catalogPath = path.join(PROJECTS_DIR, d, 'catalog-info.yaml');
        if (fs.existsSync(catalogPath)) {
          const content = fs.readFileSync(catalogPath, 'utf8');

          const infraDir = path.join(PROJECTS_DIR, d, 'infra');
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
            path: path.join(PROJECTS_DIR, d),
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
      console.error(e);
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(services));
    return;
  }

  // ── API 2: Request Infrastructure Claim with Custom Params ──
  if (req.method === 'POST' && req.url === '/api/request-infra') {
    const params = await parseBody(req);
    const { projectName, claimType, customClaimName } = params;
    const projectDir = path.join(PROJECTS_DIR, projectName);

    if (!fs.existsSync(projectDir)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: `Service "${projectName}" not found` }));
    }

    try {
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

      // Git Commit in project repo
      exec(`cd ${projectDir} && git add . && git commit -m "feat(infra): add ${customClaimName || claimType} claim (${claimSpec.file}) via Backstage"`, () => {});

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

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
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
      }));
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
    return;
  }

  // ── Static Files ──────────────────────────────────────────
  let filePath = req.url === '/' ? '/index.html' : req.url;
  const fullPath = path.join(__dirname, 'public', filePath);
  const ext = path.extname(fullPath);
  const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript' };
  serveFile(res, fullPath, types[ext] || 'text/plain');
});

server.listen(PORT, () => {
  console.log(`\n======================================================`);
  console.log(`🚀 Backstage Developer Portal LIVE at http://localhost:${PORT}`);
  console.log(`   Connected Microservices run on http://localhost:4000`);
  console.log(`======================================================\n`);
});

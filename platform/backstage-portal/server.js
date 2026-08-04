const http = require('http');
const fs = require('fs');
const path = require('path');
const { loadClaimSpecs, listServices, applyClaimToCatalog } = require('./services/catalogService');

const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  fs.readFileSync(envPath, 'utf8').split('\n').forEach(line => {
    const match = line.match(/^\s*([\w]+)\s*=\s*(.+)\s*$/);
    if (match) process.env[match[1]] = match[2];
  });
}

const PORT = 3000;
const PROJECTS_DIR = '/home/amr';
const CLAIMS_DIR = path.join(__dirname, 'claims');
const REQUIRED_ENV_VARS = ['TEAM_ALPHA_PASSCODE', 'TEAM_BETA_PASSCODE', 'TEAM_GAMMA_PASSCODE'];

function serveFile(res, filePath, contentType) {
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not Found'); }
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
}

function parseBody(req, maxSize = 1048576) {
  return new Promise((resolve, reject) => {
    let body = '';
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > maxSize) {
        req.destroy();
        return reject(new Error('Request body too large'));
      }
      body += chunk;
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(body || '{}'));
      } catch (e) {
        reject(new Error('Invalid JSON in request body'));
      }
    });
    req.on('error', (err) => reject(err));
  });
}

const server = http.createServer(async (req, res) => {
  // Enterprise Security & CORS Headers
  const allowedOrigins = ['http://localhost:3000', 'http://localhost:4000'];
  const requestOrigin = req.headers.origin;
  const corsOrigin = allowedOrigins.includes(requestOrigin) ? requestOrigin : allowedOrigins[0];
  const corsHeaders = {
    'Access-Control-Allow-Origin': corsOrigin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'X-XSS-Protection': '1; mode=block'
  };

  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders);
    return res.end();
  }

  // ── API: Team Authentication (server-side validation) ───────
  if (req.method === 'POST' && req.url === '/api/auth/login') {
    let params;
    try {
      params = await parseBody(req);
    } catch (parseErr) {
      res.writeHead(400, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
      return res.end(JSON.stringify({ error: parseErr.message }));
    }
    const { team, passcode } = params;
    const teamPasscodes = {
      'team-alpha': process.env.TEAM_ALPHA_PASSCODE,
      'team-beta': process.env.TEAM_BETA_PASSCODE,
      'team-gamma': process.env.TEAM_GAMMA_PASSCODE
    };
    const teamProfiles = {
      'team-alpha': { name: 'Amr Elzoghby', role: 'team-alpha • Owner', avatar: 'AE' },
      'team-beta': { name: 'John Doe', role: 'team-beta • Platform Eng', avatar: 'JD' },
      'team-gamma': { name: 'Sarah Smith', role: 'team-gamma • Developer', avatar: 'SS' }
    };
    if (!team || !passcode || teamPasscodes[team] !== passcode) {
      res.writeHead(401, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
      return res.end(JSON.stringify({ error: 'Invalid team or passcode.' }));
    }
    res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    return res.end(JSON.stringify({ success: true, team, ...teamProfiles[team] }));
  }

  // ── API 0: Kubernetes Health Probes (Liveness & Readiness) ───
  if (req.method === 'GET' && (req.url === '/api/healthz' || req.url === '/api/readyz')) {
    res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    res.end(JSON.stringify({
      status: 'HEALTHY',
      uptimeSeconds: Math.floor(process.uptime()),
      timestamp: new Date().toISOString(),
      architecture: 'clean-modular-mvc',
      version: '2.0.0-enterprise'
    }));
    return;
  }

  // ── API 1: List Existing Workspace Microservices ───────────
  if (req.method === 'GET' && req.url === '/api/catalog') {
    const services = listServices(PROJECTS_DIR);
    res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    res.end(JSON.stringify(services));
    return;
  }

  // ── API 2: Fetch Modular Claim Specifications ──────────────
  if (req.method === 'GET' && req.url === '/api/claims/specs') {
    const specs = loadClaimSpecs(CLAIMS_DIR);
    res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    res.end(JSON.stringify(specs));
    return;
  }

  // ── API 3: Request Infrastructure Claim ────────────────────
  if (req.method === 'POST' && req.url === '/api/request-infra') {
    let params;
    try {
      params = await parseBody(req);
    } catch (parseErr) {
      res.writeHead(400, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
      return res.end(JSON.stringify({ error: parseErr.message }));
    }
    const { projectName, claimType, customClaimName } = params;

    if (!projectName || !claimType) {
      res.writeHead(400, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
      return res.end(JSON.stringify({ error: 'Missing required fields: projectName and claimType' }));
    }

    try {
      const result = await applyClaimToCatalog(projectName, claimType, customClaimName, params, PROJECTS_DIR);
      res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
      res.end(JSON.stringify(result));
    } catch (err) {
      const statusCode = err.message.includes('not found') ? 404 : 500;
      res.writeHead(statusCode, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
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
  const missing = REQUIRED_ENV_VARS.filter(v => !process.env[v]);
  if (missing.length > 0) {
    console.warn(`\n⚠️  WARNING: Missing environment variables: ${missing.join(', ')}`);
    console.warn(`   Team login will fail until these are configured.`);
    console.warn(`   Run: cp .env.example .env  then set your passcodes.\n`);
  }
  console.log(`\n======================================================`);
  console.log(`🚀 Backstage Developer Portal LIVE at http://localhost:${PORT}`);
  console.log(`   Clean Architecture — Modular Enterprise MVC Engine`);
  console.log(`   Connected Microservices run on http://localhost:4000`);
  console.log(`======================================================\n`);
});

function gracefulShutdown(signal) {
  console.log(`\n[${signal}] Shutting down gracefully...`);
  server.close(() => {
    console.log('Server closed. Exiting.');
    process.exit(0);
  });
  setTimeout(() => {
    console.error('Forced shutdown after timeout.');
    process.exit(1);
  }, 10000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('uncaughtException', (err) => {
  console.error('Uncaught Exception:', err);
  gracefulShutdown('uncaughtException');
});

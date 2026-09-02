const http = require('http');
const fs = require('fs');
const path = require('path');
const { loadClaimSpecs, listServices } = require('./services/catalogService');

const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  fs.readFileSync(envPath, 'utf8').split('\n').forEach(line => {
    const match = line.match(/^\s*([\w]+)\s*=\s*(.+)\s*$/);
    if (match) process.env[match[1]] = match[2];
  });
}

const PORT = Number.parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '127.0.0.1';
const PROJECTS_DIR = path.resolve(process.env.PROJECTS_DIR || '/home/amr');
const CLAIMS_DIR = path.join(__dirname, 'claims');
const PUBLIC_DIR = fs.realpathSync(path.join(__dirname, 'public'));
const REQUIRED_ENV_VARS = [
  'TEAM_ALPHA_PASSCODE',
  'TEAM_BETA_PASSCODE',
  'TEAM_GAMMA_PASSCODE'
];

function isInsideDirectory(candidate, root) {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

function resolvePublicPath(requestPath) {
  if (requestPath.includes('\0') || requestPath.includes('\\')) {
    return null;
  }

  const relativePath = requestPath === '/'
    ? 'index.html'
    : requestPath.replace(/^\/+/, '');
  const candidate = path.resolve(PUBLIC_DIR, relativePath);
  return isInsideDirectory(candidate, PUBLIC_DIR) ? candidate : null;
}

function serveFile(req, res, filePath, contentType, headers) {
  fs.realpath(filePath, (realPathError, realPath) => {
    if (realPathError) {
      res.writeHead(404, headers);
      return res.end('Not Found');
    }
    if (!isInsideDirectory(realPath, PUBLIC_DIR)) {
      res.writeHead(403, headers);
      return res.end('Forbidden');
    }

    fs.readFile(realPath, (readError, data) => {
      if (readError) {
        res.writeHead(404, headers);
        return res.end('Not Found');
      }
      res.writeHead(200, Object.assign({}, headers, { 'Content-Type': contentType }));
      return res.end(req.method === 'HEAD' ? undefined : data);
    });
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
  const allowedOrigins = [`http://localhost:${PORT}`, `http://127.0.0.1:${PORT}`];
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

  let requestPath;
  try {
    requestPath = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  } catch (error) {
    res.writeHead(400, corsHeaders);
    return res.end('Bad Request');
  }

  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders);
    return res.end();
  }

  // ── API: Team Authentication (server-side validation) ───────
  if (req.method === 'POST' && requestPath === '/api/auth/login') {
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
  if (req.method === 'GET' && (requestPath === '/api/healthz' || requestPath === '/api/readyz')) {
    res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    res.end(JSON.stringify({
      status: 'HEALTHY',
      uptimeSeconds: Math.floor(process.uptime()),
      timestamp: new Date().toISOString(),
      mode: 'read-only-local-catalog',
      version: '2.1.0'
    }));
    return;
  }

  // ── API 1: List Existing Workspace Microservices ───────────
  if (req.method === 'GET' && requestPath === '/api/catalog') {
    const services = listServices(PROJECTS_DIR);
    res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    res.end(JSON.stringify(services));
    return;
  }

  // ── API 2: Fetch Modular Claim Specifications ──────────────
  if (req.method === 'GET' && requestPath === '/api/claims/specs') {
    const specs = loadClaimSpecs(CLAIMS_DIR);
    res.writeHead(200, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    res.end(JSON.stringify(specs));
    return;
  }

  if (requestPath.startsWith('/api/')) {
    res.writeHead(404, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
    return res.end(JSON.stringify({ error: 'API endpoint not found' }));
  }

  // ── Static Files ──────────────────────────────────────────
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, Object.assign({}, corsHeaders, { Allow: 'GET, HEAD' }));
    return res.end('Method Not Allowed');
  }

  const fullPath = resolvePublicPath(requestPath);
  if (!fullPath) {
    res.writeHead(403, corsHeaders);
    return res.end('Forbidden');
  }
  const ext = path.extname(fullPath);
  const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript' };
  return serveFile(req, res, fullPath, types[ext] || 'text/plain', corsHeaders);
});

server.listen(PORT, HOST, () => {
  const missing = REQUIRED_ENV_VARS.filter(v => !process.env[v]);
  if (missing.length > 0) {
    console.warn(`\n⚠️  WARNING: Missing environment variables: ${missing.join(', ')}`);
    console.warn(`   Team login will fail until these are configured.`);
    console.warn(`   Run: cp .env.example .env  then set your passcodes.\n`);
  }
  console.log(`\n======================================================`);
  console.log(`🚀 Local IDP catalog available at http://${HOST}:${PORT}`);
  console.log(`   Read-only mode: infrastructure changes must use an approved Backstage Golden Path PR`);
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

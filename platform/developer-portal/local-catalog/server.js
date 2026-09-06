const http = require('http');
const fs = require('fs');
const path = require('path');
const { loadClaimSpecs, listServices } = require('./services/catalogService');

const PORT = Number.parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '127.0.0.1';
const REPOSITORY_ROOT = path.resolve(process.env.REPOSITORY_ROOT || path.join(__dirname, '../../..'));
const CLAIMS_DIR = path.join(__dirname, 'claims');
const PUBLIC_DIR = fs.realpathSync(path.join(__dirname, 'public'));

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

const server = http.createServer((req, res) => {
  // This local catalog is same-origin and read-only.
  const allowedOrigins = [`http://localhost:${PORT}`, `http://127.0.0.1:${PORT}`];
  const requestOrigin = req.headers.origin;
  const corsOrigin = allowedOrigins.includes(requestOrigin) ? requestOrigin : allowedOrigins[0];
  const corsHeaders = {
    'Access-Control-Allow-Origin': corsOrigin,
    'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
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
    let services;
    try {
      services = listServices(REPOSITORY_ROOT);
    } catch (error) {
      console.error('Invalid repository catalog:', error.message);
      res.writeHead(500, Object.assign({}, corsHeaders, { 'Content-Type': 'application/json' }));
      return res.end(JSON.stringify({ error: 'Repository catalog validation failed' }));
    }
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
  console.log(`\n======================================================`);
  console.log(`🚀 Local IDP catalog available at http://${HOST}:${PORT}`);
  console.log(`   Read-only mode: infrastructure changes require a reviewed Git pull request`);
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

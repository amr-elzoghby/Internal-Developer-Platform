let currentInfraType = 'postgres';
let currentComponentData = null;
let allServicesData = [];
let activeUserSession = JSON.parse(localStorage.getItem('idp-session')) || {
  team: 'team-alpha',
  name: 'Amr Elzoghby',
  role: 'team-alpha • Owner',
  avatar: 'AE'
};

function esc(str) {
  const d = document.createElement('div');
  d.appendChild(document.createTextNode(str || ''));
  return d.innerHTML;
}

// Restore session on load
document.addEventListener('DOMContentLoaded', () => {
  const avatarEl = document.getElementById('user-avatar');
  const nameEl = document.getElementById('user-name');
  const roleEl = document.getElementById('user-role-badge');
  if (avatarEl) avatarEl.innerText = activeUserSession.avatar;
  if (nameEl) nameEl.innerText = activeUserSession.name;
  if (roleEl) roleEl.innerText = activeUserSession.role;
  refreshCatalog();
});

const claimDefaultNames = {
  'postgres': 'users-db',
  'redis': 'session-redis',
  's3': 'user-uploads',
  'kafka': 'order-events',
  'ssl': 'api-tls-cert',
  'oauth': 'stripe-payment',
  'grafana': 'metrics-dashboard',
  'slack': 'prod-slack-alerts',
  'domain': 'api-ingress'
};

function showPage(pageId) {
  ['catalog', 'infra', 'singlepane', 'techdocs', 'security'].forEach(t => {
    const pageEl = document.getElementById('page-' + t);
    const navEl = document.getElementById('nav-' + t);
    if (pageEl) pageEl.classList.add('hidden');
    if (navEl) navEl.classList.remove('active');
  });

  const activePage = document.getElementById('page-' + pageId);
  const activeNav = document.getElementById('nav-' + pageId);
  if (activePage) activePage.classList.remove('hidden');
  if (activeNav) activeNav.classList.add('active');

  if (pageId === 'catalog') refreshCatalog();
  if (pageId === 'singlepane') loadSinglePanePage();
  if (pageId === 'techdocs') loadTechDocsPage();
}

function closeModal(id) { document.getElementById(id).classList.remove('active'); }

function openLoginModal() {
  document.getElementById('login-passcode').value = '';
  document.getElementById('login-error-banner').style.display = 'none';
  document.getElementById('modal-login').classList.add('active');
}

async function executeTeamLogin() {
  const team = document.getElementById('login-team-select').value;
  const passcode = document.getElementById('login-passcode').value.trim();
  const errorBanner = document.getElementById('login-error-banner');

  try {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ team, passcode })
    });
    const data = await res.json();

    if (!res.ok) {
      errorBanner.innerText = `❌ Access Denied: ${data.error}`;
      errorBanner.style.display = 'block';
      return;
    }

    errorBanner.style.display = 'none';
    activeUserSession = { team: data.team, name: data.name, role: data.role, avatar: data.avatar };
    localStorage.setItem('idp-session', JSON.stringify(activeUserSession));

    document.getElementById('user-avatar').innerText = activeUserSession.avatar;
    document.getElementById('user-name').innerText = activeUserSession.name;
    document.getElementById('user-role-badge').innerText = activeUserSession.role;

    closeModal('modal-login');
    refreshCatalog();
  } catch (err) {
    errorBanner.innerText = '❌ Connection error. Please try again.';
    errorBanner.style.display = 'block';
  }
}

async function refreshCatalog() {
  try {
    const res = await fetch('/api/catalog');
    allServicesData = await res.json();
    const tbody = document.getElementById('catalog-table');

    if (!allServicesData || allServicesData.length === 0) {
      tbody.innerHTML = `<tr><td colspan="7" style="text-align:center; padding:30px; color:var(--text-muted);">No services found in workspace.</td></tr>`;
      return;
    }

    tbody.innerHTML = allServicesData.map(s => {
      const claims = [];
      if (s.claims.postgres) claims.push('<span class="badge badge-claim">🗄️ PostgreSQL</span>');
      if (s.claims.redis) claims.push('<span class="badge badge-claim">⚡ Redis</span>');
      if (s.claims.s3) claims.push('<span class="badge badge-claim">📦 S3 Storage</span>');
      if (s.claims.kafka) claims.push('<span class="badge badge-claim">📨 Kafka</span>');
      if (s.claims.ssl) claims.push('<span class="badge badge-claim">🔒 TLS Cert</span>');
      if (s.claims.oauth) claims.push('<span class="badge badge-claim">🔑 Payment OAuth</span>');
      if (s.claims.grafana) claims.push('<span class="badge badge-claim">📊 Grafana</span>');
      if (s.claims.slack) claims.push('<span class="badge badge-claim">🔔 Slack Alerts</span>');
      if (s.claims.domain) claims.push('<span class="badge badge-claim">🌐 Subdomain</span>');

      if (claims.length === 0) claims.push('<span style="color:var(--text-dim); font-size:12px;">No Claims</span>');

      return `
        <tr>
          <td><strong>${esc(s.name)}</strong><br/><span style="font-size:11px; color:var(--text-dim);">${esc(s.path)}</span></td>
          <td><code>${esc(s.owner)}</code></td>
          <td>shopscale-ecommerce</td>
          <td><span class="badge badge-prod">${esc(s.lifecycle)}</span></td>
          <td>${claims.join(' ')}</td>
          <td><span style="color:var(--success); font-weight:600;">● ${esc(s.status.argocd)}</span></td>
          <td>
            <button class="btn btn-secondary" style="padding:4px 10px; font-size:12px;" onclick="inspectEntity('${esc(s.name)}')">Single Pane View 🔍</button>
          </td>
        </tr>`;
    }).join('');
  } catch(e) {
    console.error(e);
    const tbody = document.getElementById('catalog-table');
    if (tbody) {
      tbody.innerHTML = `<tr><td colspan="7" style="text-align:center; padding:30px; color:var(--danger);">⚠️ Failed to load services. Server may be offline.</td></tr>`;
    }
  }
}

async function openInfraModal(type) {
  currentInfraType = type;
  document.getElementById('infra-form').classList.remove('hidden');
  document.getElementById('infra-result').classList.add('hidden');
  document.getElementById('infra-title').innerText = `Request ${type.toUpperCase()} Infrastructure Claim`;
  document.getElementById('infra-custom-name').value = claimDefaultNames[type] || `${type}-claim`;

  const sel = document.getElementById('infra-target-project');
  sel.innerHTML = '';

  try {
    const res = await fetch('/api/catalog');
    const services = await res.json();

    if (!services || services.length === 0) {
      sel.innerHTML = '<option value="">No services found</option>';
    } else {
      services.forEach(s => {
        const opt = document.createElement('option');
        opt.value = s.name;
        opt.innerText = s.name;
        sel.appendChild(opt);
      });
    }
  } catch (e) {
    sel.innerHTML = '<option value="">⚠️ Failed to load services</option>';
  }

  document.getElementById('modal-infra').classList.add('active');
}

async function executeInfraClaim() {
  const projectName = document.getElementById('infra-target-project').value;
  const customClaimName = document.getElementById('infra-custom-name').value.trim() || claimDefaultNames[currentInfraType];

  document.getElementById('infra-form').classList.add('hidden');
  const resDiv = document.getElementById('infra-result');
  resDiv.classList.remove('hidden');
  resDiv.innerHTML = '<div class="log-box" id="infra-log"></div>';

  const logBox = document.getElementById('infra-log');
  const steps = [
    `⏳ Connecting to service repository: /home/amr/${projectName}/...`,
    `⏳ Writing Crossplane spec: infra/${customClaimName}-claim.yaml...`,
    `⏳ Setting writeConnectionSecretToRef.name: ${projectName.toLowerCase()}-${customClaimName.toLowerCase()}-secret...`,
    '⏳ Updating catalog-info.yaml dependsOn metadata...',
    '⏳ Git commit: feat(infra): add claim via Backstage Self-Service...',
    '⏳ Provisioning cloud infrastructure & updating Kubernetes connection secrets...'
  ];

  steps.forEach((st, i) => {
    setTimeout(() => {
      const div = document.createElement('div');
      div.className = 'log-step';
      div.innerText = st;
      logBox.appendChild(div);
      setTimeout(() => div.classList.add('visible'), 30);
    }, i * 400);
  });

  const res = await fetch('/api/request-infra', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ projectName, claimType: currentInfraType, customClaimName })
  });
  const data = await res.json();

  setTimeout(() => {
    logBox.innerHTML = '';
    data.steps.forEach(s => {
      const div = document.createElement('div');
      div.className = 'log-step success visible';
      div.innerText = '✅ ' + s.name;
      logBox.appendChild(div);
    });

    resDiv.innerHTML += `
      <div class="result-box">
        <h4 style="color:var(--success);">🎉 Crossplane Claim "${customClaimName}" Generated!</h4>
        <p style="font-size:12px; color:var(--text-muted); margin:6px 0;">YAML Spec generated in repository root:</p>
        <code>📄 ${projectName}/${data.claimFile}</code>
        <p style="font-size:12px; color:var(--text-muted); margin-top:10px;">
          Connection secrets & configuration environment variables are now injected into the service!
        </p>
        <div style="margin-top:14px; display:flex; gap:10px;">
          <a href="${data.appUrl}" target="_blank" class="btn">🌐 Inspect Service (port 4000)</a>
          <button class="btn btn-secondary" onclick="closeModal('modal-infra'); showPage('catalog');">Done</button>
        </div>
      </div>`;
  }, steps.length * 400 + 500);
}

async function inspectEntity(name) {
  const res = await fetch('/api/catalog');
  const services = await res.json();
  currentComponentData = services.find(x => x.name === name);
  if (!currentComponentData) return;

  document.getElementById('entity-modal-name').innerText = `Single Pane View: ${currentComponentData.name}`;
  switchInspectorTab('overview');
  document.getElementById('modal-entity').classList.add('active');
}

function switchInspectorTab(tab, element) {
  document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
  if (element) {
    element.classList.add('active');
  } else {
    const firstTab = document.querySelector('.tab-btn');
    if (firstTab) firstTab.classList.add('active');
  }

  const c = currentComponentData;
  if (!c) return;
  const content = document.getElementById('inspector-content');

  if (tab === 'overview') {
    content.innerHTML = `
      <div style="background:var(--bg-root); padding:16px; border-radius:10px; border:1px solid var(--border-color); font-size:13px;">
        <p style="margin-bottom:8px;"><strong>Kind:</strong> Component</p>
        <p style="margin-bottom:8px;"><strong>Type:</strong> ${esc(c.type)}</p>
        <p style="margin-bottom:8px;"><strong>Owner Team:</strong> <code>${esc(c.owner)}</code></p>
        <p style="margin-bottom:8px;"><strong>System:</strong> shopscale-ecommerce</p>
        <p style="margin-bottom:8px;"><strong>Repository Path:</strong> <code>${esc(c.path)}</code></p>
        <p><strong>Backstage Spec:</strong> <code>${esc(c.path)}/catalog-info.yaml</code></p>
      </div>`;
  } else if (tab === 'cicd') {
    content.innerHTML = `
      <div style="background:var(--bg-root); padding:16px; border-radius:10px; border:1px solid var(--border-color); font-size:13px;">
        <p style="color:var(--success); font-weight:600; margin-bottom:8px;">🛡️ Trivy Security Scanner: ${esc(c.status.security)}</p>
        <p style="color:var(--success); font-weight:600; margin-bottom:8px;">📊 SonarQube Quality Gate: ${esc(c.status.sonarqube)}</p>
        <hr style="border-color:var(--border-color); margin:12px 0;"/>
        <p style="font-weight:600; margin-bottom:8px;">Recent GitHub Actions Pipeline Runs:</p>
        <p style="color:var(--text-muted);">Run #${c.status.buildRun || 142} • Main Branch • <span style="color:var(--success);">Success</span> (38s ago)</p>
        <p style="color:var(--text-muted);">Run #${(c.status.buildRun || 142) - 1} • Main Branch • <span style="color:var(--success);">Success</span> (2h ago)</p>
      </div>`;
  } else if (tab === 'k8s') {
    content.innerHTML = `
      <div style="background:var(--bg-root); padding:16px; border-radius:10px; border:1px solid var(--border-color); font-size:13px;">
        <p style="color:var(--success); font-weight:600; margin-bottom:8px;">● Pods Status: ${esc(c.status.pods)}</p>
        <p style="color:var(--success); font-weight:600; margin-bottom:8px;">● ArgoCD GitOps: ${esc(c.status.argocd)}</p>
        <hr style="border-color:var(--border-color); margin:12px 0;"/>
        <p><strong>CPU Usage:</strong> ${esc(c.status.cpuUsage || '42m / 500m (8%)')}</p>
        <p style="margin-top:6px;"><strong>Memory Usage:</strong> ${esc(c.status.memoryUsage || '112Mi / 512Mi (21%)')}</p>
        <p style="margin-top:6px;"><strong>Restarts:</strong> ${esc(c.status.restarts || '0 (Stable)')}</p>
      </div>`;
  } else if (tab === 'claims') {
    let claimsList = c.infraFiles || [];
    content.innerHTML = `
      <div style="background:var(--bg-root); padding:16px; border-radius:10px; border:1px solid var(--border-color); font-size:13px;">
        <p style="font-weight:600; margin-bottom:12px;">Active Crossplane / K8s Infrastructure Claims (${claimsList.length}):</p>
        ${claimsList.length > 0 
          ? claimsList.map(item => `<div style="background:var(--bg-card); padding:8px 12px; border-radius:6px; margin-bottom:6px; border:1px solid var(--border-color); color:var(--accent-blue);">📄 infra/${esc(item)}</div>`).join('')
          : '<p style="color:var(--text-dim);">No Infrastructure Claims attached yet. Use the Self-Service portal to request resources!</p>'}
      </div>`;
  }
}

async function loadSinglePanePage() {
  const sel = document.getElementById('singlepane-select-service');
  if (!sel) return;
  sel.innerHTML = '';

  try {
    const res = await fetch('/api/catalog');
    allServicesData = await res.json();

    if (!allServicesData || allServicesData.length === 0) {
      sel.innerHTML = '<option value="">No components found</option>';
      return;
    }

    allServicesData.forEach(s => {
      const opt = document.createElement('option');
      opt.value = s.name;
      opt.innerText = s.name;
      sel.appendChild(opt);
    });

    renderSinglePaneDashboard(allServicesData[0].name);
  } catch (e) {
    sel.innerHTML = '<option value="">⚠️ Failed to load services</option>';
    document.getElementById('singlepane-grid').innerHTML = '<div class="card"><h3>⚠️ Connection Error</h3><p>Could not connect to the API server.</p></div>';
  }
}

async function loadTechDocsPage() {
  const sel = document.getElementById('techdocs-select-service');
  if (!sel) return;
  sel.innerHTML = '';

  try {
    const res = await fetch('/api/catalog');
    allServicesData = await res.json();

    if (!allServicesData || allServicesData.length === 0) {
      sel.innerHTML = '<option value="">No components found</option>';
      return;
    }

    allServicesData.forEach(s => {
      const opt = document.createElement('option');
      opt.value = s.name;
      opt.innerText = s.name;
      sel.appendChild(opt);
    });

    renderTechDocs(allServicesData[0].name);
  } catch (e) {
    sel.innerHTML = '<option value="">⚠️ Failed to load services</option>';
    document.getElementById('techdocs-container').innerHTML = '<h3>⚠️ Connection Error</h3><p>Could not connect to the API server.</p>';
  }
}

function renderTechDocs(name) {
  const c = allServicesData.find(x => x.name === name);
  if (!c) return;

  const claimsList = c.infraFiles || [];
  const claimsText = claimsList.length > 0
    ? claimsList.map(item => `<code>infra/${esc(item)}</code>`).join(', ')
    : 'No active claims';

  document.getElementById('techdocs-container').innerHTML = `
    <h3>📚 ${esc(c.name)} — Architecture & Runbook</h3>
    <p style="color:var(--text-dim); margin-bottom:16px;">Source: <code>${esc(c.path)}/catalog-info.yaml</code> (Owner: <code>${esc(c.owner)}</code>)</p>
    <div style="background:var(--bg-root); padding:20px; border-radius:8px; border:1px solid var(--border-color); font-size:13.5px; line-height:1.7;">
      <h4 style="color:var(--primary); margin-bottom:8px;">1. Service Overview</h4>
      <p>The <strong>${esc(c.name)}</strong> component is a <code>${esc(c.type)}</code> microservice owned by <code>${esc(c.owner)}</code> running in <code>${esc(c.lifecycle)}</code> lifecycle.</p>
      
      <h4 style="color:var(--primary); margin-top:16px; margin-bottom:8px;">2. Active Infrastructure & Environment Binding</h4>
      <p>Active Infrastructure Claims: ${claimsText}. When Claims are requested via Backstage Self-Service, Crossplane generates Custom Resources in <code>infra/</code> and injects connection secrets into K8s Pod environment variables.</p>
      
      <h4 style="color:var(--primary); margin-top:16px; margin-bottom:8px;">3. Operational Playbook</h4>
      <p>• <strong>Health Check:</strong> <code>GET /healthz</code><br/>
         • <strong>ArgoCD GitOps Sync:</strong> Automatic upon <code>git push main</code><br/>
         • <strong>Emergency Rollback:</strong> <code>argocd app sync ${esc(c.name).toLowerCase()} --revision HEAD~1</code></p>
    </div>
  `;
}

function renderSinglePaneDashboard(name) {
  const c = allServicesData.find(x => x.name === name);
  if (!c) return;

  const claimsList = c.infraFiles || [];
  const grid = document.getElementById('singlepane-grid');
  grid.innerHTML = `
    <div class="card">
      <h3>📁 Overview & Metadata</h3>
      <p><strong>Kind/Type:</strong> Component / ${esc(c.type)}<br/>
         <strong>Owner Team:</strong> ${esc(c.owner)}<br/>
         <strong>System:</strong> shopscale-ecommerce<br/>
         <strong>Path:</strong> <code>${esc(c.path)}</code></p>
    </div>

    <div class="card">
      <h3>🛡️ Security & Quality Gate</h3>
      <p><span style="color:var(--success); font-weight:600;">● Trivy Scan:</span> ${esc(c.status.security)}<br/>
         <span style="color:var(--success); font-weight:600;">● SonarQube:</span> ${esc(c.status.sonarqube)}<br/>
         <strong>Pipeline:</strong> GitHub Actions Run #${c.status.buildRun || 142} Success</p>
    </div>

    <div class="card">
      <h3>☸️ K8s & GitOps Status</h3>
      <p><span style="color:var(--success); font-weight:600;">● Pods:</span> ${esc(c.status.pods)}<br/>
         <span style="color:var(--success); font-weight:600;">● ArgoCD Sync:</span> ${esc(c.status.argocd)}<br/>
         <strong>Metrics:</strong> CPU ${esc(c.status.cpuUsage || '8%')} | Memory ${esc(c.status.memoryUsage || '21%')}</p>
    </div>

    <div class="card">
      <h3>🗄️ Active Claims (${claimsList.length})</h3>
      <div style="font-size:12.5px; color:var(--accent-blue); line-height:1.6;">
        ${claimsList.length > 0 ? claimsList.map(item => `<div>• 📄 infra/${esc(item)}</div>`).join('') : '<span style="color:var(--text-dim);">No Active Claims</span>'}
      </div>
    </div>
  `;
}

function handleSearch(query) {
  const q = query.toLowerCase().trim();
  const rows = document.querySelectorAll('#catalog-table tr');
  rows.forEach(row => {
    if (!q) { row.style.display = ''; return; }
    const text = row.textContent.toLowerCase();
    row.style.display = text.includes(q) ? '' : 'none';
  });
  const cards = document.querySelectorAll('#page-infra .card');
  cards.forEach(card => {
    if (!q) { card.style.display = ''; return; }
    const text = card.textContent.toLowerCase();
    card.style.display = text.includes(q) ? '' : 'none';
  });
}

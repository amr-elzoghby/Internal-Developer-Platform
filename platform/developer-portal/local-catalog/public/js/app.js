let currentComponentData = null;
let allServicesData = [];
const teamViews = Object.freeze({
  'identity-platform': { team: 'identity-platform', name: 'Identity Platform', role: 'Read-only team view', avatar: 'IP' },
  'platform-engineering': { team: 'platform-engineering', name: 'Platform Engineering', role: 'Read-only team view', avatar: 'PE' },
  'data-platform': { team: 'data-platform', name: 'Data Platform', role: 'Read-only team view', avatar: 'DP' }
});

function loadTeamView() {
  try {
    const saved = JSON.parse(localStorage.getItem('idp-team-view-v2'));
    if (saved && teamViews[saved.team]) return teamViews[saved.team];
  } catch (error) {
    localStorage.removeItem('idp-team-view-v2');
  }
  return teamViews['identity-platform'];
}

let activeUserSession = loadTeamView();

function esc(str) {
  const d = document.createElement('div');
  d.appendChild(document.createTextNode(str || ''));
  return d.innerHTML;
}

let catalogCache = null;
let catalogCacheTime = 0;
const CACHE_TTL = 30000;

async function fetchCatalog(forceRefresh) {
  const now = Date.now();
  if (!forceRefresh && catalogCache && (now - catalogCacheTime) < CACHE_TTL) {
    return catalogCache;
  }
  const res = await fetch('/api/catalog');
  if (!res.ok) throw new Error('Repository catalog unavailable or invalid');
  catalogCache = await res.json();
  catalogCacheTime = now;
  allServicesData = catalogCache;
  return catalogCache;
}

// Restore the local presentation view on load. This is not authentication.
document.addEventListener('DOMContentLoaded', () => {
  const avatarEl = document.getElementById('user-avatar');
  const nameEl = document.getElementById('user-name');
  const roleEl = document.getElementById('user-role-badge');
  if (avatarEl) avatarEl.innerText = activeUserSession.avatar;
  if (nameEl) nameEl.innerText = activeUserSession.name;
  if (roleEl) roleEl.innerText = activeUserSession.role;
  refreshCatalog();
});

const infrastructureSources = {
  postgres: {
    title: 'PostgreSQL RDS',
    linkText: 'Open Template Reference',
    url: 'https://github.com/amr-elzoghby/Internal-Developer-Platform/tree/main/templates/backstage/infra-database',
    availability: 'Template reference available. Use a reviewed Git PR; this local catalog does not run Backstage templates.'
  },
  redis: {
    title: 'Redis ElastiCache',
    linkText: 'Open API Definition',
    url: 'https://github.com/amr-elzoghby/Internal-Developer-Platform/blob/main/infrastructure/crossplane/apis/definitions/redis-elasticache.yaml',
    availability: 'The API exists, but its reviewed Backstage Golden Path is not implemented yet.'
  },
  s3: {
    title: 'S3 Object Bucket',
    linkText: 'Open API Definition',
    url: 'https://github.com/amr-elzoghby/Internal-Developer-Platform/blob/main/infrastructure/crossplane/apis/definitions/s3-bucket.yaml',
    availability: 'The API exists, but its reviewed Backstage Golden Path is not implemented yet.'
  },
  ec2: {
    title: 'EC2 Server',
    linkText: 'Open API Definition',
    url: 'https://github.com/amr-elzoghby/Internal-Developer-Platform/blob/main/infrastructure/crossplane/apis/definitions/ec2-server.yaml',
    availability: 'The API exists, but its reviewed Backstage Golden Path is not implemented yet.'
  }
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

function openTeamViewModal() {
  document.getElementById('team-view-select').value = activeUserSession.team;
  document.getElementById('modal-team-view').classList.add('active');
}

function selectTeamView() {
  const team = document.getElementById('team-view-select').value;
  activeUserSession = teamViews[team] || teamViews['identity-platform'];
  localStorage.setItem('idp-team-view-v2', JSON.stringify(activeUserSession));

  document.getElementById('user-avatar').innerText = activeUserSession.avatar;
  document.getElementById('user-name').innerText = activeUserSession.name;
  document.getElementById('user-role-badge').innerText = activeUserSession.role;
  closeModal('modal-team-view');
}

async function refreshCatalog() {
  const tbody = document.getElementById('catalog-table');
  if (tbody && (!allServicesData || allServicesData.length === 0)) {
    tbody.innerHTML = [1, 2, 3].map(() => `
      <tr>
        <td colspan="7" style="padding: 16px;">
          <div class="skeleton-row"></div>
        </td>
      </tr>
    `).join('');
  }

  try {
    allServicesData = await fetchCatalog(true);
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
      if (s.claims.ec2) claims.push('<span class="badge badge-claim">🖥️ EC2 Server</span>');

      if (claims.length === 0) claims.push('<span class="text-no-claims">No Claims</span>');

      return `
        <tr>
          <td><strong>${esc(s.name)}</strong><br/><span class="text-dim-sm">${esc(s.path)}</span></td>
          <td><code>${esc(s.owner)}</code></td>
          <td>${esc(s.system || 'platform-services')}</td>
          <td><span class="badge badge-prod">${esc(s.lifecycle)}</span></td>
          <td>${claims.join(' ')}</td>
          <td><span style="color:var(--text-muted);">○ ${esc(s.status.argocd)}</span></td>
          <td>
            <button class="btn btn-secondary btn-inspect" data-service-id="${esc(s.id)}" onclick="inspectEntity(this.dataset.serviceId)">Single Pane View 🔍</button>
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
  const source = infrastructureSources[type];
  if (!source) return;
  document.getElementById('infra-title').innerText = `${source.title} API Contract`;
  const details = document.getElementById('infra-contract-details');
  details.replaceChildren();
  const status = document.createElement('p');
  status.innerText = source.availability;
  details.appendChild(status);

  const link = document.getElementById('infra-approved-link');
  link.href = source.url;
  link.innerText = source.linkText;

  try {
    const response = await fetch('/api/claims/specs');
    if (!response.ok) throw new Error('Unable to load claim specifications');
    const specs = await response.json();
    const spec = specs[type];
    if (spec && Array.isArray(spec.parameters)) {
      const heading = document.createElement('p');
      heading.innerHTML = '<strong>Approved parameters:</strong>';
      details.appendChild(heading);
      const list = document.createElement('ul');
      spec.parameters.forEach(parameter => {
        const item = document.createElement('li');
        item.innerText = `${parameter.label} (${parameter.name})`;
        list.appendChild(item);
      });
      details.appendChild(list);
    }
  } catch (e) {
    const warning = document.createElement('p');
    warning.innerText = 'The local API contract metadata is unavailable.';
    details.appendChild(warning);
  }

  document.getElementById('modal-infra').classList.add('active');
}

async function inspectEntity(name) {
  const services = await fetchCatalog();
  currentComponentData = services.find(x => x.id === name);
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
      <div class="info-panel">
        <p><strong>Kind:</strong> Component</p>
        <p><strong>Type:</strong> ${esc(c.type)}</p>
        <p><strong>Owner Team:</strong> <code>${esc(c.owner)}</code></p>
        <p><strong>System:</strong> ${esc(c.system || 'platform-services')}</p>
        <p><strong>Repository Path:</strong> <code>${esc(c.path)}</code></p>
        <p><strong>Backstage Spec:</strong> <code>${esc(c.path)}/catalog-info.yaml</code></p>
      </div>`;
  } else if (tab === 'cicd') {
    content.innerHTML = `
      <div class="info-panel">
        <p style="color:var(--text-muted);">🛡️ Trivy: ${esc(c.status.security)}</p>
        <p style="color:var(--text-muted);">📊 SonarQube: ${esc(c.status.sonarqube)}</p>
        <p style="color:var(--text-muted);">No pipeline result is reported without a live integration.</p>
      </div>`;
  } else if (tab === 'k8s') {
    content.innerHTML = `
      <div class="info-panel">
        <p style="color:var(--text-muted);">○ Pods: ${esc(c.status.pods)}</p>
        <p style="color:var(--text-muted);">○ Argo CD: ${esc(c.status.argocd)}</p>
        <hr style="border-color:var(--border-color); margin:12px 0;"/>
        <p><strong>CPU Usage:</strong> ${esc(c.status.cpuUsage || 'Unavailable')}</p>
        <p><strong>Memory Usage:</strong> ${esc(c.status.memoryUsage || 'Unavailable')}</p>
        <p><strong>Restarts:</strong> ${esc(c.status.restarts || 'Unavailable')}</p>
      </div>`;
  } else if (tab === 'claims') {
    let claimsList = c.infraFiles || [];
    content.innerHTML = `
      <div class="info-panel">
        <p style="font-weight:600; margin-bottom:12px;">Declared Crossplane Infrastructure Claims (${claimsList.length}):</p>
        ${claimsList.length > 0 
          ? claimsList.map(item => `<div class="claim-file-item">📄 ${esc(item)}</div>`).join('')
          : '<p style="color:var(--text-dim);">No infrastructure claim files were detected for this component.</p>'}
      </div>`;
  }
}

async function loadSinglePanePage() {
  const sel = document.getElementById('singlepane-select-service');
  if (!sel) return;
  sel.innerHTML = '';

  try {
    allServicesData = await fetchCatalog();

    if (!allServicesData || allServicesData.length === 0) {
      sel.innerHTML = '<option value="">No components found</option>';
      return;
    }

    allServicesData.forEach(s => {
      const opt = document.createElement('option');
      opt.value = s.id;
      opt.innerText = s.id;
      sel.appendChild(opt);
    });

    renderSinglePaneDashboard(allServicesData[0].id);
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
    allServicesData = await fetchCatalog();

    if (!allServicesData || allServicesData.length === 0) {
      sel.innerHTML = '<option value="">No components found</option>';
      return;
    }

    allServicesData.forEach(s => {
      const opt = document.createElement('option');
      opt.value = s.id;
      opt.innerText = s.id;
      sel.appendChild(opt);
    });

    renderTechDocs(allServicesData[0].id);
  } catch (e) {
    sel.innerHTML = '<option value="">⚠️ Failed to load services</option>';
    document.getElementById('techdocs-container').innerHTML = '<h3>⚠️ Connection Error</h3><p>Could not connect to the API server.</p>';
  }
}

function renderTechDocs(name) {
  const c = allServicesData.find(x => x.id === name);
  if (!c) return;

  const claimsList = c.infraFiles || [];
  const claimsText = claimsList.length > 0
    ? claimsList.map(item => `<code>${esc(item)}</code>`).join(', ')
    : 'No declared claims';

  document.getElementById('techdocs-container').innerHTML = `
    <h3>📚 ${esc(c.name)} — Repository Summary</h3>
    <p class="text-no-claims" style="margin-bottom:16px;">Source: <code>${esc(c.path)}/catalog-info.yaml</code> (Owner: <code>${esc(c.owner)}</code>)</p>
    <div class="techdocs-body">
      <h4>1. Service Overview</h4>
      <p>The <strong>${esc(c.name)}</strong> component is a <code>${esc(c.type)}</code> microservice owned by <code>${esc(c.owner)}</code> marked <code>${esc(c.lifecycle)}</code> in the catalog.</p>
      
      <h4>2. Declared Infrastructure & Environment Binding</h4>
      <p>Detected infrastructure files: ${claimsText}. This read-only catalog does not submit requests. Infrastructure requests require a reviewed pull request into the platform's watched claims path.</p>
      
      <h4>3. Operational Playbook</h4>
      <p>• <strong>Health Check:</strong> <code>${esc(c.healthCheck)}</code><br/>
         • <strong>Argo CD GitOps Sync:</strong> Deployments follow a reviewed digest promotion merged into the watched main branch<br/>
         • <strong>Rollback:</strong> Open a reviewed PR with <code>git revert &lt;promotion-commit&gt;</code>; Argo CD application <code>${esc(c.argoApplication)}</code> follows the merged main revision.</p>
    </div>
  `;
}

function renderSinglePaneDashboard(name) {
  const c = allServicesData.find(x => x.id === name);
  if (!c) return;

  const claimsList = c.infraFiles || [];
  const grid = document.getElementById('singlepane-grid');
  grid.innerHTML = `
    <div class="card">
      <h3>📁 Overview & Metadata</h3>
      <p><strong>Kind/Type:</strong> Component / ${esc(c.type)}<br/>
         <strong>Owner Team:</strong> ${esc(c.owner)}<br/>
         <strong>System:</strong> ${esc(c.system || 'platform-services')}<br/>
         <strong>Path:</strong> <code>${esc(c.path)}</code></p>
    </div>

    <div class="card">
      <h3>🛡️ Security & Quality Gate</h3>
      <p style="color:var(--text-muted);">○ Trivy: ${esc(c.status.security)}<br/>
         ○ SonarQube: ${esc(c.status.sonarqube)}<br/>
         ○ Pipeline: Live results are not connected</p>
    </div>

    <div class="card">
      <h3>☸️ K8s & GitOps Status</h3>
      <p style="color:var(--text-muted);">○ Pods: ${esc(c.status.pods)}<br/>
         ○ Argo CD: ${esc(c.status.argocd)}<br/>
         <strong>Metrics:</strong> CPU ${esc(c.status.cpuUsage || 'Unavailable')} | Memory ${esc(c.status.memoryUsage || 'Unavailable')}</p>
    </div>

    <div class="card">
      <h3>🗄️ Declared Claims (${claimsList.length})</h3>
      <div class="claims-list">
        ${claimsList.length > 0 ? claimsList.map(item => `<div>• 📄 ${esc(item)}</div>`).join('') : '<span class="text-no-claims">No Declared Claims</span>'}
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

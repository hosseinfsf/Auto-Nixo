// Nixo Lite Web Dashboard — vanilla JS
(function () {
  'use strict';

  // ---- Config ----
  var API_TOKEN = localStorage.getItem('nixo_api_token') || '';
  var API_BASE = window.location.origin;
  var REFRESH_MS = 3000;
  var refreshTimer = null;

  // ---- Helpers ----
  function apiFetch(path, opts) {
    opts = opts || {};
    opts.headers = opts.headers || {};
    opts.headers['Authorization'] = 'Bearer ' + API_TOKEN;
    if (opts.body && typeof opts.body === 'object') {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.body);
    }
    return fetch(API_BASE + path, opts).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    });
  }

  function el(id) { return document.getElementById(id); }

  function kvHtml(rows) {
    return rows.map(function (r) {
      return '<div class="row"><span class="key">' + r[0] + '</span>' +
             '<span class="value ' + (r[2] || '') + '">' + r[1] + '</span></div>';
    }).join('');
  }

  function fmt(n, digits) {
    if (n === null || n === undefined || isNaN(n)) return '—';
    return Number(n).toFixed(digits === undefined ? 2 : digits);
  }

  // ---- Status badges ----
  function updateBadges(status) {
    var bar = el('statusBar');
    if (!status) {
      bar.innerHTML = '<span class="badge badge-offline">Engine: Offline</span>';
      return;
    }
    var inputs = status.inputs || [];
    var anyOnline = inputs.some(function (i) { return i.status === 'online'; });
    var anyEnabled = inputs.some(function (i) { return i.enabled === 1; });
    bar.innerHTML =
      '<span class="badge badge-online">Engine: Online</span>' +
      '<span class="badge ' + (anyOnline ? 'badge-online' : 'badge-offline') + '">Telegram: ' +
        (anyOnline ? 'Online' : 'Offline') + '</span>' +
      '<span class="badge ' + (anyEnabled ? 'badge-online' : 'badge-warn') + '">Inputs: ' +
        (anyEnabled ? anyEnabled + ' active' : 'none') + '</span>';
  }

  // ---- Overview ----
  function loadOverview() {
    Promise.all([
      apiFetch('/status').catch(function () { return null; }),
      apiFetch('/inputs').catch(function () { return []; }),
      fetch('http://127.0.0.1:9125/api/listener/status').then(function(r){return r.json();}).catch(function(){return null;}),
      fetch('http://127.0.0.1:9125/api/queue/stats').then(function(r){return r.json();}).catch(function(){return null;}),
    ]).then(function (results) {
      var status = results[0] || {};
      var inputs = results[1] || [];
      updateBadges(status);

      el('accountInfo').innerHTML = kvHtml([
        ['Balance', fmt(status.balance), ''],
        ['Equity', fmt(status.equity), ''],
        ['Margin', fmt(status.margin), ''],
        ['Free Margin', fmt(status.free_margin), ''],
        ['Currency', status.currency || '—', ''],
      ]);

      var rStates = status.roulette_states || [];
      if (rStates.length === 0) {
        el('rouletteInfo').innerHTML = '<div class="value">No roulette state</div>';
      } else {
        el('rouletteInfo').innerHTML = kvHtml(
          rStates.map(function (s) {
            return [
              s.source_id,
              'step ' + s.step + ' / ' + s.max_step +
              (s.activated ? ' (active)' : ' (inactive)'),
              s.activated ? 'positive' : '',
            ];
          })
        );
      }

      var lastSig = status.last_signal;
      el('lastSignal').innerHTML = lastSig
        ? kvHtml([
            ['Symbol', lastSig.symbol || '—', ''],
            ['Side', lastSig.side || '—', ''],
            ['Time', lastSig.timestamp || '—', ''],
          ])
        : '<div class="value">No signals yet</div>';

      var lastOrd = status.last_order;
      el('lastOrder').innerHTML = lastOrd
        ? kvHtml([
            ['Symbol', lastOrd.symbol || '—', ''],
            ['Side', lastOrd.side || '—', ''],
            ['Lots', fmt(lastOrd.lots), ''],
            ['Status', lastOrd.status || '—', ''],
          ])
        : '<div class="value">No orders yet</div>';

      var openTrades = status.open_trades || [];
      el('openTrades').innerHTML = openTrades.length === 0
        ? '<div class="value">None</div>'
        : kvHtml(openTrades.map(function (t) {
            return [t.symbol + ' ' + t.side, fmt(t.lots) + ' lots', t.profit >= 0 ? 'positive' : 'negative'];
          }));

      var pl = status.today_pl;
      el('todayPL').innerHTML = pl === null || pl === undefined
        ? '<div class="value">—</div>'
        : '<div class="value ' + (pl >= 0 ? 'positive' : 'negative') + '">' + fmt(pl) + '</div>';
    }).catch(function (e) {
      console.error('overview', e);
    });
  }

  // ---- Telegram ----
  function loadTelegram() {
    apiFetch('/inputs').then(function (inputs) {
      var tg = inputs.filter(function (i) { return i.type === 'telegram'; });
      var html = tg.length === 0
        ? '<div class="value">No Telegram channels configured</div>'
        : '<table class="table"><tr><th>ID</th><th>Name</th><th>Status</th><th>Enabled</th><th></th></tr>' +
          tg.map(function (i) {
            return '<tr><td>' + i.id + '</td><td>' + (i.name || '') + '</td>' +
              '<td><span class="badge ' + (i.status === 'online' ? 'badge-online' : 'badge-offline') + '">' +
              (i.status || 'unknown') + '</span></td>' +
              '<td>' + (i.enabled === 1 ? 'Yes' : 'No') + '</td>' +
              '<td><button class="btn btn-danger" onclick="toggleInput(\'' + i.id + '\',' + (i.enabled === 1 ? 'false' : 'true') + ')">' +
              (i.enabled === 1 ? 'Disable' : 'Enable') + '</button></td></tr>';
          }).join('') + '</table>';
      el('channelList').innerHTML = html;
    }).catch(function (e) { console.error('telegram', e); });
  }

  window.toggleInput = function (id, enabled) {
    apiFetch('/inputs', { method: 'POST', body: { id: id, enabled: enabled } })
      .then(loadTelegram).catch(function (e) { alert('Failed: ' + e); });
  };

  window.addChannel = function () {
    var id = el('newChannelId').value.trim();
    if (!id) return;
    apiFetch('/inputs', {
      method: 'POST',
      body: { id: id, type: 'telegram', name: id, enabled: true },
    }).then(function () {
      el('newChannelId').value = '';
      loadTelegram();
    }).catch(function (e) { alert('Failed: ' + e); });
  };

  // ---- Proxy ----
  function loadProxy() {
    apiFetch('/telegram/proxy').then(function (p) {
      el('proxyEnabled').value = p.enabled ? 'true' : 'false';
      el('proxyMode').value = p.mode || 'disabled';
      el('proxyType').value = p.type || 'socks5';
      el('proxyHost').value = p.host || '';
      el('proxyPort').value = p.port || 10808;
      el('proxyUsername').value = p.username || '';
      el('proxyPassword').value = '';
      el('proxySecret').value = '';
      el('proxyRdns').value = p.rdns ? 'true' : 'false';
      el('proxyTimeout').value = p.connect_timeout_seconds || 10;
      el('proxyMaxRetries').value = p.max_retries || 3;
      el('proxyRetryDelay').value = p.retry_delay_seconds || 5;
      el('proxyDirectFallback').value = p.direct_fallback ? 'true' : 'false';

      el('proxyStatus').innerHTML = kvHtml([
        ['Mode', p.mode || 'disabled', ''],
        ['Type', p.type || '—', ''],
        ['Host', (p.host || '—') + ':' + (p.port || ''), ''],
        ['Remote DNS', p.rdns ? 'Enabled' : 'Disabled', ''],
        ['Direct Fallback', p.direct_fallback ? 'Enabled' : 'Disabled', ''],
      ]);
    }).catch(function (e) { console.error('proxy', e); });
  }

  window.saveProxy = function () {
    apiFetch('/telegram/proxy', {
      method: 'POST',
      body: {
        enabled: el('proxyEnabled').value === 'true',
        mode: el('proxyMode').value,
        type: el('proxyType').value,
        host: el('proxyHost').value,
        port: parseInt(el('proxyPort').value, 10),
        username: el('proxyUsername').value,
        password: el('proxyPassword').value,
        secret: el('proxySecret').value,
        rdns: el('proxyRdns').value === 'true',
        connect_timeout_seconds: parseInt(el('proxyTimeout').value, 10),
        max_retries: parseInt(el('proxyMaxRetries').value, 10),
        retry_delay_seconds: parseInt(el('proxyRetryDelay').value, 10),
        direct_fallback: el('proxyDirectFallback').value === 'true',
      },
    }).then(function (r) {
      if (r.ok === false) { alert('Validation: ' + (r.errors || r.error)); return; }
      loadProxy();
      alert('Saved');
    }).catch(function (e) { alert('Failed: ' + e); });
  };

  window.testProxy = function () {
    el('proxyTestResult').innerHTML = '<div class="value">Testing local listener...</div>';
    apiFetch('/telegram/proxy/test', { method: 'POST' }).then(function (r) {
      el('proxyTestResult').innerHTML =
        '<div class="value ' + (r.local_listener ? 'positive' : 'negative') + '">' +
        'Local listener: ' + (r.local_listener ? 'Reachable' : 'Unreachable') +
        (r.local_error ? ' (' + r.local_error + ')' : '') + '</div>' +
        '<div class="value ' + (r.telegram_proxy ? 'positive' : 'negative') + '">' +
        'Telegram proxy: ' + (r.telegram_proxy ? 'OK' : 'Failed') +
        (r.telegram_proxy_error ? ' (' + r.telegram_proxy_error + ')' : '') + '</div>';
    }).catch(function (e) {
      el('proxyTestResult').innerHTML = '<div class="value negative">Failed: ' + e + '</div>';
    });
  };

  window.testTelegramProxy = function () {
    el('proxyTestResult').innerHTML = '<div class="value">Testing Telegram connection...</div>';
    apiFetch('/telegram/proxy/test', { method: 'POST' }).then(function (r) {
      el('proxyTestResult').innerHTML =
        '<div class="value ' + (r.telegram_proxy ? 'positive' : 'negative') + '">' +
        'Telegram connection: ' + (r.telegram_proxy ? 'Connected' : 'Failed') +
        (r.telegram_proxy_error ? ' (' + r.telegram_proxy_error + ')' : '') + '</div>';
    }).catch(function (e) {
      el('proxyTestResult').innerHTML = '<div class="value negative">Failed: ' + e + '</div>';
    });
  };

  // ---- Roulette ----
  function loadRoulette() {
    apiFetch('/roulette').then(function (r) {
      el('rouletteEnabled').value = r.enabled ? 'true' : 'false';
      el('rouletteBaseRisk').value = r.base_risk_pct;
      el('rouletteMaxRisk').value = r.max_risk_pct;
      el('rouletteTriggerPct').value = r.trigger_pct;
      el('rouletteMaxSteps').value = r.max_steps;

      var states = r.states || [];
      el('rouletteStateList').innerHTML = states.length === 0
        ? '<div class="value">No per-source state</div>'
        : '<table class="table"><tr><th>Source</th><th>Model</th><th>Step</th><th>Max</th><th>Active</th></tr>' +
          states.map(function (s) {
            return '<tr><td>' + s.source_id + '</td><td>' + s.model + '</td>' +
              '<td>' + s.step + '</td><td>' + s.max_step + '</td>' +
              '<td>' + (s.activated ? 'Yes' : 'No') + '</td></tr>';
          }).join('') + '</table>';
    }).catch(function (e) {
      el('rouletteStateList').innerHTML = '<div class="value">Unable to load roulette</div>';
      console.error('roulette', e);
    });
  }

  window.saveRoulette = function () {
    apiFetch('/roulette', {
      method: 'POST',
      body: {
        enabled: el('rouletteEnabled').value === 'true',
        base_risk_pct: parseFloat(el('rouletteBaseRisk').value),
        max_risk_pct: parseFloat(el('rouletteMaxRisk').value),
        trigger_pct: parseFloat(el('rouletteTriggerPct').value),
        max_steps: parseInt(el('rouletteMaxSteps').value, 10),
      },
    }).then(loadRoulette).catch(function (e) { alert('Failed: ' + e); });
  };

  // ---- MT5 ----
  function loadMt5() {
    apiFetch('/mt5').then(function (m) {
      el('mt5Path').value = m.terminal_path || '';
      el('mt5Account').value = m.account || '';
      el('mt5Server').value = m.server || '';
      el('mt5DryRun').value = m.dry_run ? 'true' : 'false';
    }).catch(function (e) { console.error('mt5', e); });
  }

  window.testMt5 = function () {
    el('mt5TestResult').innerHTML = '<div class="value">Testing...</div>';
    apiFetch('/mt5/test', { method: 'POST' }).then(function (r) {
      el('mt5TestResult').innerHTML = '<div class="value ' + (r.ok ? 'positive' : 'negative') + '">' +
        (r.ok ? 'Connected' : 'Failed: ' + (r.error || 'unknown')) + '</div>';
    }).catch(function (e) {
      el('mt5TestResult').innerHTML = '<div class="value negative">Failed: ' + e + '</div>';
    });
  };

  window.saveMt5 = function () {
    apiFetch('/mt5', {
      method: 'POST',
      body: {
        terminal_path: el('mt5Path').value,
        account: el('mt5Account').value,
        server: el('mt5Server').value,
        dry_run: el('mt5DryRun').value === 'true',
      },
    }).then(loadMt5).catch(function (e) { alert('Failed: ' + e); });
  };

  // ---- Activity ----
  function loadActivity() {
    apiFetch('/activity?limit=50').then(function (rows) {
      el('activityList').innerHTML = rows.length === 0
        ? '<div class="value">No activity</div>'
        : rows.map(function (r) {
            var d = new Date(r.ts * 1000).toLocaleString();
            return '<div class="log-entry ' + r.level + '">[' + d + '] ' +
              r.level.toUpperCase() + ': ' + r.message + '</div>';
          }).join('');
    }).catch(function (e) { console.error('activity', e); });
  }

  // ---- Navigation ----
  function switchPage(name) {
    document.querySelectorAll('.page').forEach(function (p) { p.classList.add('hidden'); });
    document.querySelectorAll('.nav-btn').forEach(function (b) { b.classList.remove('active'); });
    var page = el('page-' + name);
    if (page) page.classList.remove('hidden');
    var btn = document.querySelector('.nav-btn[data-page="' + name + '"]');
    if (btn) btn.classList.add('active');
  }

  document.querySelectorAll('.nav-btn').forEach(function (btn) {
    btn.addEventListener('click', function () { switchPage(btn.dataset.page); });
  });

  // ---- Token prompt ----
  if (!API_TOKEN) {
    var t = prompt('Enter API token (set in engine_config.json):');
    if (t) { API_TOKEN = t; localStorage.setItem('nixo_api_token', t); }
  }

  // ---- Refresh loop ----
  function refresh() {
    var active = document.querySelector('.page:not(.hidden)');
    if (!active) return;
    var page = active.dataset.page;
    if (page === 'overview') loadOverview();
    else if (page === 'telegram') loadTelegram();
    else if (page === 'proxy') loadProxy();
    else if (page === 'roulette') loadRoulette();
    else if (page === 'mt5') loadMt5();
    else if (page === 'activity') loadActivity();
    else if (page === 'listener') { refreshStatus(); loadProxies(); loadQueue(); }
  }


  // ---- Listener Manager ----
  var LISTENER_API = 'http://127.0.0.1:9125';

  function listenerFetch(path, opts) {
    opts = opts || {};
    return fetch(LISTENER_API + path, opts).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    });
  }

  window.startListener = function () {
    listenerFetch('/api/listener/start', { method: 'POST' })
      .then(function (d) { alert(d.message || 'Started'); refreshStatus(); })
      .catch(function (e) { alert('Error: ' + e); });
  };

  window.stopListener = function () {
    listenerFetch('/api/listener/stop', { method: 'POST' })
      .then(function (d) { alert(d.message || 'Stopped'); refreshStatus(); })
      .catch(function (e) { alert('Error: ' + e); });
  };

  window.refreshStatus = function () {
    listenerFetch('/api/listener/status')
      .then(function (d) {
        var badge = document.querySelector('#listenerStatus .badge');
        if (d.running) {
          badge.className = 'badge badge-online';
          badge.textContent = 'Status: Running (PID ' + d.pid + ')';
        } else {
          badge.className = 'badge badge-offline';
          badge.textContent = 'Status: Stopped';
        }
        if (d.log) {
          var logEl = document.getElementById('listenerLog');
          if (logEl) logEl.textContent = d.log;
        }
      })
      .catch(function () {
        var badge = document.querySelector('#listenerStatus .badge');
        if (badge) { badge.className = 'badge badge-offline'; badge.textContent = 'Status: Unknown'; }
      });
  };

  window.addProxy = function () {
    var type = document.getElementById('proxyType').value.trim();
    var host = document.getElementById('proxyHost').value.trim();
    var port = parseInt(document.getElementById('proxyPort').value, 10);
    var secret = document.getElementById('proxySecret').value.trim();
    if (!type || !host || !port) { alert('Type, host, and port are required'); return; }
    listenerFetch('/api/proxy/add', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: type, host: host, port: port, secret: secret || null })
    })
      .then(function (d) { alert(d.message || 'Added'); loadProxies(); })
      .catch(function (e) { alert('Error: ' + e); });
  };

  function loadProxies() {
    listenerFetch('/api/proxy/list')
      .then(function (d) {
        var tbody = document.getElementById('proxyTableBody');
        if (!d.proxies || d.proxies.length === 0) {
          tbody.innerHTML = '<tr><td colspan="7">No proxies configured</td></tr>';
          return;
        }
        tbody.innerHTML = d.proxies.map(function (p) {
          return '<tr>' +
            '<td>' + p.type + '</td>' +
            '<td>' + p.host + '</td>' +
            '<td>' + p.port + '</td>' +
            '<td><span class="badge ' + (p.status === 'active' ? 'badge-online' : 'badge-offline') + '">' + p.status + '</span></td>' +
            '<td>' + (p.latency_ms ? p.latency_ms + ' ms' : '-') + '</td>' +
            '<td>' + p.fail_count + '</td>' +
            '<td><button class="btn btn-test" onclick="testProxy(\'' + p.type + '\',\'' + p.host + '\',' + p.port + ')">Test</button> ' +
            '<button class="btn btn-stop" onclick="removeProxy(\'' + p.type + '\',\'' + p.host + '\',' + p.port + ')">Remove</button></td>' +
            '</tr>';
        }).join('');
      })
      .catch(function () {
        var tbody = document.getElementById('proxyTableBody');
        if (tbody) tbody.innerHTML = '<tr><td colspan="7">Error loading proxies</td></tr>';
      });
  }

  window.testProxy = function (type, host, port) {
    listenerFetch('/api/proxy/test', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: type, host: host, port: port })
    })
      .then(function (d) {
        alert('Test result: ' + (d.ok ? 'OK (' + d.latency + 'ms)' : 'FAILED: ' + d.error));
        loadProxies();
      })
      .catch(function (e) { alert('Error: ' + e); });
  };

  window.removeProxy = function (type, host, port) {
    if (!confirm('Remove proxy ' + host + ':' + port + '?')) return;
    listenerFetch('/api/proxy/remove', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: type, host: host, port: port })
    })
      .then(function (d) { alert(d.message || 'Removed'); loadProxies(); })
      .catch(function (e) { alert('Error: ' + e); });
  };

  function loadQueue() {
    listenerFetch('/api/queue/stats')
      .then(function (d) {
        var el;
        el = document.getElementById('qTotal'); if (el) el.textContent = d.total || 0;
        el = document.getElementById('qPending'); if (el) el.textContent = d.pending || 0;
        el = document.getElementById('qProcessed'); if (el) el.textContent = d.processed || 0;
        el = document.getElementById('qFailed'); if (el) el.textContent = d.failed || 0;
      })
      .catch(function () {});
    listenerFetch('/api/queue/recent')
      .then(function (d) {
        var tbody = document.getElementById('queueTableBody');
        if (!tbody) return;
        if (!d.rows || d.rows.length === 0) {
          tbody.innerHTML = '<tr><td colspan="6">No messages yet</td></tr>';
          return;
        }
        tbody.innerHTML = d.rows.map(function (r) {
          return '<tr>' +
            '<td>' + r.chat_id + '</td>' +
            '<td>' + r.message_id + '</td>' +
            '<td>' + r.edit_version + '</td>' +
            '<td>' + r.update_type + '</td>' +
            '<td><span class="badge ' + (r.state === 'pending' ? 'badge-warn' : (r.state === 'processed' ? 'badge-online' : 'badge-offline')) + '">' + r.state + '</span></td>' +
            '<td>' + r.date_utc + '</td>' +
            '</tr>';
        }).join('');
      })
      .catch(function () {
        var tbody = document.getElementById('queueTableBody');
        if (tbody) tbody.innerHTML = '<tr><td colspan="6">Error loading queue</td></tr>';
      });
  }


  refreshTimer = setInterval(refresh, REFRESH_MS);
  refresh();
})();
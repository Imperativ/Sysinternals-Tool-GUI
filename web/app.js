(() => {
  'use strict';

  const csrf = document.querySelector('meta[name="slg-csrf"]').content;
  const el = {
    agent: document.getElementById('agent-status'),
    search: document.getElementById('search'),
    category: document.getElementById('category'),
    clear: document.getElementById('clear-filter'),
    count: document.getElementById('result-count'),
    grid: document.getElementById('tool-grid'),
    loading: document.getElementById('catalog-loading'),
    dialog: document.getElementById('tool-dialog'),
    detail: document.getElementById('tool-detail'),
    template: document.getElementById('tool-card-template')
  };
  const state = { catalog: null, selectedId: null, detail: null, preview: null, runPoll: null };

  const statusLabels = {
    'ready-local': 'lokal startbar',
    'ready-live': 'über Live startbar',
    'download-available': 'Download verfügbar',
    'catalog-only-pending-review': 'Ausführung noch nicht geprüft',
    'unsupported-platform': 'nicht auf Windows ausführbar',
    'not-available': 'momentan nicht verfügbar'
  };

  const executionLabels = {
    enabled: 'Ausführung manifestiert',
    review: 'Ausführung noch nicht geprüft',
    unsupported: 'nicht auf Windows'
  };

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (options.body !== undefined) {
      headers.set('Content-Type', 'application/json');
      headers.set('X-SLG-CSRF', csrf);
    }
    const response = await fetch(path, { ...options, headers, cache: 'no-store' });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(payload?.error?.message || `HTTP ${response.status}`);
    }
    return payload;
  }

  function make(tag, options = {}) {
    const node = document.createElement(tag);
    if (options.className) node.className = options.className;
    if (options.text !== undefined) node.textContent = options.text;
    if (options.type) node.type = options.type;
    if (options.href) { node.href = options.href; node.target = '_blank'; node.rel = 'noopener noreferrer'; }
    if (options.value !== undefined) node.value = options.value;
    if (options.disabled !== undefined) node.disabled = options.disabled;
    if (options.title) node.title = options.title;
    return node;
  }

  function addChip(container, text) { container.append(make('span', { className: 'chip', text })); }

  function setAgent(text, mode = 'pending') {
    el.agent.replaceChildren();
    el.agent.append(make('span', { className: `status-dot ${mode}` }), document.createTextNode(text));
  }

  function formatExecution(tool) {
    if (!tool.platforms.includes('Windows')) return { className: 'unsupported', text: executionLabels.unsupported };
    if (tool.execution.enabled) return { className: 'ready', text: executionLabels.enabled };
    return { className: 'review', text: executionLabels.review };
  }

  function renderCatalog() {
    el.grid.replaceChildren();
    const tools = state.catalog?.tools || [];
    el.count.textContent = `${tools.length} Tool${tools.length === 1 ? '' : 's'} im aktuellen Filter`;
    if (!tools.length) {
      el.grid.append(make('p', { className: 'empty-state', text: 'Keine Tools entsprechen der aktuellen Suche oder Kategorie.' }));
      return;
    }
    for (const tool of tools) {
      const fragment = el.template.content.cloneNode(true);
      const card = fragment.querySelector('.tool-card');
      fragment.querySelector('h3').textContent = tool.name;
      fragment.querySelector('.version').textContent = `v${tool.version}`;
      fragment.querySelector('.description').textContent = tool.description;
      const badge = fragment.querySelector('.execution-badge');
      const exec = formatExecution(tool);
      badge.classList.add(exec.className);
      badge.textContent = exec.text;
      const categories = fragment.querySelector('.categories');
      tool.categories.forEach(category => addChip(categories, category));
      const button = fragment.querySelector('button');
      button.addEventListener('click', () => openTool(tool.id));
      card.dataset.toolId = tool.id;
      el.grid.append(fragment);
    }
  }

  async function loadCatalog() {
    const params = new URLSearchParams();
    if (el.search.value.trim()) params.set('q', el.search.value.trim());
    if (el.category.value) params.set('category', el.category.value);
    el.loading.hidden = false;
    try {
      const data = await api(`/api/v1/tools${params.size ? `?${params}` : ''}`);
      state.catalog = data;
      if (el.category.options.length === 1) {
        data.categories.forEach(category => el.category.append(new Option(category, category)));
      }
      renderCatalog();
    } catch (error) {
      el.grid.replaceChildren(make('p', { className: 'empty-state', text: `Katalogfehler: ${error.message}` }));
      el.count.textContent = 'Katalog nicht verfügbar';
    } finally {
      el.loading.hidden = true;
    }
  }

  function availabilityEvidence(availability) {
    const list = make('dl', { className: 'evidence' });
    const add = (label, content) => { list.append(make('dt', { text: label }), make('dd', { text: content })); };
    add('Host', `${availability.architecture} · ${new Date(availability.checkedAt).toLocaleString('de-DE')}`);
    if (availability.local?.found) {
      const signature = availability.local.signature || {};
      add('Lokal', `${availability.local.source}: ${availability.local.path}`);
      add('Signatur', `${signature.status || 'unbekannt'}${signature.subject ? ` · ${signature.subject}` : ''}`);
    } else add('Lokal', 'Kein erlaubter lokaler Fundort mit passendem Artefakt erkannt.');
    if (availability.live?.checked) add('Live-UNC', availability.live.available ? availability.live.path : availability.live.reason);
    else add('Live-UNC', availability.live?.reason || 'Nicht geprüft.');
    if (availability.download?.available) add('Download', 'Offizieller Microsoft-Link ist hinterlegt.');
    return list;
  }

  function riskCopy(risks) {
    const names = {
      'read-only': 'liest System- oder Metadaten',
      'collects-sensitive-data': 'kann sensible Daten erfassen',
      'changes-process-state': 'kann Prozesszustände verändern',
      'changes-system-state': 'kann Systemzustände verändern',
      'persistent-service-driver': 'kann Dienst oder Treiber persistent einrichten',
      'destructive': 'kann Daten oder Systemzustand irreversibel verändern',
      'remote-execution': 'kann Prozesse remote ausführen'
    };
    return risks.map(risk => names[risk] || risk).join('; ');
  }

  function buildRunArea(container, tool) {
    const panel = make('section', { className: 'detail-panel run-panel' });
    const heading = make('div', { className: 'run-header' });
    heading.append(make('h3', { text: 'Ausführung' }));
    const runMeta = make('span', { className: 'run-meta', text: 'Noch kein Lauf gestartet.' });
    heading.append(runMeta);
    const output = make('pre', { className: 'run-output', text: 'Konsolenausgabe erscheint hier nur für CLI-Tools. Native GUI-Tools öffnen ein separates Windows-Fenster.' });
    panel.append(heading, output);
    container.append(panel);
    return { panel, runMeta, output };
  }

  function setOutput(runArea, run) {
    runArea.runMeta.textContent = `PID ${run.pid} · ${run.status}${run.exitCode !== null ? ` · Exit ${run.exitCode}` : ''}`;
    runArea.output.replaceChildren();
    if (run.kind === 'gui') {
      runArea.output.append(make('span', { className: 'output-note', text: run.status === 'native-window-started' ? 'Das native GUI wurde im Benutzerdesktop gestartet. Die Interaktion erfolgt im geöffneten Toolfenster.' : `Native GUI-Lauf: ${run.status}.` }));
      return;
    }
    if (!run.events?.length) {
      runArea.output.append(make('span', { className: 'output-note', text: run.status === 'running' ? 'Warte auf Konsolenausgabe…' : 'Keine Konsolenausgabe.' }));
      return;
    }
    for (const event of run.events) {
      const line = make('span', { className: event.stream === 'stderr' ? 'output-err' : '', text: `[${new Date(event.at).toLocaleTimeString('de-DE')}] ${event.text}\n` });
      runArea.output.append(line);
    }
    runArea.output.scrollTop = runArea.output.scrollHeight;
  }

  function clearRunPoll() {
    if (state.runPoll) { clearInterval(state.runPoll); state.runPoll = null; }
  }

  function beginRunPoll(runArea, runId) {
    clearRunPoll();
    const refresh = async () => {
      try {
        const run = await api(`/api/v1/runs/${runId}`);
        setOutput(runArea, run);
        if (!['running', 'native-window-started'].includes(run.status)) clearRunPoll();
      } catch (error) {
        clearRunPoll();
        runArea.runMeta.textContent = `Laufstatus nicht verfügbar: ${error.message}`;
      }
    };
    refresh();
    state.runPoll = setInterval(refresh, 900);
  }

  function createActionPanel(detail, tool, availability) {
    const panel = make('section', { className: 'detail-panel' });
    panel.append(make('h3', { text: 'Prüfen und starten' }));
    const help = make('a', { className: 'help-link', text: 'Offizielle Microsoft-Dokumentation öffnen', href: tool.docUrl });
    panel.append(help);

    if (!tool.execution.enabled) {
      panel.append(make('p', { text: tool.execution.reason }));
      return panel;
    }
    if (availability.overall === 'catalog-only-pending-review' || availability.overall === 'unsupported-platform') {
      panel.append(make('p', { text: availability.explanation }));
      return panel;
    }

    const form = make('div', { className: 'run-form' });
    const sourceGroup = make('div', { className: 'source-options' });
    let source = availability.local?.found && availability.local.signature?.valid ? 'local' : availability.live?.available ? 'live' : null;
    const addSource = (mode, label, enabled) => {
      const button = make('button', { type: 'button', className: `button ${source === mode ? 'primary' : 'secondary'}`, text: label, disabled: !enabled });
      button.dataset.source = mode;
      button.addEventListener('click', () => {
        if (!enabled) return;
        source = mode;
        sourceGroup.querySelectorAll('button').forEach(item => { item.className = `button ${item.dataset.source === mode ? 'primary' : 'secondary'}`; });
      });
      sourceGroup.append(button);
    };
    addSource('local', 'Lokal starten', Boolean(availability.local?.found && availability.local.signature?.valid));
    addSource('live', 'Über Live starten', Boolean(availability.live?.available));
    form.append(sourceGroup);

    if (!source) {
      form.append(make('p', { text: 'Es ist momentan keine startfähige lokale oder Live-Quelle vorhanden.' }));
      if (availability.download?.available) {
        const download = make('button', { type: 'button', className: 'button secondary', text: 'Offiziellen Microsoft-Download öffnen' });
        download.addEventListener('click', async () => {
          try { await api(`/api/v1/tools/${tool.id}/download:open`, { method: 'POST', body: '{}' }); download.textContent = 'Download im Browser geöffnet'; }
          catch (error) { alert(`Download-Link konnte nicht geöffnet werden: ${error.message}`); }
        });
        form.append(download);
      }
      panel.append(form);
      return panel;
    }

    const argsLabel = make('label', { className: 'field-label' });
    argsLabel.append(document.createTextNode('Argumenttokens — ein Argument pro Zeile'));
    const args = make('textarea', { value: '' });
    args.placeholder = 'Beispiel: -n\nnotepad.exe\n\nKein cmd.exe oder PowerShell: jeder Eintrag wird als einzelnes Argument übergeben.';
    args.setAttribute('spellcheck', 'false');
    argsLabel.append(args);
    form.append(argsLabel);
    form.append(make('p', { className: 'run-meta', text: 'Der Agent startet nur den manifestierten Pfad. Leere Zeilen werden ignoriert; es gibt keine Shell-Auswertung.' }));

    if (tool.execution.risks?.length && tool.execution.risks[0] !== 'read-only') {
      form.append(make('div', { className: 'warning-block', text: `Wirkungsklasse: ${riskCopy(tool.execution.risks)}. Die konkrete Bestätigung wird nach der Vorschau verlangt.` }));
    }
    const previewButton = make('button', { type: 'button', className: 'button primary', text: 'Ausführungsvorschau erzeugen' });
    const previewBox = make('section', { className: 'preview-box' });
    form.append(previewButton, previewBox);

    previewButton.addEventListener('click', async () => {
      previewBox.replaceChildren();
      previewBox.classList.remove('visible');
      const tokens = args.value.split(/\r?\n/).filter(token => token.length > 0);
      previewButton.disabled = true;
      previewButton.textContent = 'Vorschau wird geprüft…';
      try {
        const preview = await api('/api/v1/invocations:preview', { method: 'POST', body: JSON.stringify({ toolId: tool.id, sourceMode: source, args: tokens }) });
        state.preview = preview;
        renderPreview(previewBox, preview, tool, detail.runArea);
        previewBox.classList.add('visible');
      } catch (error) {
        previewBox.append(make('div', { className: 'warning-block', text: `Vorschau abgelehnt: ${error.message}` }));
        previewBox.classList.add('visible');
      } finally {
        previewButton.disabled = false;
        previewButton.textContent = 'Ausführungsvorschau erzeugen';
      }
    });

    panel.append(form);
    return panel;
  }

  function renderPreview(box, preview, tool, runArea) {
    box.append(make('strong', { text: 'Geprüfte Vorschau — gültig für 5 Minuten' }));
    const command = make('pre', { className: 'command-preview', text: `${preview.executablePath}\n${preview.argv.map(token => JSON.stringify(token)).join('\n') || '(ohne Argumente)'}` });
    box.append(command);
    box.append(make('p', { text: `Quelle: ${preview.sourceMode === 'local' ? 'lokal' : 'Sysinternals Live'} · Wirkung: ${riskCopy(preview.risk.classes)}` }));
    let phraseInput = null;
    let eulaCheck = null;
    if (preview.risk.requiresConfirmation) {
      const confirmation = make('div', { className: 'confirmation' });
      confirmation.append(make('label', { text: `Diese Ausführung kann folgende Wirkung haben: ${riskCopy(preview.risk.classes)}. Gib exakt „${preview.risk.confirmationPhrase}“ ein.` }));
      phraseInput = make('input');
      phraseInput.placeholder = preview.risk.confirmationPhrase;
      phraseInput.autocomplete = 'off';
      confirmation.append(phraseInput);
      box.append(confirmation);
    }
    if (preview.risk.eulaExplicitlyRequested) {
      const confirmation = make('div', { className: 'confirmation' });
      const label = make('label');
      eulaCheck = make('input', { type: 'checkbox' });
      label.append(eulaCheck, document.createTextNode(' Ich habe bewusst „-accepteula“ als Toolparameter gewählt. Der Agent akzeptiert keine EULA automatisch.'));
      confirmation.append(label);
      box.append(confirmation);
    }
    if (preview.risk.sensitiveOutput) box.append(make('p', { className: 'warning-block', text: 'Das Tool kann sensible Daten ausgeben oder erfassen. Die Agent-Ausgabe bleibt nur im Arbeitsspeicher und wird nicht standardmäßig gespeichert.' }));
    const start = make('button', { type: 'button', className: preview.risk.requiresConfirmation ? 'button danger' : 'button primary', text: preview.tool.kind === 'gui' ? 'Native GUI starten' : 'CLI-Lauf starten' });
    start.addEventListener('click', async () => {
      start.disabled = true;
      try {
        const run = await api('/api/v1/invocations:start', { method: 'POST', body: JSON.stringify({ previewId: preview.previewId, confirmationPhrase: phraseInput?.value || '', acceptEula: Boolean(eulaCheck?.checked) }) });
        setOutput(runArea, run);
        beginRunPoll(runArea, run.id);
        start.textContent = 'Lauf gestartet';
      } catch (error) {
        start.disabled = false;
        alert(`Start abgelehnt: ${error.message}`);
      }
    });
    box.append(start);
  }

  function renderDetail(tool) {
    el.detail.replaceChildren();
    const title = make('div', { className: 'detail-title-row' });
    const titleText = make('div');
    titleText.append(make('h2', { text: tool.name }), make('p', { className: 'detail-subtitle', text: `v${tool.version} · ${tool.platforms.join(', ')}` }));
    const badge = make('span', { className: `status-overall status-${tool.availability.overall}`, text: statusLabels[tool.availability.overall] || tool.availability.overall });
    title.append(titleText, badge);
    el.detail.append(title);

    const body = make('div', { className: 'detail-body' });
    const overview = make('section', { className: 'detail-panel' });
    overview.append(make('h3', { text: 'Einordnung' }), make('p', { text: tool.description }));
    const chips = make('div', { className: 'chip-row' });
    tool.categories.forEach(category => addChip(chips, category));
    if (tool.legacy) addChip(chips, 'Legacy / Live-Verzeichnis');
    overview.append(chips);
    body.append(overview);

    const availability = make('section', { className: 'detail-panel status-card' });
    availability.append(make('h3', { text: 'Verfügbarkeit auf diesem Host' }), make('span', { className: `status-overall status-${tool.availability.overall}`, text: statusLabels[tool.availability.overall] || tool.availability.overall }), make('p', { text: tool.availability.explanation }), availabilityEvidence(tool.availability));
    const refresh = make('button', { type: 'button', className: 'button secondary', text: 'Status neu prüfen' });
    refresh.addEventListener('click', () => openTool(tool.id));
    availability.append(refresh);
    body.append(availability);

    const detail = { runArea: buildRunArea(body, tool) };
    const action = createActionPanel(detail, tool, tool.availability);
    body.insertBefore(action, detail.runArea.panel);
    el.detail.append(body);
  }

  async function openTool(toolId) {
    clearRunPoll();
    state.selectedId = toolId;
    el.detail.replaceChildren(make('p', { text: 'Verfügbarkeit wird für diesen Host geprüft…' }));
    if (!el.dialog.open) el.dialog.showModal();
    try {
      const tool = await api(`/api/v1/tools/${toolId}`);
      if (state.selectedId !== toolId) return;
      state.detail = tool;
      renderDetail(tool);
    } catch (error) {
      el.detail.replaceChildren(make('div', { className: 'warning-block', text: `Toolstatus konnte nicht geladen werden: ${error.message}` }));
    }
  }

  function debounce(callback, delay = 220) {
    let timer;
    return (...args) => { clearTimeout(timer); timer = setTimeout(() => callback(...args), delay); };
  }

  async function boot() {
    try {
      const health = await api('/api/v1/health');
      setAgent(`Agent bereit · ${health.architecture} · Katalog ${health.catalogRevision}`, 'ok');
    } catch (error) {
      setAgent(`Agentfehler: ${error.message}`, 'error');
    }
    await loadCatalog();
  }

  el.search.addEventListener('input', debounce(loadCatalog));
  el.category.addEventListener('change', loadCatalog);
  el.clear.addEventListener('click', () => { el.search.value = ''; el.category.value = ''; loadCatalog(); });
  el.dialog.addEventListener('close', () => { clearRunPoll(); state.selectedId = null; state.preview = null; });
  boot();
})();

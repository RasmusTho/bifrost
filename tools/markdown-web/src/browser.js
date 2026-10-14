// Browser entry for the Bifrost note page (WKWebView). Exposes
// `window.BifrostMarkdown` to the Swift host and reports link taps back
// through `webkit.messageHandlers.bifrost`.

import DOMPurify from 'dompurify';
import { renderHTML, scan } from './renderer.js';

const MERMAID_URL = 'mermaid.min.js'; // relative to index.html (ygg://app/MarkdownWeb/)
let mermaidLoading = null;
let renderSerial = 0;

function post(message) {
  try { window.webkit?.messageHandlers?.bifrost?.postMessage(message); } catch { /* not hosted */ }
}

function sanitize(html) {
  return DOMPurify.sanitize(html, {
    USE_PROFILES: { html: true, mathMl: true, svg: true },
    ADD_TAGS: ['details', 'summary', 'figure', 'figcaption', 'audio', 'video', 'section'],
    ADD_ATTR: ['open', 'controls', 'playsinline', 'preload', 'loading', 'target'],
    ALLOWED_URI_REGEXP: /^(?:ygg:|https?:|mailto:|#)/i,
    FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'textarea', 'select', 'button'],
  });
}

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function mermaidTheme() {
  const shell = document.documentElement.dataset.theme === 'light';
  return {
    theme: 'base',
    themeVariables: {
      darkMode: !shell,
      background: 'transparent',
      fontFamily: cssVar('--font-ui') || 'system-ui',
      fontSize: '14px',
      primaryColor: shell ? 'rgba(255,255,255,0.72)' : cssVar('--bg-raised'),
      primaryTextColor: cssVar('--fg-1'),
      primaryBorderColor: shell ? cssVar('--cyan') : cssVar('--cyan-dim'),
      secondaryColor: shell ? cssVar('--agent-muted') : cssVar('--bg-overlay'),
      tertiaryColor: shell ? cssVar('--accent-muted') : cssVar('--bg-surface'),
      lineColor: cssVar('--fg-2'),
      textColor: cssVar('--fg-1'),
      mainBkg: shell ? 'rgba(255,255,255,0.72)' : cssVar('--bg-raised'),
      nodeBorder: shell ? cssVar('--cyan') : cssVar('--cyan-dim'),
      clusterBkg: shell ? 'rgba(255,255,255,0.4)' : cssVar('--bg-surface'),
      noteBkgColor: shell ? cssVar('--accent-muted') : cssVar('--accent-muted'),
      noteTextColor: cssVar('--fg-1'),
      actorBkg: shell ? 'rgba(255,255,255,0.72)' : cssVar('--bg-raised'),
      actorBorder: cssVar('--cyan'),
      signalColor: cssVar('--fg-2'),
      labelBoxBkgColor: shell ? 'rgba(255,255,255,0.72)' : cssVar('--bg-raised'),
      pie1: cssVar('--cyan-dim'), pie2: cssVar('--accent-dim'), pie3: cssVar('--agent-dim'),
      pie4: cssVar('--vault-dim'), pie5: cssVar('--amber-dim'), pie6: cssVar('--destructive-dim'),
      pieStrokeColor: 'transparent',
      pieTitleTextColor: cssVar('--fg-1'),
      pieLegendTextColor: cssVar('--fg-1'),
      pieSectionTextColor: cssVar('--fg-1'),
      gridColor: cssVar('--border'),
      sectionBkgColor: cssVar('--bg-surface'),
      altSectionBkgColor: cssVar('--bg-raised'),
      taskBkgColor: cssVar('--cyan-dim'),
      activeTaskBkgColor: cssVar('--accent-dim'),
      doneTaskBkgColor: cssVar('--vault-dim'),
      taskTextColor: shell ? cssVar('--fg-1') : cssVar('--fg-inverse'),
      // Mindmap / timeline scales: muted role fills with ink labels.
      ...Object.fromEntries(['cyan', 'agent', 'accent', 'vault', 'amber', 'destructive'].flatMap((role, i) => [
        [`cScale${i}`, shell ? cssVar(`--${role}-muted`) : cssVar(`--${role}-muted`)],
        [`cScale${i + 6}`, shell ? cssVar(`--${role}-muted`) : cssVar(`--${role}-muted`)],
        [`cScaleLabel${i}`, cssVar('--fg-1')],
        [`cScaleLabel${i + 6}`, cssVar('--fg-1')],
        [`cScalePeer${i}`, cssVar(`--${role}`)],
      ])),
    },
  };
}

function loadMermaid() {
  if (window.mermaid) return Promise.resolve(window.mermaid);
  mermaidLoading ||= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = MERMAID_URL;
    script.onload = () => resolve(window.mermaid);
    script.onerror = () => reject(new Error('Mermaid runtime unavailable'));
    document.head.appendChild(script);
  });
  return mermaidLoading;
}

function failMermaid(figure, source, message) {
  figure.className = 'vault-mermaid-block failed-embed failed-embed--mermaid';
  figure.dataset.mermaidState = 'failed';
  figure.dataset.testid = 'failed-embed';
  figure.innerHTML = '<div class="failed-embed-main"><span class="failed-embed-tag">MERMAID</span>'
    + '<span class="failed-embed-message"></span></div>'
    + '<details class="vault-mermaid-source"><summary>Source</summary>'
    + '<pre class="vault-code-block vault-mermaid-source-code"><code></code></pre></details>';
  figure.querySelector('.failed-embed-message').textContent = message;
  figure.querySelector('code').textContent = source;
}

async function renderMermaid(root, serial) {
  const figures = [...root.querySelectorAll('figure.vault-mermaid-block[data-mermaid-state="pending"]')];
  if (!figures.length) return;
  let mermaid;
  try {
    mermaid = await loadMermaid();
  } catch (error) {
    figures.forEach(f => failMermaid(f, f.textContent, error.message));
    return;
  }
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', ...mermaidTheme() });
  for (let i = 0; i < figures.length; i += 1) {
    if (serial !== renderSerial) return;
    const figure = figures[i];
    const source = figure.querySelector('code')?.textContent ?? '';
    try {
      const { svg } = await mermaid.render(`ygg-mermaid-${serial}-${i}`, source);
      if (serial !== renderSerial) return;
      figure.dataset.mermaidState = 'rendered';
      figure.innerHTML = `<div class="vault-mermaid-rendered" data-testid="vault-mermaid-rendered">${svg}</div>`;
    } catch (error) {
      failMermaid(figure, source, String(error?.message || error).split('\n')[0]);
      document.getElementById(`dygg-mermaid-${serial}-${i}`)?.remove();
    }
  }
}

function render(payload) {
  renderSerial += 1;
  const serial = renderSerial;
  if (payload.theme) document.documentElement.dataset.theme = payload.theme === 'light' ? 'light' : 'dark';
  const root = document.getElementById('note');
  root.innerHTML = sanitize(renderHTML(payload));
  root.querySelectorAll('a[href^="http"]').forEach(a => a.setAttribute('rel', 'noopener'));
  // DOMPurify's profiles drop `type`; task boxes are the only inputs we emit.
  root.querySelectorAll('li.task-list-item > input').forEach(box => { box.type = 'checkbox'; box.disabled = true; });
  renderMermaid(root, serial).finally(() => {
    if (serial === renderSerial) post({ type: 'rendered' });
  });
  if (payload.anchor) scrollToAnchor(payload.anchor);
  return true;
}

function scrollToAnchor(anchor) {
  const el = document.getElementById(anchor) || document.getElementById(decodeURIComponent(anchor));
  el?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

document.addEventListener('click', event => {
  const link = event.target.closest('a[href]');
  if (!link) return;
  const href = link.getAttribute('href');
  event.preventDefault();
  if (href.startsWith('#')) { scrollToAnchor(href.slice(1)); return; }
  if (href.startsWith('ygg://note/')) {
    const hash = href.indexOf('#');
    post({
      type: 'openNote',
      path: link.dataset.yggPath || '',
      anchor: hash >= 0 ? decodeURIComponent(href.slice(hash + 1)) : null,
    });
    return;
  }
  if (href.startsWith('ygg://vault/')) {
    post({ type: 'openAsset', path: link.dataset.yggPath || '' });
    return;
  }
  post({ type: 'openExternal', url: href });
});

window.BifrostMarkdown = {
  scan: markdown => scan(markdown),
  render,
  setTheme(theme) {
    document.documentElement.dataset.theme = theme === 'light' ? 'light' : 'dark';
    // Mermaid bakes colours into SVG; ask the host to re-render.
    if (document.querySelector('.vault-mermaid-rendered')) post({ type: 'themeChanged' });
  },
};
window.addEventListener('error', event => post({ type: 'error', message: String(event.message || event.error) }));
window.addEventListener('unhandledrejection', event => post({ type: 'error', message: String(event.reason?.message || event.reason) }));
post({ type: 'ready' });

// Bifrost note renderer: Obsidian-flavoured Markdown -> HTML.
//
// Pure module (no DOM), so it runs in the app's WKWebView and under
// `node --test`. Markup and class names follow the web Companion renderer
// (agentic-pkm-mvp companion_ui/renderer/*) so the shared stylesheet and the
// web's visual grammar carry over.
//
// Vault access is never done here. The host (Swift) asks `scan()` for the link
// and embed targets, resolves them on demand against the vault, and passes the
// answers back in `payload.resolved` / `payload.embedded`.

import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import mark from 'markdown-it-mark';
import texmath from 'markdown-it-texmath';
import katex from 'katex';
import hljs from 'highlight.js/lib/common';
import yaml from 'js-yaml';

const IMAGE_EXT = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'avif', 'heic', 'tif', 'tiff']);
const AUDIO_EXT = new Set(['mp3', 'wav', 'm4a', 'ogg', 'flac', 'aac', 'webm']);
const VIDEO_EXT = new Set(['mp4', 'mov', 'm4v', 'ogv']);

const CALLOUT_ALIASES = {
  note: 'note', abstract: 'abstract', summary: 'abstract', tldr: 'abstract',
  info: 'info', todo: 'todo', tip: 'tip', hint: 'tip', important: 'tip',
  success: 'success', check: 'success', done: 'success',
  question: 'question', help: 'question', faq: 'question',
  warning: 'warning', caution: 'warning', attention: 'warning',
  failure: 'failure', fail: 'failure', missing: 'failure',
  danger: 'danger', error: 'danger', bug: 'bug', example: 'example',
  quote: 'quote', cite: 'quote',
};
const CALLOUT_ICONS = {
  abstract: 'A', bug: 'B', danger: '!', example: 'E', failure: 'X', info: 'i', note: 'N',
  question: '?', quote: '"', success: '+', tip: '*', todo: 'T', warning: '!',
};

const CALLOUT_HEADER_RE = /^\s{0,3}>\s?\[!([^\]\s]+)\]([+-]?)[ \t]*(.*)$/;
const FENCE_RE = /^\s{0,3}(```+|~~~+)/;

export function escapeHTML(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

export function slugify(text) {
  return String(text).trim().toLowerCase()
    .replace(/<[^>]+>/g, '')
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .replace(/\s+/g, '-');
}

function extensionOf(target) {
  const base = target.split('/').pop();
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
}

function encodePath(path) {
  return path.split('/').map(encodeURIComponent).join('/');
}

export function vaultAssetURL(path) {
  return `ygg://vault/${encodePath(path)}`;
}

export function noteURL(path, anchor) {
  return `ygg://note/${encodePath(path)}${anchor ? `#${encodeURIComponent(anchor)}` : ''}`;
}

/** Splits `target#sub|alias` (Obsidian link syntax). */
export function parseLinkTarget(raw) {
  let target = raw;
  let alias = null;
  const pipe = target.indexOf('|');
  if (pipe >= 0) {
    alias = target.slice(pipe + 1).trim();
    target = target.slice(0, pipe);
  }
  let sub = null;
  const hash = target.indexOf('#');
  if (hash >= 0) {
    sub = target.slice(hash + 1).trim();
    target = target.slice(0, hash);
  }
  target = target.trim();
  if (!sub && target.startsWith('^')) {
    // `[[^block-id]]`: a block in the current note.
    sub = target;
    target = '';
  }
  return { target, sub, alias };
}

// ---------------------------------------------------------------- source pass

/** Strips YAML frontmatter. Returns { body, properties, invalid }. */
export function splitFrontmatter(source) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(source);
  if (!match) return { body: source, properties: null, invalid: false };
  const body = source.slice(match[0].length);
  try {
    const value = yaml.load(match[1], { schema: yaml.JSON_SCHEMA });
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return { body, properties: value, invalid: false };
    }
    return { body, properties: null, invalid: match[1].trim().length > 0 };
  } catch {
    return { body, properties: null, invalid: true, raw: match[1] };
  }
}

/** Splits markdown into alternating prose / fenced-code segments. */
function segments(source) {
  const lines = source.split('\n');
  const out = [];
  let buffer = [];
  let fence = null;
  for (const line of lines) {
    const m = FENCE_RE.exec(line);
    if (fence) {
      buffer.push(line);
      const closing = /^\s{0,3}(`{3,}|~{3,})\s*$/.exec(line);
      if (closing && closing[1][0] === fence[0] && closing[1].length >= fence.length) {
        out.push({ code: true, text: buffer.join('\n') });
        buffer = [];
        fence = null;
      }
      continue;
    }
    if (m) {
      if (buffer.length) out.push({ code: false, text: buffer.join('\n') });
      buffer = [line];
      fence = m[1];
      continue;
    }
    buffer.push(line);
  }
  if (buffer.length) out.push({ code: Boolean(fence), text: buffer.join('\n') });
  return out;
}

/** Removes Obsidian `%% comments %%` outside code. */
export function stripComments(source) {
  return segments(source)
    .map(s => (s.code ? s.text : s.text.replace(/%%[\s\S]*?%%/g, '')))
    .join('\n');
}

const LINK_RE = /(!?)\[\[([^\]\n]+?)\]\]/g;
const MD_IMAGE_RE = /!\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g;
const MD_LINK_RE = /(^|[^!])\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g;

function isExternal(target) {
  return /^[a-z][a-z0-9+.-]*:/i.test(target);
}

/** The resolution for `target` as written in the note at `env.notePath`. */
function lookup(env, target) {
  return env.resolvedBySource?.[env.notePath]?.[target] ?? env.resolved?.[target];
}

/** Link and embed targets the host must resolve. */
export function scan(source) {
  const { body } = splitFrontmatter(String(source ?? ''));
  const links = new Set();
  const embeds = new Set();
  for (const seg of segments(stripComments(body))) {
    if (seg.code) continue;
    const text = seg.text.replace(/`[^`\n]*`/g, '');
    for (const m of text.matchAll(LINK_RE)) {
      const { target } = parseLinkTarget(m[2]);
      if (!target) continue;
      (m[1] ? embeds : links).add(target);
    }
    for (const m of text.matchAll(MD_IMAGE_RE)) {
      const target = decodeURI(m[1]);
      if (!isExternal(target)) embeds.add(target);
    }
    for (const m of text.matchAll(MD_LINK_RE)) {
      const href = m[2];
      if (isExternal(href) || href.startsWith('#')) continue;
      let target = href.split('#')[0];
      try { target = decodeURI(target); } catch { /* keep as written */ }
      if (target) links.add(target);
    }
  }
  return { links: [...links], embeds: [...embeds] };
}

// ------------------------------------------------------------- markdown-it

function highlight(code, lang) {
  if (lang && hljs.getLanguage(lang)) {
    try {
      return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
    } catch { /* fall through */ }
  }
  return escapeHTML(code);
}

function wikilinkPlugin(md) {
  md.inline.ruler.before('link', 'obsidian_wikilink', (state, silent) => {
    const src = state.src;
    let pos = state.pos;
    const isEmbed = src.charCodeAt(pos) === 0x21 /* ! */;
    if (isEmbed) pos += 1;
    if (src.charCodeAt(pos) !== 0x5b || src.charCodeAt(pos + 1) !== 0x5b) return false;
    const close = src.indexOf(']]', pos + 2);
    if (close < 0) return false;
    const inner = src.slice(pos + 2, close);
    if (!inner || inner.includes('\n') || inner.includes('[[')) return false;
    if (!silent) {
      const token = state.push(isEmbed ? 'obsidian_embed' : 'obsidian_wikilink', '', 0);
      token.meta = parseLinkTarget(inner);
      token.content = inner;
    }
    state.pos = close + 2;
    return true;
  });

  md.renderer.rules.obsidian_wikilink = (tokens, idx, _opts, env) => {
    const { target, sub, alias } = tokens[idx].meta;
    const label = escapeHTML(alias || (target ? (sub ? `${target} › ${sub.replace(/^\^/, '')}` : target) : (sub || '').replace(/^\^/, '')));
    if (!target) {
      return `<a class="vault-wikilink" href="#${escapeHTML(anchorFor(sub))}">${label}</a>`;
    }
    const resolved = lookup(env, target);
    if (!resolved) {
      return `<span class="vault-wikilink vault-wikilink-diagnostic" data-testid="missing-link" title="Note not found: ${escapeHTML(target)}">${label}</span>`;
    }
    const href = resolved.kind === 'asset' ? vaultAssetURL(resolved.path) : noteURL(resolved.path, sub ? anchorFor(sub) : null);
    return `<a class="vault-wikilink" href="${escapeHTML(href)}" data-ygg-path="${escapeHTML(resolved.path)}">${label}</a>`;
  };

  md.renderer.rules.obsidian_embed = (tokens, idx, _opts, env) => renderEmbed(md, tokens[idx].meta, env);
}

function anchorFor(sub) {
  if (!sub) return '';
  return sub.startsWith('^') ? sub.slice(1) : slugify(sub);
}

function sizeHint(alias) {
  if (!alias) return '';
  const m = /^(\d+)(?:x(\d+))?$/.exec(alias.trim());
  if (!m) return '';
  return ` width="${m[1]}"${m[2] ? ` height="${m[2]}"` : ''}`;
}

function failedEmbed(kind, message, target) {
  return `<figure class="failed-embed failed-embed--${escapeHTML(kind)}" data-testid="failed-embed" data-kind="${escapeHTML(kind)}">`
    + `<div class="failed-embed-main"><span class="failed-embed-tag">${escapeHTML(kind.toUpperCase())}</span>`
    + `<span class="failed-embed-message">${escapeHTML(message)}${target ? ` · ${escapeHTML(target)}` : ''}</span></div></figure>`;
}

function renderEmbed(md, meta, env) {
  const { target, sub, alias } = meta;
  if (!target) return '';
  const ext = extensionOf(target);
  const resolved = lookup(env, target);
  if (!resolved) {
    if (IMAGE_EXT.has(ext)) {
      return '<figure class="vault-asset-diagnostic missing-image" data-testid="missing-image">'
        + '<div class="missing-image-box"><span class="missing-image-icon" aria-hidden="true"></span>'
        + `<span class="missing-image-caption">Image not found · ${escapeHTML(target)}</span></div></figure>`;
    }
    return failedEmbed(ext || 'note', 'Not found in this vault', target);
  }
  const url = vaultAssetURL(resolved.path);
  const rext = extensionOf(resolved.path);
  if (IMAGE_EXT.has(rext)) {
    const alt = alias && !/^\d+(x\d+)?$/.test(alias) ? alias : target;
    return `<img class="vault-image" src="${escapeHTML(url)}" alt="${escapeHTML(alt)}"${sizeHint(alias)} loading="lazy">`;
  }
  if (AUDIO_EXT.has(rext)) return `<audio class="vault-audio" controls preload="metadata" src="${escapeHTML(url)}"></audio>`;
  if (VIDEO_EXT.has(rext)) return `<video class="vault-video" controls playsinline preload="metadata" src="${escapeHTML(url)}"></video>`;
  if (rext === 'pdf') {
    return `<a class="vault-file-chip" href="${escapeHTML(url)}" data-ygg-path="${escapeHTML(resolved.path)}">`
      + `<span class="vault-file-chip-tag">PDF</span>${escapeHTML(alias || target)}${sub ? ` · ${escapeHTML(sub)}` : ''}</a>`;
  }
  if (rext === 'md' || rext === '') {
    const depth = env.embedDepth || 0;
    const content = env.embedded?.[resolved.path];
    if (content == null || depth >= 2) {
      return failedEmbed('note', depth >= 2 ? 'Embed depth limit reached' : 'Could not read note', target);
    }
    let body = splitFrontmatter(content).body;
    if (sub) body = extractSection(body, sub);
    if (body == null) return failedEmbed('note', `Section not found: ${sub}`, target);
    const inner = renderBody(md, body, childEnv(env, { embedDepth: depth + 1, notePath: resolved.path }));
    const title = escapeHTML(target + (sub ? ` › ${sub.replace(/^\^/, '')}` : ''));
    return `<section class="vault-embed" data-testid="vault-embed" data-ygg-path="${escapeHTML(resolved.path)}">`
      + `<a class="vault-embed-title" href="${escapeHTML(noteURL(resolved.path, sub ? anchorFor(sub) : null))}" data-ygg-path="${escapeHTML(resolved.path)}">${title}</a>`
      + `<div class="vault-embed-body">${inner}</div></section>`;
  }
  return `<a class="vault-file-chip" href="${escapeHTML(url)}" data-ygg-path="${escapeHTML(resolved.path)}">`
    + `<span class="vault-file-chip-tag">${escapeHTML((rext || 'file').toUpperCase())}</span>${escapeHTML(alias || target)}</a>`;
}

/** Heading section (`Heading`) or block (`^id`) of a note body. */
export function extractSection(body, sub) {
  const lines = body.split('\n');
  if (sub.startsWith('^')) {
    const id = sub.slice(1);
    const re = new RegExp(`\\s\\^${id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`);
    const i = lines.findIndex(l => re.test(l));
    if (i < 0) return null;
    let start = i;
    while (start > 0 && lines[start - 1].trim() !== '') start -= 1;
    return lines.slice(start, i + 1).join('\n').replace(re, '');
  }
  const wanted = slugify(sub);
  let start = -1;
  let level = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const m = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(lines[i]);
    if (!m) continue;
    if (start < 0 && slugify(m[2]) === wanted) { start = i; level = m[1].length; continue; }
    if (start >= 0 && m[1].length <= level) return lines.slice(start, i).join('\n');
  }
  return start < 0 ? null : lines.slice(start).join('\n');
}

function tagPlugin(md) {
  md.inline.ruler.after('emphasis', 'obsidian_tag', (state, silent) => {
    const src = state.src;
    const pos = state.pos;
    if (src.charCodeAt(pos) !== 0x23 /* # */) return false;
    const prev = pos > 0 ? src[pos - 1] : ' ';
    if (!/\s|[(,]/.test(prev)) return false;
    const m = /^#([\p{L}\p{N}_/-]+)/u.exec(src.slice(pos));
    if (!m || /^\d+$/.test(m[1])) return false;
    if (!silent) {
      const token = state.push('obsidian_tag', '', 0);
      token.content = m[1];
    }
    state.pos += m[0].length;
    return true;
  });
  md.renderer.rules.obsidian_tag = (tokens, idx) => `<span class="vault-tag" data-tag="${escapeHTML(tokens[idx].content)}">#${escapeHTML(tokens[idx].content)}</span>`;
}

/** Task list items with the web's markup (read-only checkboxes). */
function taskPlugin(md) {
  md.core.ruler.after('inline', 'obsidian_tasks', state => {
    const tokens = state.tokens;
    for (let i = 2; i < tokens.length; i += 1) {
      const inline = tokens[i];
      if (inline.type !== 'inline' || tokens[i - 1].type !== 'paragraph_open' || tokens[i - 2].type !== 'list_item_open') continue;
      const m = /^\[([ xX/\-><?!*])\]\s+/.exec(inline.content);
      if (!m) continue;
      const first = inline.children[0];
      if (!first || first.type !== 'text' || !/^\[[^\]]\]/.test(first.content)) continue;
      first.content = first.content.replace(/^\[[^\]]\]\s*/, '');
      const li = tokens[i - 2];
      li.attrJoin('class', 'task-list-item');
      li.attrSet('data-task-state', m[1]);
      const box = new state.Token('html_inline', '', 0);
      box.content = `<input type="checkbox" disabled${m[1] !== ' ' ? ' checked' : ''}> `;
      inline.children.unshift(box);
      for (let j = i - 3; j >= 0; j -= 1) {
        if ((tokens[j].type === 'bullet_list_open' || tokens[j].type === 'ordered_list_open') && tokens[j].level === li.level - 1) {
          if (!(tokens[j].attrGet('class') || '').includes('task-list')) tokens[j].attrJoin('class', 'task-list');
          break;
        }
      }
    }
  });
}

/** Heading ids and Obsidian `^block-id` anchors. */
function anchorPlugin(md) {
  md.core.ruler.after('inline', 'obsidian_anchors', state => {
    const seen = new Map();
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i += 1) {
      const t = tokens[i];
      if (t.type === 'heading_open') {
        let slug = slugify(tokens[i + 1].content);
        const n = seen.get(slug) || 0;
        seen.set(slug, n + 1);
        if (n) slug = `${slug}-${n}`;
        t.attrSet('id', slug);
      }
      if (t.type === 'inline' && /\s\^([A-Za-z0-9-]+)\s*$/.test(t.content)) {
        const id = /\s\^([A-Za-z0-9-]+)\s*$/.exec(t.content)[1];
        const last = t.children[t.children.length - 1];
        if (last && last.type === 'text') last.content = last.content.replace(/\s\^[A-Za-z0-9-]+\s*$/, '');
        const open = tokens[i - 1];
        if (open && open.type.endsWith('_open')) open.attrSet('id', id);
      }
    }
  });
}

function fenceRenderer(md) {
  md.renderer.rules.fence = (tokens, idx) => {
    const token = tokens[idx];
    const lang = (token.info || '').trim().split(/\s+/)[0].toLowerCase();
    const source = token.content.replace(/\n$/, '');
    if (lang === 'mermaid') {
      return '<figure class="vault-mermaid-block" data-testid="vault-mermaid-block" data-mermaid-state="pending">'
        + `<pre class="vault-mermaid" data-testid="vault-mermaid"><code class="language-mermaid">${escapeHTML(source)}</code></pre></figure>`;
    }
    const langAttr = lang ? ` data-language="${escapeHTML(lang)}"` : '';
    const cls = lang ? ` class="hljs language-${escapeHTML(lang)}"` : ' class="hljs"';
    return `<pre class="vault-code-block"${langAttr}><code${cls}>${highlight(source, lang)}</code></pre>`;
  };
}

function tableWrapper(md) {
  const open = md.renderer.rules.table_open || ((t, i, o, e, s) => s.renderToken(t, i, o));
  const close = md.renderer.rules.table_close || ((t, i, o, e, s) => s.renderToken(t, i, o));
  md.renderer.rules.table_open = (...args) => `<div class="vault-table-scroll">${open(...args)}`;
  md.renderer.rules.table_close = (...args) => `${close(...args)}</div>`;
}

function linkTargets(md) {
  const fallback = md.renderer.rules.link_open || ((t, i, o, e, s) => s.renderToken(t, i, o));
  md.renderer.rules.link_open = (tokens, idx, opts, env, self) => {
    const token = tokens[idx];
    const href = token.attrGet('href') || '';
    if (/^https?:/i.test(href)) token.attrJoin('class', 'vault-external-link');
    else if (!/^[a-z][a-z0-9+.-]*:/i.test(href) && !href.startsWith('#')) {
      // Relative markdown link to a vault note or file.
      const target = decodeURI(href.split('#')[0]);
      const resolved = lookup(env, target);
      if (resolved) {
        const anchor = href.includes('#') ? href.split('#')[1] : null;
        token.attrSet('href', resolved.kind === 'asset' ? vaultAssetURL(resolved.path) : noteURL(resolved.path, anchor));
        token.attrSet('data-ygg-path', resolved.path);
        token.attrJoin('class', 'vault-wikilink');
      }
    }
    return fallback(tokens, idx, opts, env, self);
  };
  const image = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, idx, opts, env, self) => {
    const token = tokens[idx];
    const src = token.attrGet('src') || '';
    if (/^https?:/i.test(src)) {
      // Remote images are not loaded (privacy; matches the web asset policy).
      return '<figure class="vault-asset-diagnostic missing-image" data-testid="remote-image">'
        + '<div class="missing-image-box"><span class="missing-image-icon" aria-hidden="true"></span>'
        + `<span class="missing-image-caption">Remote image not loaded · <a class="vault-external-link" href="${escapeHTML(src)}">open</a></span></div></figure>`;
    }
    if (!/^[a-z][a-z0-9+.-]*:/i.test(src)) {
      const resolved = lookup(env, decodeURI(src));
      if (!resolved) return renderEmbed(md, { target: decodeURI(src), sub: null, alias: null }, env);
      token.attrSet('src', vaultAssetURL(resolved.path));
      token.attrJoin('class', 'vault-image');
    }
    return image(tokens, idx, opts, env, self);
  };
}

export function createMarkdown() {
  const md = new MarkdownIt({ html: true, linkify: true, breaks: true, typographer: false });
  md.use(footnote).use(mark).use(texmath, { engine: katex, delimiters: 'dollars', katexOptions: { throwOnError: false, output: 'htmlAndMathml' } });
  md.use(wikilinkPlugin).use(tagPlugin).use(taskPlugin).use(anchorPlugin).use(fenceRenderer).use(tableWrapper).use(linkTargets);
  md.linkify.set({ fuzzyLink: false, fuzzyEmail: false });
  return md;
}

/** A nested render's env: shares resolution data, not footnote state. */
function childEnv(env, extra = {}) {
  const { footnotes: _footnotes, ...rest } = env;
  return { ...rest, ...extra };
}

// ---------------------------------------------------------------- callouts

/** Renders a body, with Obsidian callouts handled at line level like the web. */
function renderBody(md, body, env) {
  const blocks = [];
  const out = [];
  for (const seg of segments(stripComments(body))) {
    if (seg.code) { out.push(seg.text); continue; }
    const lines = seg.text.split('\n');
    for (let i = 0; i < lines.length; i += 1) {
      const header = CALLOUT_HEADER_RE.exec(lines[i]);
      if (!header) { out.push(lines[i]); continue; }
      const body = [];
      let j = i + 1;
      while (j < lines.length && /^\s{0,3}>/.test(lines[j])) {
        body.push(lines[j].replace(/^\s{0,3}>\s?/, ''));
        j += 1;
      }
      blocks.push(renderCallout(md, header, body.join('\n'), env));
      out.push('', `<!--ygg-block-${blocks.length - 1}-->`, '');
      i = j - 1;
    }
  }
  let html = md.render(out.join('\n'), env);
  html = html.replace(/<!--ygg-block-(\d+)-->/g, (_, n) => blocks[Number(n)]);
  return html;
}

function renderCallout(md, header, bodyMarkdown, env) {
  const rawType = header[1].toLowerCase();
  const visual = CALLOUT_ALIASES[rawType] || 'note';
  const fold = header[2];
  const title = header[3].trim() || rawType.replace(/[-_]/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
  const titleHTML = md.renderInline(title, env);
  const icon = `<span class="vault-callout-icon" aria-hidden="true">${escapeHTML(CALLOUT_ICONS[visual] || 'N')}</span>`;
  const head = `${icon}<span class="vault-callout-title">${titleHTML}</span>`;
  const bodyHTML = bodyMarkdown.trim() ? `<div class="vault-callout-body">${renderBody(md, bodyMarkdown, childEnv(env))}</div>` : '';
  const cls = `vault-callout vault-callout--${escapeHTML(visual)}`;
  const attrs = `class="${cls}" data-callout="${escapeHTML(rawType)}" data-testid="vault-callout"`;
  if (fold) {
    return `<details ${attrs}${fold === '+' ? ' open' : ''}><summary class="vault-callout-header">${head}</summary>${bodyHTML}</details>`;
  }
  return `<div ${attrs}><div class="vault-callout-header">${head}</div>${bodyHTML}</div>`;
}

// ------------------------------------------------------------- properties

function propertyValue(value) {
  if (Array.isArray(value)) return value.map(propertyValue).join('');
  if (value && typeof value === 'object') return `<span class="vault-property-value">${escapeHTML(JSON.stringify(value))}</span>`;
  return `<span class="vault-property-value">${escapeHTML(value)}</span>`;
}

export function renderProperties(properties, invalid) {
  if (invalid) {
    return '<section class="vault-properties vault-properties-invalid" data-testid="vault-properties">'
      + '<div class="vault-properties-header"><span class="vault-properties-label">Properties</span></div>'
      + '<p class="vault-properties-diagnostics">Frontmatter could not be read as YAML.</p></section>';
  }
  if (!properties || !Object.keys(properties).length) return '';
  const rows = Object.entries(properties).map(([key, value]) => {
    let dd;
    if (key === 'tags' || key === 'tag') {
      const tags = Array.isArray(value) ? value : String(value).split(/[,\s]+/).filter(Boolean);
      dd = tags.map(t => `<span class="vault-property-tag">#${escapeHTML(String(t).replace(/^#/, ''))}</span>`).join('');
    } else {
      dd = propertyValue(value);
    }
    return `<div class="vault-property"><dt>${escapeHTML(key)}</dt><dd>${dd}</dd></div>`;
  }).join('');
  return '<section class="vault-properties" data-testid="vault-properties">'
    + '<div class="vault-properties-header"><span class="vault-properties-label">Properties</span></div>'
    + `<dl class="vault-properties-list">${rows}</dl></section>`;
}

// -------------------------------------------------------------------- API

let shared;

/** Full note -> HTML string (unsanitised; the browser entry sanitises). */
export function renderHTML(payload) {
  shared ||= createMarkdown();
  const source = String(payload?.markdown ?? '');
  const { body, properties, invalid } = splitFrontmatter(source);
  const env = {
    resolved: payload?.resolved || {},
    resolvedBySource: payload?.resolvedBySource || {},
    embedded: payload?.embedded || {},
    notePath: payload?.notePath || '',
    embedDepth: 0,
  };
  const props = payload?.showProperties === false ? '' : renderProperties(properties, invalid);
  return `${props}<article class="vault-markdown-rendered" data-renderer="bifrost-markdown">${renderBody(shared, body, env)}</article>`;
}

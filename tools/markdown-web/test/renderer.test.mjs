// node --test test/  — renderer behaviour against the web Companion's
// obsidian-renderer fixtures (copied in test/fixtures) and the UAT test note.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { renderHTML, scan, extractSection, splitFrontmatter } from '../src/renderer.js';

const fx = name => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');

test('frontmatter becomes properties and never reaches the body', () => {
  const html = renderHTML({ markdown: fx('frontmatter-properties.md') });
  assert.match(html, /class="vault-properties"/);
  assert.match(html, /<span class="vault-property-tag">#alpha<\/span>/);
  assert.match(html, /<dt>status<\/dt>/);
  const article = html.slice(html.indexOf('<article'));
  assert.doesNotMatch(article, /custom_field/);
  assert.match(article, /Body text that must NOT include/);
});

test('invalid frontmatter is reported, not rendered as body', () => {
  const { invalid } = splitFrontmatter('---\nkey: [unclosed\n---\nbody');
  assert.equal(invalid, true);
  assert.match(renderHTML({ markdown: '---\nkey: [unclosed\n---\nbody' }), /could not be read/);
});

test('callouts: types, titles, folding, nesting, inline markdown', () => {
  const html = renderHTML({ markdown: fx('callouts.md'), resolved: { WikiLink: { path: 'WikiLink.md', kind: 'note' } } });
  assert.match(html, /vault-callout vault-callout--note/);
  assert.match(html, /vault-callout--warning[^>]*>.*Custom Title Here/s);
  assert.match(html, /<details class="vault-callout vault-callout--tip"[^>]*>(?!.*open)/);
  assert.match(html, /<details class="vault-callout vault-callout--question"[^>]* open>/);
  assert.match(html, /data-callout="custom-type"/);
  assert.match(html, /vault-callout--note" data-callout="custom-type"/);
  assert.match(html, /<strong>bold<\/strong>/);
  assert.match(html, /data-ygg-path="WikiLink.md"/);
  // nested callout renders inside the outer body
  const info = html.slice(html.indexOf('data-callout="info"'));
  assert.match(info, /vault-callout-body.*vault-callout vault-callout--note/s);
});

test('wikilinks: resolved, alias, heading, block, local, missing', () => {
  const resolved = { ExistingNote: { path: 'Notes/ExistingNote.md', kind: 'note' } };
  const html = renderHTML({ markdown: fx('wikilinks.md'), resolved });
  assert.match(html, /href="ygg:\/\/note\/Notes\/ExistingNote\.md"[^>]*>ExistingNote</);
  assert.match(html, />Display Alias</);
  assert.match(html, /ExistingNote\.md#section-header/);
  assert.match(html, /ExistingNote\.md#abc123/);
  assert.match(html, /href="#local-section"/);
  assert.match(html, /href="#local-block-id"/);
  assert.match(html, /vault-wikilink-diagnostic[^>]*title="Note not found: NonExistentNote12345"/);
  assert.match(html, /id="local-block-id"/);
  assert.doesNotMatch(html, /\^local-block-id/);
});

test('comments are hidden; unsafe html is left for the browser sanitizer', () => {
  const html = renderHTML({ markdown: fx('comments-and-html.md') });
  assert.doesNotMatch(html, /should be hidden/);
  assert.doesNotMatch(html, /Multi-word inline comment/);
  assert.match(html, /still visible text after comment/);
});

test('embeds: images with size hints, media, pdf, notes, sections, missing', () => {
  const resolved = {
    'test-image.png': { path: 'assets/test-image.png', kind: 'asset' },
    SomeNote: { path: 'SomeNote.md', kind: 'note' },
    'document.pdf': { path: 'docs/document.pdf', kind: 'asset' },
    'audio.mp3': { path: 'a/audio.mp3', kind: 'asset' },
    'video.mp4': { path: 'a/video.mp4', kind: 'asset' },
  };
  const embedded = { 'SomeNote.md': '# SomeNote\nIntro\n## Heading\nUnder heading\nblock text ^blockid\n## Other\nNope' };
  const html = renderHTML({ markdown: fx('embeds-images.md'), resolved, embedded });
  assert.match(html, /<img class="vault-image" src="ygg:\/\/vault\/assets\/test-image\.png"/);
  assert.match(html, /width="100" height="145"/);
  assert.match(html, /<audio class="vault-audio"/);
  assert.match(html, /<video class="vault-video"/);
  assert.match(html, /vault-file-chip-tag">PDF/);
  assert.match(html, /class="vault-embed"/);
  assert.match(html, /Under heading/);
  assert.match(html, /data-kind="canvas"/);
  assert.match(html, /data-kind="xyz"/);
  assert.match(html, /remote-image/);
});

test('section extraction', () => {
  const body = '# A\nx\n## B\ny\n### C\nz\n## D\n\nw\npara line ^id1';
  assert.equal(extractSection(body, 'B'), '## B\ny\n### C\nz');
  assert.equal(extractSection(body, '^id1'), 'w\npara line');
  assert.equal(extractSection(body, 'Nope'), null);
});

test('scan reports link and embed targets, skipping code', () => {
  const s = scan('[[A]] [[B|x]] ![[c.png]] ![](img/d.png) `[[NotThis]]`\n```\n[[NorThis]]\n```\n![remote](https://x/y.png)');
  assert.deepEqual(s.links.sort(), ['A', 'B']);
  assert.deepEqual(s.embeds.sort(), ['c.png', 'img/d.png']);
});

test('UAT test note: every feature renders', () => {
  const html = renderHTML({
    markdown: fx('markdown-och-mermaid-testnot.md'),
    resolved: { fixture: { path: 'Projects/fixture.md', kind: 'note' }, source: { path: 'Projects/source.md', kind: 'note' } },
    embedded: { 'Projects/fixture.md': '# Fixture note\nEmbedded body.' },
  });
  for (const pattern of [
    /<mark>highlight<\/mark>/, /<s>strikethrough<\/s>/, /class="vault-tag" data-tag="uat"/,
    /class="vault-tag" data-tag="bifrost\/rendering"/, /footnote-ref/, /<br>/,
    /vault-callout--warning/, /<details class="vault-callout vault-callout--tip"/,
    /class="task-list"/, /data-task-state="x"/, /vault-table-scroll/, /hljs-keyword/,
    /class="katex"/, /katex-display/, /<hr>/, /Embedded body/,
  ]) assert.match(html, pattern);
  assert.equal((html.match(/data-testid="vault-mermaid-block"/g) || []).length, 8);
  assert.match(html, /<h1 id="markdown-och-mermaid-testnot">/);
});

test('scan reports relative Markdown links, not external or local anchors', () => {
  const { links } = scan('[a](Sub/Other%20Note.md#Part) [b](https://x.io) [c](#here) ![i](pic.png) [d](mailto:a@b.c)');
  assert.deepEqual(links, ['Sub/Other Note.md']);
});

test('embedded notes resolve their own links relative to themselves', () => {
  const html = renderHTML({
    markdown: '![[Inner]]',
    notePath: 'A/Host.md',
    resolved: { Inner: { path: 'B/Inner.md', kind: 'note' }, Peer: { path: 'A/Peer.md', kind: 'note' } },
    resolvedBySource: {
      'A/Host.md': { Inner: { path: 'B/Inner.md', kind: 'note' } },
      'B/Inner.md': { Peer: { path: 'B/Peer.md', kind: 'note' } },
    },
    embedded: { 'B/Inner.md': 'see [[Peer]]' },
  });
  assert.match(html, /data-ygg-path="B\/Peer\.md"/);
  assert.doesNotMatch(html, /data-ygg-path="A\/Peer\.md"/);
});

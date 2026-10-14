// Builds Yggdrasil/Yggdrasil/MarkdownWeb (committed; the app has no JS build step).
//   npm ci && npm run build
import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync, copyFileSync, readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, '../../Yggdrasil/Yggdrasil/MarkdownWeb');
rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, 'katex'), { recursive: true });

await build({
  entryPoints: [join(here, 'src/browser.js')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari16'],
  legalComments: 'eof',
  outfile: join(out, 'bifrost-markdown.js'),
});

copyFileSync(join(here, 'node_modules/mermaid/dist/mermaid.min.js'), join(out, 'mermaid.min.js'));
copyFileSync(join(here, 'node_modules/katex/dist/katex.min.css'), join(out, 'katex/katex.min.css'));
cpSync(join(here, 'node_modules/katex/dist/fonts'), join(out, 'katex/fonts'), {
  recursive: true,
  filter: src => !/\.(ttf|woff)$/.test(src),
});
for (const f of ['index.html', 'note.css', 'yggdrasil-tokens.css', 'NOTICE.md']) {
  copyFileSync(join(here, 'src', f), join(out, f));
}

// Manifest of vendored bytes, for review and drift checks.
const lines = [];
const walk = dir => readdirSync(dir, { withFileTypes: true }).forEach(e => {
  const p = join(dir, e.name);
  if (e.isDirectory()) walk(p);
  else if (e.name !== 'VENDOR.sha256') lines.push(`${createHash('sha256').update(readFileSync(p)).digest('hex')}  ${p.slice(out.length + 1)}`);
});
walk(out);
writeFileSync(join(out, 'VENDOR.sha256'), lines.sort((a, b) => (a.slice(66) < b.slice(66) ? -1 : 1)).join('\n') + '\n');
console.log(`MarkdownWeb built: ${lines.length} files`);

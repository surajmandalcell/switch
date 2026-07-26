import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const output = path.join(root, 'dist/site');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(path.join(root, 'website'), output, { recursive: true });

const docsRoot = path.join(root, 'docs');
const markdownFiles = (await walk(docsRoot)).filter((file) => file.endsWith('.md'));
const navigation = await Promise.all(markdownFiles
  .filter((file) => !file.includes(`${path.sep}adr${path.sep}`))
  .map(async (file) => ({ file, relative: path.relative(docsRoot, file), title: titleOf(await readFile(file, 'utf8')) })));
navigation.sort((a, b) => order(a.relative) - order(b.relative) || a.title.localeCompare(b.title));

for (const sourcePath of markdownFiles) {
  const relative = path.relative(docsRoot, sourcePath).replace(/\.md$/i, '');
  const directory = path.join(output, 'docs', relative === 'INDEX' ? '' : relative.toLowerCase());
  await mkdir(directory, { recursive: true });
  const rootPrefix = path.relative(directory, output).replaceAll(path.sep, '/') || '.';
  const source = await readFile(sourcePath, 'utf8');
  const title = titleOf(source);
  const body = renderMarkdown(source, sourcePath, directory);
  const nav = navigation.map((item) => {
    const target = item.relative === 'INDEX.md' ? path.join(output, 'docs') : path.join(output, 'docs', item.relative.replace(/\.md$/, '').toLowerCase());
    return `<a href="${escapeHtml(relativeHref(directory, target))}"${item.file === sourcePath ? ' aria-current="page"' : ''}>${escapeHtml(item.title)}</a>`;
  }).join('');
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark light"><title>${escapeHtml(title)} · Subscription Proxy Inator</title><meta name="description" content="Subscription Proxy Inator documentation"><link rel="icon" href="${rootPrefix}/assets/icon.svg"><link rel="stylesheet" href="${rootPrefix}/assets/site.css"></head><body class="docs-page"><header class="site-header"><a class="site-brand" href="${rootPrefix}/"><img src="${rootPrefix}/assets/icon.svg" alt=""><span>Subscription Proxy Inator</span></a><nav><a href="${rootPrefix}/#features">Features</a><a href="${rootPrefix}/docs/">Documentation</a><a href="https://github.com/surajmandalcell/subscription-proxy-inator">GitHub</a></nav></header><div class="docs-layout"><aside class="docs-nav">${nav}</aside><main class="docs-content"><article>${body}</article></main></div><script src="${rootPrefix}/assets/site.js" defer></script></body></html>`;
  await writeFile(path.join(directory, 'index.html'), html);
}

const sitemap = ['','docs/', ...markdownFiles.filter((file) => path.basename(file) !== 'INDEX.md').map((file) => `docs/${path.relative(docsRoot, file).replace(/\.md$/i, '').toLowerCase()}/`)]
  .map((entry) => `<url><loc>https://surajmandalcell.github.io/subscription-proxy-inator/${entry}</loc></url>`).join('');
await writeFile(path.join(output, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${sitemap}</urlset>`);
console.log(`Generated the product site and ${markdownFiles.length} documentation pages in ${path.relative(root, output)}.`);

async function walk(directory) {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...await walk(full)); else output.push(full);
  }
  return output;
}
function titleOf(source) { return /^#\s+(.+)$/m.exec(source)?.[1]?.replace(/[`*_]/g, '') ?? 'Documentation'; }
function order(relative) {
  const names = ['INDEX.md','QUICK_START.md','ARCHITECTURE.md','CONFIGURATION.md','PROVIDERS.md','PROVIDER_DEVELOPMENT.md','API.md','ROUTING.md','USAGE.md','SECURITY.md','TROUBLESHOOTING.md','DEVELOPMENT.md','RELEASE.md','MIGRATION_V1.md'];
  const index = names.indexOf(relative); return index === -1 ? 100 : index;
}
function relativeHref(fromDirectory, toDirectory) {
  let value = path.relative(fromDirectory, toDirectory).replaceAll(path.sep, '/');
  if (!value) value = './'; else if (!value.endsWith('/')) value += '/';
  return value;
}

function renderMarkdown(source, sourcePath, outputDirectory) {
  const lines = source.replace(/\r/g, '').split('\n');
  const html = [];
  let index = 0;
  let paragraph = [];
  let list = null;
  let code = null;
  const flushParagraph = () => { if (paragraph.length) { html.push(`<p>${inline(paragraph.join(' '), sourcePath, outputDirectory)}</p>`); paragraph = []; } };
  const flushList = () => { if (list) { html.push(`</${list}>`); list = null; } };
  while (index < lines.length) {
    const line = lines[index];
    if (code) {
      if (/^```/.test(line)) { html.push(`<pre><code class="language-${escapeHtml(code.language)}">${escapeHtml(code.lines.join('\n'))}</code></pre>`); code = null; }
      else code.lines.push(line);
      index += 1; continue;
    }
    const fence = /^```\s*([\w-]*)/.exec(line);
    if (fence) { flushParagraph(); flushList(); code = { language: fence[1], lines: [] }; index += 1; continue; }
    const heading = /^(#{1,6})\s+(.+)$/.exec(line);
    if (heading) { flushParagraph(); flushList(); const level = heading[1].length; const text = heading[2]; html.push(`<h${level} id="${slug(text)}">${inline(text, sourcePath, outputDirectory)}</h${level}>`); index += 1; continue; }
    if (/^---+$/.test(line.trim())) { flushParagraph(); flushList(); html.push('<hr>'); index += 1; continue; }
    if (line.startsWith('> ')) { flushParagraph(); flushList(); html.push(`<blockquote>${inline(line.slice(2), sourcePath, outputDirectory)}</blockquote>`); index += 1; continue; }
    if (/^\|.+\|$/.test(line) && /^\|?\s*:?-+/.test(lines[index + 1] ?? '')) {
      flushParagraph(); flushList(); const headers = tableCells(line); index += 2; const rows = [];
      while (index < lines.length && /^\|.+\|$/.test(lines[index])) { rows.push(tableCells(lines[index])); index += 1; }
      html.push(`<div class="doc-table"><table><thead><tr>${headers.map((cell) => `<th>${inline(cell, sourcePath, outputDirectory)}</th>`).join('')}</tr></thead><tbody>${rows.map((row) => `<tr>${row.map((cell) => `<td>${inline(cell, sourcePath, outputDirectory)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`); continue;
    }
    const unordered = /^\s*[-*]\s+(.+)$/.exec(line);
    const ordered = /^\s*\d+[.)]\s+(.+)$/.exec(line);
    if (unordered || ordered) { flushParagraph(); const type = unordered ? 'ul' : 'ol'; if (list !== type) { flushList(); html.push(`<${type}>`); list = type; } html.push(`<li>${inline((unordered ?? ordered)[1], sourcePath, outputDirectory)}</li>`); index += 1; continue; }
    if (!line.trim()) { flushParagraph(); flushList(); index += 1; continue; }
    paragraph.push(line.trim()); index += 1;
  }
  flushParagraph(); flushList();
  if (code) html.push(`<pre><code class="language-${escapeHtml(code.language)}">${escapeHtml(code.lines.join('\n'))}</code></pre>`);
  return html.join('\n');
}
function inline(value, sourcePath, outputDirectory) {
  let text = escapeHtml(value);
  text = text.replace(/`([^`]+)`/g, '<code>$1</code>');
  text = text.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  text = text.replace(/\*([^*]+)\*/g, '<em>$1</em>');
  text = text.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (_match, label, href) => `<a href="${escapeHtml(rewriteHref(href, sourcePath, outputDirectory))}">${label}</a>`);
  return text;
}
function rewriteHref(href, sourcePath, outputDirectory) {
  if (/^(?:https?:|mailto:|tel:|#)/i.test(href)) return href;
  const [pathname, hash = ''] = href.split('#');
  if (!pathname.endsWith('.md')) return href;
  const targetSource = path.resolve(path.dirname(sourcePath), pathname);
  const relative = path.relative(path.join(root, 'docs'), targetSource).replace(/\.md$/i, '');
  const targetOutput = relative === 'INDEX' ? path.join(output, 'docs') : path.join(output, 'docs', relative.toLowerCase());
  return `${relativeHref(outputDirectory, targetOutput)}${hash ? `#${hash}` : ''}`;
}
function tableCells(line) { return line.replace(/^\||\|$/g, '').split('|').map((cell) => cell.trim()); }
function slug(value) { return value.toLowerCase().replace(/<[^>]+>/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }
function escapeHtml(value) { return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;'); }

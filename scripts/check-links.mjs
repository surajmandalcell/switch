import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const siteMode = process.argv.includes('--site');
const base = siteMode ? path.join(root, 'dist/site') : root;
const files = await walk(base);
const inputs = siteMode ? files.filter((file) => file.endsWith('.html')) : files.filter((file) => file.endsWith('.md'));
const errors = [];

for (const file of inputs) {
  const source = await readFile(file, 'utf8');
  const links = siteMode ? htmlLinks(source) : markdownLinks(source);
  for (const raw of links) {
    if (!raw || /^(?:https?:|mailto:|tel:|data:|javascript:)/i.test(raw) || raw === '#') continue;
    const [pathname] = raw.split('#');
    if (!pathname) continue;
    const decoded = decodeURIComponent(pathname.split('?')[0]);
    const resolved = decoded.startsWith('/')
      ? path.join(base, decoded.replace(/^\/+/, ''))
      : path.resolve(path.dirname(file), decoded);
    const existing = await resolveTarget(resolved);
    if (!existing) errors.push(`${path.relative(root, file)} -> ${raw}`);
  }
}

if (errors.length) throw new Error(`Broken local links:\n${errors.join('\n')}`);
console.log(`Checked ${inputs.length} ${siteMode ? 'generated HTML' : 'Markdown'} files: no broken local links.`);

async function walk(directory) {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (['node_modules', '.git', 'release', 'coverage'].includes(entry.name)) continue;
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...await walk(full));
    else output.push(full);
  }
  return output;
}

function markdownLinks(source) {
  return [...source.matchAll(/!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)].map((match) => match[1]);
}
function htmlLinks(source) {
  return [...source.matchAll(/\b(?:href|src)=["']([^"']+)["']/gi)].map((match) => match[1]);
}
async function resolveTarget(target) {
  const direct = await stat(target).catch(() => null);
  if (direct?.isFile()) return target;
  if (direct?.isDirectory() && await stat(path.join(target, 'index.html')).catch(() => null)) return path.join(target, 'index.html');
  if (!path.extname(target) && await stat(`${target}.md`).catch(() => null)) return `${target}.md`;
  return null;
}

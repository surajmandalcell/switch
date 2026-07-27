import { readdir, readFile, stat } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';

import { normalizeRepositoryPath } from './path-utils.mjs';

const root = path.resolve(import.meta.dirname, '..');
const excludedDirectories = new Set(['node_modules', 'dist', 'release', 'coverage', '.git']);
const required = [
  'package.json', 'README.md', 'CHANGELOG.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md',
  'docs/INDEX.md', 'docs/ARCHITECTURE.md', 'docs/DESIGN_SYSTEM.md', 'docs/CONFIGURATION.md', 'docs/PROVIDERS.md',
  'docs/API.md', 'docs/ROUTING.md', 'docs/USAGE.md', 'docs/SECURITY.md', 'docs/DEVELOPMENT.md',
  'desktop/main/index.js', 'desktop/preload/index.cjs', 'desktop/renderer/App.jsx',
  'src/bootstrap.js', 'src/application/routing-service.js', 'src/application/proxy-service.js',
  'src/domain/config.js', 'src/infrastructure/http-server.js', 'website/index.html',
  '.github/workflows/desktop-ci.yml', '.github/workflows/codeql.yml', '.github/workflows/release.yml',
];
const forbiddenRoots = ['bin', 'public', 'images', '.rework', '.lockgen', '.publish'];

for (const relativePath of required) {
  if (!(await stat(path.join(root, relativePath)).catch(() => null))) throw new Error(`Missing required public file: ${relativePath}`);
}
for (const relativePath of forbiddenRoots) {
  if (await stat(path.join(root, relativePath)).catch(() => null)) throw new Error(`Legacy or staging root must not be published: ${relativePath}`);
}

const files = await walk(root);
const publicFiles = files.filter((file) => !isExcluded(file));
const sourceFiles = publicFiles.filter((file) => /\.(?:js|mjs|cjs|jsx)$/.test(file));

for (const file of sourceFiles.filter((file) => !file.endsWith('.jsx'))) {
  const result = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${relative(file)} failed syntax validation:\n${result.stderr}`);
}

await validateJsx(sourceFiles.filter((file) => file.endsWith('.jsx')));
validateArchitecture(sourceFiles);
await validateStaleReferences(publicFiles);
await validatePackage();
await validateRendererBoundary();
await validateWorkflowActions(publicFiles);

console.log(`Verified ${publicFiles.length} canonical public files, ${sourceFiles.length} source files, package metadata, architecture boundaries, and repository cleanliness.`);

async function walk(directory) {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && excludedDirectories.has(entry.name)) continue;
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...await walk(full));
    else output.push(full);
  }
  return output;
}

function isExcluded(file) {
  return relative(file).split('/').some((part) => excludedDirectories.has(part));
}

function relative(file) {
  return normalizeRepositoryPath(path.relative(root, file));
}

async function validateJsx(files) {
  let typescript;
  try {
    typescript = await import('typescript');
  } catch {
    return;
  }
  for (const file of files) {
    const source = await readFile(file, 'utf8');
    const result = typescript.transpileModule(source, {
      fileName: file,
      reportDiagnostics: true,
      compilerOptions: {
        jsx: typescript.JsxEmit.ReactJSX,
        target: typescript.ScriptTarget.ES2022,
        module: typescript.ModuleKind.ESNext,
      },
    });
    const errors = (result.diagnostics ?? []).filter((diagnostic) => diagnostic.category === typescript.DiagnosticCategory.Error);
    if (errors.length) {
      throw new Error(`${relative(file)} failed JSX validation: ${errors
        .map((item) => typescript.flattenDiagnosticMessageText(item.messageText, '\n'))
        .join('; ')}`);
    }
  }
}

function validateArchitecture(files) {
  for (const file of files) {
    const rel = relative(file);
    const source = requireText(file);
    const imports = [
      ...source.matchAll(/(?:from\s+|import\s*\()\s*['"]([^'"]+)['"]/g),
      ...source.matchAll(/require\s*\(\s*['"]([^'"]+)['"]\s*\)/g),
    ].map((match) => match[1].replaceAll('\\', '/'));
    for (const specifier of imports) {
      const segments = specifier.split('/').filter((segment) => segment && segment !== '.' && segment !== '..');
      if (rel.startsWith('src/domain/') && segments.some((segment) => ['application', 'infrastructure', 'providers', 'desktop'].includes(segment))) {
        throw new Error(`Domain code cannot depend on outer layers. Found ${specifier} in ${rel}.`);
      }
      if (rel.startsWith('src/application/') && segments.some((segment) => ['infrastructure', 'desktop'].includes(segment))) {
        throw new Error(`Application code cannot depend on infrastructure or desktop presentation. Found ${specifier} in ${rel}.`);
      }
      if (rel.startsWith('desktop/renderer/') && (specifier === 'electron' || specifier.startsWith('node:') || segments.some((segment) => ['infrastructure', 'providers'].includes(segment)))) {
        throw new Error(`The sandboxed renderer cannot import Node, Electron, infrastructure, or provider adapters. Found ${specifier} in ${rel}.`);
      }
    }
  }
}

function requireText(file) {
  return spawnSync(
    process.execPath,
    ['-e', `process.stdout.write(require('fs').readFileSync(${JSON.stringify(file)}, 'utf8'))`],
    { encoding: 'utf8' },
  ).stdout;
}

async function validateStaleReferences(files) {
  const forbidden = [
    ['codex', '-proxy'].join(''),
    ['codex', '-claude-proxy'].join(''),
    ['.re', 'work/root'].join(''),
    ['automation/', 'desktop-rework'].join(''),
    ['@pikoloo/', 'codex-proxy'].join(''),
  ];
  for (const file of files.filter((item) => /\.(?:md|json|js|mjs|cjs|jsx|html|css|yml|yaml)$/.test(item))) {
    if (relative(file) === 'scripts/verify.mjs') continue;
    const source = await readFile(file, 'utf8');
    for (const term of forbidden) {
      if (source.toLowerCase().includes(term.toLowerCase())) {
        throw new Error(`Stale legacy reference ${JSON.stringify(term)} found in ${relative(file)}.`);
      }
    }
  }
}

async function validatePackage() {
  const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  if (pkg.name !== 'subscription-proxy-inator' || pkg.version !== '2.1.2') {
    throw new Error('Package identity must be subscription-proxy-inator@2.1.2.');
  }
  if (pkg.private !== true) throw new Error('The desktop application package must remain private.');
  if (pkg.main !== 'desktop/main/index.js') throw new Error('Electron main entry is incorrect.');
  if (!pkg.build?.mac || !pkg.build?.win || !pkg.build?.linux) throw new Error('Electron Builder must cover macOS, Windows, and Linux.');
  for (const command of ['test', 'test:coverage', 'verify', 'check:links', 'build:site', 'build:renderer', 'check', 'build', 'dist:dir']) {
    if (!pkg.scripts?.[command]) throw new Error(`Missing package script: ${command}`);
  }
}

async function validateRendererBoundary() {
  const preload = await readFile(path.join(root, 'desktop/preload/index.cjs'), 'utf8');
  const exposed = [...preload.matchAll(/^\s{2}([A-Za-z][A-Za-z0-9]*):/gm)].map((match) => match[1]);
  if (exposed.length < 10 || exposed.length > 40 || new Set(exposed).size !== exposed.length) {
    throw new Error('Preload bridge must expose a finite, unique capability set.');
  }
  const renderer = (await Promise.all((await walk(path.join(root, 'desktop/renderer'))).map((file) => readFile(file, 'utf8')))).join('\n');
  if (/secretRef|apiKeySecretRef|ipcRenderer|require\s*\(/.test(renderer)) {
    throw new Error('Renderer contains a forbidden secret reference or direct process capability.');
  }
  const main = await readFile(path.join(root, 'desktop/main/index.js'), 'utf8');
  if (!/contextIsolation:\s*true/.test(main) || !/sandbox:\s*true/.test(main) || !/nodeIntegration:\s*false/.test(main)) {
    throw new Error('BrowserWindow must keep context isolation and sandboxing enabled with Node integration disabled.');
  }
}

async function validateWorkflowActions(files) {
  const workflows = files.filter((file) => /\.github[\\/]workflows[\\/].+\.ya?ml$/.test(file));
  for (const file of workflows) {
    const source = await readFile(file, 'utf8');
    if (/actions\/checkout@v[1-5]\b/.test(source) || /actions\/setup-node@v[1-5]\b/.test(source)) {
      throw new Error(`${relative(file)} uses an obsolete Node-action generation.`);
    }
  }
}

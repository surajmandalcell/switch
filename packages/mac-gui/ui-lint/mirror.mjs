// The mirror proves measured geometry. Real text, real contrast, and ARIA require the HTML reference and native checks.
import { readFile, writeFile, mkdtemp, rm, mkdir } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = '/Volumes/External1TB/data/_custom/switch-build/lint';
const folder = dirname(fileURLToPath(import.meta.url));
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const area = node => node.frame.width * node.frame.height;
const contains = (outer, inner) => {
  const a = outer.frame, b = inner.frame;
  return a.x <= b.x + 0.1 && a.y <= b.y + 0.1 &&
    a.x + a.width >= b.x + b.width - 0.1 && a.y + a.height >= b.y + b.height - 0.1;
};

async function main() {
  const input = resolve(process.argv[2]);
  const doc = JSON.parse(await readFile(input, 'utf8'));
  if (!['light', 'dark'].includes(doc.appearance) || !doc.items?.length ||
      ![doc.window.width, doc.window.height].every(n => Number.isFinite(n) && n > 0))
    throw new Error('Export needs a window, appearance, and recorded items.');
  const nodes = [];
  for (const item of doc.items) {
    if (!['x', 'y', 'width', 'height'].every(key => Number.isFinite(item.frame?.[key])))
      throw new Error('Invalid measured frame.');
    if (item.frame.width <= 0 || item.frame.height <= 0) continue;
    // Co-located modifiers describe one native view, not overlapping HTML siblings.
    const same = nodes.find(node => ['x', 'y', 'width', 'height'].every(key => Math.abs(node.frame[key] - item.frame[key]) < 0.01));
    if (same) {
      const tags = [...same.tags, ...item.tags];
      const control = same.kind === 'control' || item.kind === 'control';
      const surface = tags.some(tag => ['card', 'tile', 'actions', 'stack'].includes(tag.name));
      const source = [...new Set([same.source, item.source].filter(Boolean))].join(', ');
      Object.assign(same, item, { tags, source, kind: control ? 'control' : (surface ? 'view' : (same.fontSize || item.fontSize ? 'text' : 'view')) });
    } else nodes.push({ ...item, children: [] });
  }
  const body = { frame: { x: 0, y: 0, ...doc.window }, children: [] };
  for (const node of nodes) {
    node.parent = nodes.filter(other => other !== node && other.kind !== 'text' &&
      area(other) > area(node) + 0.01 && contains(other, node))
      .sort((a, b) => area(a) - area(b))[0] ?? body;
    node.parent.children.push(node);
  }
  const groups = new Map();
  for (const node of nodes) for (const tag of node.tags) if (tag.name === 'align') {
    const group = groups.get(tag.group) ?? { edge: tag.edge, members: [] };
    if (group.edge !== tag.edge) throw new Error(`Conflicting edges in ${tag.group}`);
    group.members.push(node); groups.set(tag.group, group);
  }
  for (const [name, group] of groups) {
    if (group.members.length < 2) continue;
    let parent = group.members[0].parent;
    while (!group.members.every(node => {
      for (let ancestor = node.parent; ancestor; ancestor = ancestor.parent) if (ancestor === parent) return true;
      return false;
    })) parent = parent.parent;
    const wrapper = { frame: parent.frame, children: [], parent, group: name, edge: group.edge, tags: [] };
    parent.children.push(wrapper);
    // Geometry probes let one native view belong to several groups without moving its surface or controls.
    for (const node of new Set(group.members)) {
      wrapper.children.push({ frame: node.frame, tags: [], children: [], parent: wrapper,
        alignItem: true, source: node.source });
    }
  }
  const selectors = new Map();
  const tagName = node => node.kind === 'control' ? 'button' : node.kind === 'text' ? 'span' : 'div';
  function render(node, selector) {
    const f = node.frame, p = node.parent.frame;
    const names = new Set(node.tags.map(tag => tag.name));
    const attrs = [];
    // A one-tile row shares its frame with the tile. Its inner 6 pt text gaps are not row gaps.
    for (const name of ['actions', 'stack', 'number']) if (names.has(name) &&
        !(name === 'stack' && names.has('tile'))) attrs.push(`data-ui-${name}`);
    if (names.has('card')) {
      attrs.push('data-ui-container', 'data-ui-content');
      // Card tiles use the explicit 16 inset / 6 radius contract below, rather than radius minus inset.
      if (node.children.some(child => child.tags.some(tag => tag.name === 'tile') &&
          !child.tags.some(tag => tag.name === 'stack'))) attrs.push('data-ui-radius');
    }
    if (names.has('tile')) attrs.push('data-ui-radius-inner');
    if (node.alignItem) attrs.push('data-ui-align-item');
    if (node.group) attrs.push(`data-ui-align="${escape(node.edge)}"`, `data-group="${escape(node.group)}"`);
    const style = (node.group ? 'display:contents;' : '') + `left:${f.x - p.x}px;top:${f.y - p.y}px;width:${f.width}px;height:${f.height}px;` +
      `background:${node.fill ?? 'transparent'};border-radius:${node.radius ?? 0}px;` +
      `font-size:${node.fontSize ?? 14}px;font-weight:${node.fontWeight ?? 400};` +
      `font-family:${node.fontFamily === 'SF Mono' ? 'ui-monospace' : '-apple-system'};` +
      `color:${node.color ?? (doc.appearance === 'dark' ? '#ffffff' : '#000000')};` +
      (names.has('number') ? 'font-variant-numeric:tabular-nums;' : '');
    const tag = tagName(node);
    if (tag === 'button') attrs.push('aria-label="control"');
    const text = node.fontSize ? 'x'.repeat(Math.max(1, Math.min(3, Math.floor(f.width / node.fontSize)))) : '';
    selectors.set(selector, `${names.size ? [...names].join('+') : node.group ?? 'view'} ${node.source ?? ''}`.trim());
    return `<${tag} ${attrs.join(' ')} style="${escape(style)}">${text}${renderChildren(node.children, selector)}</${tag}>`;
  }
  function renderChildren(children, parent) {
    const counts = new Map();
    return children.map(node => {
      const tag = tagName(node), nth = (counts.get(tag) ?? 0) + 1;
      counts.set(tag, nth);
      return render(node, `${parent} > ${tag}:nth-of-type(${nth})`);
    }).join('');
  }
  const html = `<!doctype html><html lang="en"><meta charset="utf-8"><title>Measured ${escape(doc.page)}</title><style>
    *{box-sizing:border-box}html,body{margin:0;width:${doc.window.width}px;height:${doc.window.height}px;background:${doc.window.background ?? (doc.appearance === 'dark' ? '#282828' : '#ececec')};color-scheme:${doc.appearance}}
    body{position:relative}body *{position:absolute;border:0;padding:0;margin:0;white-space:nowrap;line-height:1}
    button:focus-visible{outline:2px solid #007aff;outline-offset:0}
    </style><body>${renderChildren(body.children, 'html > body:nth-of-type(1)')}</body></html>`;
  const output = input.replace(/\.json$/, '') + '.html';
  await writeFile(output, html);
  await mkdir(root, { recursive: true });
  const temp = await mkdtemp(join(root, 'mirror-policy-'));
  try {
    const policy = JSON.parse(await readFile(join(folder, 'ui-policy.json'), 'utf8'));
    policy.viewports = [{ width: Math.ceil(doc.window.width), height: Math.ceil(doc.window.height) }];
    policy.colorSchemes = [doc.appearance];
    const config = join(temp, 'policy.json');
    await writeFile(config, JSON.stringify(policy));
    const run = spawnSync('npx', ['--no-install', 'lintapple', pathToFileURL(output).href, '--config', config, '--json'], {
      cwd: folder, encoding: 'utf8', timeout: 120000, maxBuffer: 16 * 1024 * 1024,
      env: { ...process.env, TMPDIR: temp, npm_config_cache: join(temp, 'npm-cache'),
        PLAYWRIGHT_BROWSERS_PATH: '/Volumes/External1TB/data/_custom/playwright' }
    });
    if (run.error || ![0, 1].includes(run.status)) throw new Error(run.error?.message ?? run.stderr ?? 'lintapple failed');
    const report = JSON.parse(run.stdout);
    const measuredRules = new Set(['font-family', 'font-size', 'control-size', 'control-gap',
      'control-inset', 'layout-gap', 'layout-alignment', 'tabular-numbers', 'numeric-alignment',
      'nested-radius', 'root-background', 'horizontal-overflow', 'viewport-bounds',
      'content-clipping', 'content-overflow']);
    // A search hint can use Secondary text inside a synthetic button; judge its role against global sizes.
    const findings = report.findings.filter(finding => measuredRules.has(finding.rule) &&
      !(finding.rule === 'font-size' && policy.fontSizes.some(size => finding.actual === `${size}px`)));
    // Our own post-check, next to lintapple: a card's inner padding is even. The gap from the card's
    // Tile rows share the card inset, independent of the measured title and text bounds.
    for (const row of nodes.filter(node => node.tags.some(tag => tag.name === 'stack'))) {
      const tiles = (row.tags.some(tag => tag.name === 'tile') ? [row] :
        row.children.filter(node => node.tags.some(tag => tag.name === 'tile')))
        .sort((a, b) => a.frame.x - b.frame.x);
      if (!tiles.length) continue;
      let card = row.parent;
      while (card && !card.tags?.some(tag => tag.name === 'card')) card = card.parent;
      if (!card) continue;
      const first = tiles[0].frame, last = tiles.at(-1).frame;
      const insets = [first.x - card.frame.x,
        card.frame.x + card.frame.width - last.x - last.width,
        card.frame.y + card.frame.height - Math.max(...tiles.map(tile => tile.frame.y + tile.frame.height))];
      const gaps = tiles.slice(1).map((tile, i) => tile.frame.x - tiles[i].frame.x - tiles[i].frame.width);
      if (insets.some(value => Math.abs(value - 16) > 1) || gaps.some(value => Math.abs(value - 12) > 1) ||
          tiles.some(tile => tile.radius !== 6)) {
        findings.push({ rule: 'tile-geometry', selector: `tiles@${row.source}`, actual: `insets ${insets}, gaps ${gaps}, radius ${tiles.map(tile => tile.radius)}` });
      }
    }
    // top edge to its first content item (text, control, tile, or tagged item) must equal the gap
    // from its last content item to the bottom edge, within 1 pt. Scrolling cards are skipped.
    const isContent = node => node.kind === 'text' || node.kind === 'control' ||
      node.tags.some(tag => tag.name === 'item' || (tag.name === 'tile' && !node.children.length));
    const inside = (node, card) => { for (let up = node.parent; up; up = up.parent) if (up === card) return true; return false; };
    for (const card of nodes.filter(node => node.tags.some(tag => tag.name === 'card') &&
        !node.tags.some(tag => tag.name === 'scrolls'))) {
      const items = nodes.filter(node => node !== card && inside(node, card) && isContent(node));
      // Tile rows have the explicit 16 pt bottom inset checked above; title text starts at 14.
      if (nodes.some(node => inside(node, card) && node.tags.some(tag => tag.name === 'stack') &&
          (node.tags.some(tag => tag.name === 'tile') ||
           node.children.some(child => child.tags.some(tag => tag.name === 'tile'))))) continue;
      if (!items.length) continue;
      const top = Math.min(...items.map(node => node.frame.y)) - card.frame.y;
      const bottom = card.frame.y + card.frame.height - Math.max(...items.map(node => node.frame.y + node.frame.height));
      if (Math.abs(top - bottom) > 1) {
        const selector = `card-inset@${card.source}`;
        selectors.set(selector, `card ${card.source ?? ''}`.trim());
        findings.push({ rule: 'card-inset', selector, actual: `top ${top.toFixed(1)} pt, bottom ${bottom.toFixed(1)} pt` });
      }
    }
    console.log(`${doc.page} ${doc.appearance}: ${findings.length ? `FAIL ${findings.length} geometry findings` : 'PASS geometry'} (${nodes.length} measured items)`);
    for (const finding of findings) console.log(`${finding.rule} | ${finding.selector} | ${finding.actual ?? finding.message} | ${selectors.get(finding.selector) ?? 'unknown source'}`);
    process.exitCode = findings.length ? 1 : 0;
  } finally { await rm(temp, { recursive: true, force: true }); }
}
main().catch(error => {
  const message = error.message.includes('bootstrap_check_in')
    ? 'Chromium launch denied by the host sandbox (bootstrap_check_in, Permission denied 1100).'
    : error.message;
  console.error(`UI_LINT_ERROR: ${message}`); process.exitCode = 2;
});

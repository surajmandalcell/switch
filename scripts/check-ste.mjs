import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import ts from 'typescript';

const root = path.resolve(import.meta.dirname, '..');
const excludedDirectories = new Set(['node_modules', 'dist', 'release', 'coverage', '.git']);
const fixedFiles = [
  'website/index.html',
  'website/404.html',
  'website/manifest.webmanifest',
  'package.json',
];

const prohibited = [
  'and/or',
  'in order to',
  'prior to',
  'subsequent to',
  'utilize',
  'leverage',
  'seamless',
  'powerful',
  'robust',
  'easy to use',
  'simply',
  'obviously',
  'very',
  'basically',
];

const contractions = /\b(?:aren't|can't|couldn't|didn't|doesn't|don't|hasn't|haven't|isn't|it's|shouldn't|that's|they're|wasn't|weren't|won't|wouldn't|you're)\b/i;
const wordPattern = /[A-Za-z0-9]+(?:[.'_-][A-Za-z0-9]+)*/g;
const namedEntities = new Map([
  ['&amp;', '&'],
  ['&lt;', '<'],
  ['&gt;', '>'],
  ['&quot;', '"'],
  ['&#39;', "'"],
]);

async function walk(directory, predicate) {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && excludedDirectories.has(entry.name)) continue;
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...await walk(absolute, predicate));
    else if (predicate(absolute)) output.push(path.relative(root, absolute));
  }
  return output;
}

function decodeEntities(value) {
  return value.replace(/&(?:amp|lt|gt|quot|#39|#\d+);/g, (entity) => {
    const named = namedEntities.get(entity);
    if (named !== undefined) return named;
    const codePoint = Number(entity.slice(2, -1));
    if (!Number.isInteger(codePoint) || codePoint < 0 || codePoint > 0x10ffff) return entity;
    if (codePoint >= 0xd800 && codePoint <= 0xdfff) return entity;
    return String.fromCodePoint(codePoint);
  });
}

function stripHtmlElement(source, tag, replacement = ' ') {
  const openToken = `<${tag}`;
  const closeToken = `</${tag}`;
  let output = '';
  let cursor = 0;

  while (cursor < source.length) {
    const lower = source.toLowerCase();
    let start = lower.indexOf(openToken, cursor);
    while (start !== -1) {
      const boundary = lower[start + openToken.length];
      if (boundary === '>' || boundary === '/' || /\s/.test(boundary ?? '')) break;
      start = lower.indexOf(openToken, start + openToken.length);
    }
    if (start === -1) return output + source.slice(cursor);

    const openEnd = lower.indexOf('>', start + openToken.length);
    if (openEnd === -1) return output + source.slice(cursor);
    const closeStart = lower.indexOf(closeToken, openEnd + 1);
    if (closeStart === -1) return output + source.slice(cursor, start) + replacement;
    const closeEnd = lower.indexOf('>', closeStart + closeToken.length);
    if (closeEnd === -1) return output + source.slice(cursor, start) + replacement;

    output += source.slice(cursor, start) + replacement;
    cursor = closeEnd + 1;
  }

  return output;
}

function removeInlineCode(value) {
  return value
    .replace(/`[^`]*`/g, ' TECHNICAL_TERM ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/https?:\/\/\S+/g, ' URL ')
    .replace(/[*_~]/g, ' ');
}

function markdownSegments(source) {
  const segments = [];
  let inFence = false;
  let paragraph = [];

  const flush = () => {
    if (paragraph.length) segments.push({ text: paragraph.join(' '), instruction: false });
    paragraph = [];
  };

  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.startsWith('```')) {
      flush();
      inFence = !inFence;
      continue;
    }
    if (inFence || !line) {
      flush();
      continue;
    }
    if (/^#{1,6}\s/.test(line) || /^\|/.test(line) || /^[-:| ]+$/.test(line) || /^<\/?[a-z]/i.test(line)) {
      flush();
      continue;
    }
    const numbered = line.match(/^\d+[.)]\s+(.*)$/);
    if (numbered) {
      flush();
      segments.push({ text: numbered[1], instruction: true });
      continue;
    }
    const bullet = line.match(/^[-*+]\s+(.*)$/);
    if (bullet) {
      flush();
      segments.push({ text: bullet[1], instruction: false });
      continue;
    }
    paragraph.push(line);
  }
  flush();
  return segments;
}

function htmlSegments(source) {
  let clean = source;
  for (const [tag, replacement] of [
    ['script', ' '],
    ['style', ' '],
    ['svg', ' '],
    ['pre', ' '],
    ['code', ' TECHNICAL_TERM '],
  ]) clean = stripHtmlElement(clean, tag, replacement);
  return markupSegments(clean);
}

function markupSegments(source) {
  const output = [];
  for (const match of source.matchAll(/>([^<>]+)</g)) {
    const text = decodeEntities(match[1]).trim();
    if (text) output.push({ text, instruction: false });
  }
  for (const match of source.matchAll(/\b(?:content|aria-label|alt|title)="([^"]+)"/g)) {
    const text = decodeEntities(match[1]).trim();
    if (text) output.push({ text, instruction: false });
  }
  return output;
}

function yamlSegments(source) {
  const output = [];
  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const match = line.match(/^(?:name|description|about|label|placeholder|value):\s*(.+)$/);
    if (match) output.push({ text: match[1].replace(/^['"]|['"]$/g, ''), instruction: false });
  }
  return output;
}

function jsonSegments(source) {
  const data = JSON.parse(source);
  const output = [];
  const collect = (value, key = '') => {
    if (typeof value === 'string') {
      if (['description', 'name', 'short_name'].includes(key)) output.push({ text: value, instruction: false });
      return;
    }
    if (Array.isArray(value)) return value.forEach((item) => collect(item, key));
    if (value && typeof value === 'object') {
      for (const [childKey, child] of Object.entries(value)) collect(child, childKey);
    }
  };
  collect(data);
  return output;
}

function javascriptSegments(source, file) {
  const output = [];
  const kind = file.endsWith('.jsx') ? ts.ScriptKind.JSX : ts.ScriptKind.JS;
  const sourceFile = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind);

  const add = (text) => {
    const value = String(text ?? '').replace(/\s+/g, ' ').trim();
    if (value) output.push({ text: value, instruction: false });
  };

  const visit = (node) => {
    if (ts.isStringLiteralLike(node) || ts.isNoSubstitutionTemplateLiteral(node)) add(node.text);
    if (ts.isTemplateExpression(node)) {
      add([node.head.text, ...node.templateSpans.map((span) => `TECHNICAL_TERM ${span.literal.text}`)].join(' '));
    }
    if (ts.isJsxText(node)) add(node.text);
    ts.forEachChild(node, visit);
  };

  visit(sourceFile);
  return output;
}

function splitSentences(text) {
  const normalized = removeInlineCode(text).replace(/\s+/g, ' ').trim();
  if (!normalized) return [];
  return normalized.split(/(?<=[.!?])\s+(?=[A-Z0-9])/).map((item) => item.trim()).filter(Boolean);
}

function containsPhrase(text, phrase) {
  const escaped = phrase.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '\\s+');
  return new RegExp(`(?:^|[^a-z0-9])${escaped}(?:$|[^a-z0-9])`, 'i').test(text);
}

function checkSegment(file, segment, errors) {
  const prose = removeInlineCode(segment.text);
  for (const phrase of prohibited) {
    if (containsPhrase(prose, phrase)) errors.push(`${file}: prohibited phrase ${JSON.stringify(phrase)} in: ${segment.text}`);
  }
  if (contractions.test(prose)) errors.push(`${file}: contraction in: ${segment.text}`);
  if (prose.includes(';')) errors.push(`${file}: semicolon in prose: ${segment.text}`);

  for (const sentence of splitSentences(segment.text)) {
    const words = sentence.match(wordPattern) ?? [];
    const limit = segment.instruction ? 20 : 25;
    if (words.length > limit) errors.push(`${file}: ${words.length}-word sentence exceeds ${limit}: ${sentence}`);
  }
}

const markdownFiles = await walk(root, (file) => file.endsWith('.md'));
const yamlFiles = await walk(path.join(root, '.github'), (file) => /\.ya?ml$/.test(file));
const svgFiles = await walk(root, (file) => file.endsWith('.svg'));
const rendererFiles = await walk(path.join(root, 'desktop/renderer'), (file) => /\.(?:js|jsx)$/.test(file));
const javascriptFiles = [...rendererFiles, 'website/assets/site.js'];
const files = [...new Set([...fixedFiles, ...markdownFiles, ...yamlFiles, ...svgFiles, ...javascriptFiles])].sort();
const errors = [];
let segmentCount = 0;

for (const file of files) {
  const source = await readFile(path.join(root, file), 'utf8');
  let segments;
  if (file.endsWith('.html')) segments = htmlSegments(source);
  else if (file.endsWith('.svg')) segments = markupSegments(source);
  else if (file.endsWith('.yml') || file.endsWith('.yaml')) segments = yamlSegments(source);
  else if (file.endsWith('.json') || file.endsWith('.webmanifest')) segments = jsonSegments(source);
  else if (file.endsWith('.js') || file.endsWith('.jsx')) segments = javascriptSegments(source, file);
  else segments = markdownSegments(source);
  segmentCount += segments.length;
  for (const segment of segments) checkSegment(file, segment, errors);
}

if (errors.length) {
  console.error(`ASD-STE100 project profile failed with ${errors.length} issue(s).`);
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(`ASD-STE100 project profile passed for ${files.length} files and ${segmentCount} text segments.`);

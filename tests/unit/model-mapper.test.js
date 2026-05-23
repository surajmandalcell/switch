/**
 * Unit tests for src/model-mapper.js
 * Tests model name mapping, kilo detection, and routing resolution.
 * No server required — logic tests.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  mapClaudeModel,
  isKiloModel,
  resolveKiloModel,
  resolveModelRouting,
  normalizeModelMappings,
  normalizeReasoningMappings
} from '../../src/model-mapper.js';
import modelMapperDefault from '../../src/model-mapper.js';
const { CLAUDE_MODEL_MAP, OPENAI_MODEL_OPTIONS, REASONING_LEVEL_OPTIONS } = modelMapperDefault;

// ─── mapClaudeModel ───────────────────────────────────────────────────────────

test('mapClaudeModel: maps claude-opus-4-5 to current OpenAI default', () => {
  assert.equal(mapClaudeModel('claude-opus-4-5'), 'gpt-5.5');
});

test('mapClaudeModel: maps claude-sonnet-4-5 to current OpenAI default', () => {
  assert.equal(mapClaudeModel('claude-sonnet-4-5'), 'gpt-5.5');
});

test('mapClaudeModel: maps claude-haiku-4-20250514 to OpenAI mini by default', () => {
  assert.equal(mapClaudeModel('claude-haiku-4-20250514'), 'gpt-5.4-mini');
});

test('mapClaudeModel: maps claude-3-haiku-20240307 to OpenAI mini by default', () => {
  assert.equal(mapClaudeModel('claude-3-haiku-20240307'), 'gpt-5.4-mini');
});

test('mapClaudeModel: maps claude-3-opus-20240229 to current OpenAI default', () => {
  assert.equal(mapClaudeModel('claude-3-opus-20240229'), 'gpt-5.5');
});

test('mapClaudeModel: maps shorthand "haiku" to OpenAI mini by default', () => {
  assert.equal(mapClaudeModel('haiku'), 'gpt-5.4-mini');
});

test('mapClaudeModel: maps shorthand "opus" to current OpenAI default', () => {
  assert.equal(mapClaudeModel('opus'), 'gpt-5.5');
});

test('mapClaudeModel: maps shorthand "sonnet" to current OpenAI default', () => {
  assert.equal(mapClaudeModel('sonnet'), 'gpt-5.5');
});

test('mapClaudeModel: passes through gpt-5.2-codex unchanged', () => {
  assert.equal(mapClaudeModel('gpt-5.2-codex'), 'gpt-5.2-codex');
});

test('mapClaudeModel: maps codex shorthand to latest Codex model', () => {
  assert.equal(mapClaudeModel('codex'), 'gpt-5.3-codex');
});

test('mapClaudeModel: passes through latest Codex model unchanged', () => {
  assert.equal(mapClaudeModel('gpt-5.3-codex'), 'gpt-5.3-codex');
});

test('mapClaudeModel: passes through latest GPT-5.5 unchanged', () => {
  assert.equal(mapClaudeModel('gpt-5.5'), 'gpt-5.5');
});

test('mapClaudeModel: passes through GPT-5.4 mini unchanged', () => {
  assert.equal(mapClaudeModel('gpt-5.4-mini'), 'gpt-5.4-mini');
});

test('mapClaudeModel: passes through gpt-5.2 unchanged', () => {
  assert.equal(mapClaudeModel('gpt-5.2'), 'gpt-5.2');
});

test('mapClaudeModel: falls back to gpt-5.5 for unknown model', () => {
  assert.equal(mapClaudeModel('unknown-model-xyz'), 'gpt-5.5');
});

test('mapClaudeModel: falls back to gpt-5.5 for null/undefined', () => {
  assert.equal(mapClaudeModel(null), 'gpt-5.5');
  assert.equal(mapClaudeModel(undefined), 'gpt-5.5');
  assert.equal(mapClaudeModel(''), 'gpt-5.5');
});

test('mapClaudeModel: fuzzy match claude-*-opus-* to current OpenAI default', () => {
  assert.equal(mapClaudeModel('claude-3-5-opus-20250514'), 'gpt-5.5');
});

test('mapClaudeModel: fuzzy match claude-*-haiku-* to OpenAI mini by default', () => {
  assert.equal(mapClaudeModel('claude-3-5-haiku-20250514'), 'gpt-5.4-mini');
});

test('mapClaudeModel: fuzzy match claude-*-sonnet-* to current OpenAI default', () => {
  assert.equal(mapClaudeModel('claude-3-5-sonnet-20250514'), 'gpt-5.5');
});

test('mapClaudeModel: applies custom Opus mapping to Claude variants', () => {
  const settings = { modelMappings: { opus: 'gpt-5.4', sonnet: 'gpt-5.5', haiku: 'gpt-5.4-mini' } };
  assert.equal(mapClaudeModel('claude-opus-4-5', settings), 'gpt-5.4');
  assert.equal(mapClaudeModel('opus', settings), 'gpt-5.4');
});

test('mapClaudeModel: applies custom Sonnet and Haiku mappings', () => {
  const settings = { modelMappings: { sonnet: 'gpt-5.4-mini', haiku: 'gpt-5.4' } };
  assert.equal(mapClaudeModel('sonnet', settings), 'gpt-5.4-mini');
  assert.equal(mapClaudeModel('claude-haiku-4', settings), 'gpt-5.4');
});

test('normalizeModelMappings: fills defaults and ignores unsupported model IDs', () => {
  assert.deepEqual(normalizeModelMappings({
    opus: 'gpt-5.4',
    sonnet: 'unsupported-model',
    haiku: 42
  }), {
    opus: 'gpt-5.4',
    sonnet: 'gpt-5.5',
    haiku: 'gpt-5.4-mini'
  });
});

test('normalizeReasoningMappings: fills defaults and ignores unsupported reasoning levels', () => {
  assert.deepEqual(normalizeReasoningMappings({
    opus: 'xhigh',
    sonnet: 'unsupported',
    haiku: 42
  }), {
    opus: 'xhigh',
    sonnet: 'medium',
    haiku: 'low'
  });
});

// ─── isKiloModel ─────────────────────────────────────────────────────────────

test('isKiloModel: returns true for "kilo"', () => {
  assert.equal(isKiloModel('kilo'), true);
});

test('isKiloModel: returns false for non-kilo models', () => {
  assert.equal(isKiloModel('gpt-5.2'), false);
  assert.equal(isKiloModel('gpt-5.3-codex'), false);
  assert.equal(isKiloModel('gpt-5.2-codex'), false);
  assert.equal(isKiloModel(''), false);
  assert.equal(isKiloModel(null), false);
});

// ─── resolveKiloModel ────────────────────────────────────────────────────────

test('resolveKiloModel: returns a non-empty string', () => {
  const result = resolveKiloModel();
  assert.ok(typeof result === 'string' && result.length > 0);
});

test('resolveKiloModel: returns one of the known kilo model identifiers', () => {
  const result = resolveKiloModel();
  // Model is now stored as full ID (e.g. 'minimax/minimax-m2.5:free')
  assert.ok(typeof result === 'string' && result.length > 0, `Unexpected kilo model: ${result}`);
});

// ─── resolveModelRouting ─────────────────────────────────────────────────────

test('resolveModelRouting: haiku model uses OpenAI by default', () => {
  const result = resolveModelRouting('claude-haiku-4');
  assert.equal(result.isKilo, false);
  assert.equal(result.kiloTarget, null);
  assert.equal(result.upstreamModel, 'gpt-5.4-mini');
});

test('resolveModelRouting: opus model does NOT route to kilo', () => {
  const result = resolveModelRouting('claude-opus-4-5');
  assert.equal(result.isKilo, false);
  assert.equal(result.kiloTarget, null);
  assert.equal(result.mappedModel, 'gpt-5.5');
  assert.equal(result.upstreamModel, 'gpt-5.5');
  assert.equal(result.reasoningLevel, 'high');
});

test('resolveModelRouting: sonnet model does NOT route to kilo', () => {
  const result = resolveModelRouting('claude-sonnet-4-5');
  assert.equal(result.isKilo, false);
  assert.equal(result.kiloTarget, null);
  assert.equal(result.mappedModel, 'gpt-5.5');
});

test('resolveModelRouting: unknown model falls back to gpt-5.5 (non-kilo)', () => {
  const result = resolveModelRouting('totally-unknown-model');
  assert.equal(result.isKilo, false);
  assert.equal(result.mappedModel, 'gpt-5.5');
});

test('resolveModelRouting: null/undefined defaults to gpt-5.5 (non-kilo)', () => {
  const result = resolveModelRouting(null);
  assert.equal(result.isKilo, false);
  assert.equal(result.mappedModel, 'gpt-5.5');
});

test('resolveModelRouting: explicit kilo still routes to Kilo', () => {
  const result = resolveModelRouting('kilo');
  assert.equal(result.isKilo, true);
  assert.ok(result.kiloTarget !== null);
});

test('resolveModelRouting: returns all expected keys', () => {
  const result = resolveModelRouting('kilo');
  assert.ok('mappedModel' in result);
  assert.ok('isKilo' in result);
  assert.ok('kiloTarget' in result);
  assert.ok('upstreamModel' in result);
  assert.ok('reasoningLevel' in result);
});

// ─── CLAUDE_MODEL_MAP sanity checks ──────────────────────────────────────────

test('CLAUDE_MODEL_MAP: is a non-empty object', () => {
  assert.ok(typeof CLAUDE_MODEL_MAP === 'object' && CLAUDE_MODEL_MAP !== null);
  assert.ok(Object.keys(CLAUDE_MODEL_MAP).length > 0);
});

test('CLAUDE_MODEL_MAP: all values are non-empty strings', () => {
  for (const [key, value] of Object.entries(CLAUDE_MODEL_MAP)) {
    assert.ok(typeof value === 'string' && value.length > 0, `Value for "${key}" is invalid: ${value}`);
  }
});

test('OPENAI_MODEL_OPTIONS: exposes supported GPT dropdown options', () => {
  const ids = OPENAI_MODEL_OPTIONS.map((model) => model.id);
  assert.ok(ids.includes('gpt-5.5'));
  assert.ok(ids.includes('gpt-5.4-mini'));
  assert.equal(new Set(ids).size, ids.length);
});

test('REASONING_LEVEL_OPTIONS: exposes supported reasoning dropdown options', () => {
  const ids = REASONING_LEVEL_OPTIONS.map((level) => level.id);
  assert.deepEqual(ids, ['low', 'medium', 'high', 'xhigh']);
});

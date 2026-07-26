import { ProviderRegistry } from '../application/provider-registry.js';
import { createAnthropicCompatibleAdapter } from './anthropic-compatible.js';
import { createCommandAdapter } from './command.js';
import { createExternalModuleAdapter } from './external-module.js';
import { createGeminiAdapter } from './gemini.js';
import { createOpenAICompatibleAdapter } from './openai-compatible.js';

export function createProviderRegistry({ trustedModulesRoot }) {
  return new ProviderRegistry([
    createOpenAICompatibleAdapter({ type: 'openai', defaultBaseUrl: 'https://api.openai.com/v1' }),
    createOpenAICompatibleAdapter({ type: 'grok', defaultBaseUrl: 'https://api.x.ai/v1' }),
    createOpenAICompatibleAdapter({ type: 'openai-compatible' }),
    createAnthropicCompatibleAdapter({ type: 'anthropic', defaultBaseUrl: 'https://api.anthropic.com/v1' }),
    createAnthropicCompatibleAdapter({ type: 'anthropic-compatible' }),
    createGeminiAdapter(),
    createCommandAdapter(),
    createExternalModuleAdapter({ trustedRoot: trustedModulesRoot }),
  ]);
}

export const PROVIDER_PRESETS = Object.freeze([
  { type: 'openai', name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', modelGlobs: ['gpt-*', 'o*'] },
  { type: 'anthropic', name: 'Anthropic', baseUrl: 'https://api.anthropic.com/v1', modelGlobs: ['claude-*'] },
  { type: 'gemini', name: 'Google Gemini', baseUrl: 'https://generativelanguage.googleapis.com/v1beta', modelGlobs: ['gemini-*'] },
  { type: 'grok', name: 'xAI Grok', baseUrl: 'https://api.x.ai/v1', modelGlobs: ['grok-*'] },
  { type: 'openai-compatible', name: 'OpenAI-compatible', baseUrl: '', modelGlobs: ['*'] },
  { type: 'anthropic-compatible', name: 'Anthropic-compatible', baseUrl: '', modelGlobs: ['*'] },
  { type: 'command', name: 'CLI / command', baseUrl: '', modelGlobs: ['*'] },
]);

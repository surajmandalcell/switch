/**
 * Chat Completions Route
 * Handles POST /v1/chat/completions (OpenAI Chat Completions API compatibility)
 * and POST /v1/messages/count_tokens (approximate token counting).
 */

import { sendMessage } from '../direct-api.js';
import { sendKiloMessage } from '../kilo-api.js';
import { DEFAULT_OPENAI_MODEL, isKiloEnabled, resolveModelRouting } from '../model-mapper.js';
import { getCredentialsOrError, sendAuthError } from '../middleware/credentials.js';
import { handleStreamError } from '../middleware/sse.js';
import { logger } from '../utils/logger.js';
import { recordUsageEventSafe } from '../usage-metrics.js';

/**
 * POST /v1/chat/completions
 * Converts OpenAI Chat format to Anthropic internally, then routes to Codex or Kilo.
 * Always returns a non-streaming OpenAI-compatible response.
 */
export async function handleChatCompletion(req, res) {
  const startTime = Date.now();
  const body = req.body;
  const requestedModel = body.model || DEFAULT_OPENAI_MODEL;

  const { isKilo, kiloTarget, upstreamModel, reasoningLevel } = resolveModelRouting(requestedModel);

  if (isKilo && !isKiloEnabled()) {
    recordChatMetric({
      body,
      requestedModel,
      upstreamModel,
      provider: 'kilo',
      accountLabel: 'kilo',
      startTime,
      status: 403,
      errorType: 'kilo_disabled'
    });
    return res.status(403).json({
      error: {
        message: 'Kilo routing is disabled. Set CODEX_CLAUDE_PROXY_ENABLE_KILO=true to enable third-party Kilo model routing.',
        type: 'invalid_request_error',
        code: 'kilo_disabled'
      }
    });
  }

  let creds = null;
  if (!isKilo) {
    creds = await getCredentialsOrError();
    if (!creds) {
      logger.response(401, { error: 'No configured account' });
      recordChatMetric({
        body,
        requestedModel,
        upstreamModel,
        provider: 'openai',
        startTime,
        status: 401,
        errorType: 'auth_error'
      });
      return sendAuthError(res, 'No configured account. Add an account via /account/add');
    }
  }

  const anthropicRequest = _buildAnthropicRequest(body, upstreamModel, reasoningLevel);

  logger.request('POST', '/v1/chat/completions', {
    model: upstreamModel,
    account: isKilo ? 'kilo' : creds.email,
    messages: body.messages?.length || 0,
    tools: body.tools?.length || 0
  });

  try {
    const response = isKilo
      ? await sendKiloMessage(anthropicRequest, kiloTarget)
      : await sendMessage(anthropicRequest, creds.accessToken, creds.accountId);

    const duration = Date.now() - startTime;
    logger.response(200, { model: upstreamModel, usage: response.usage, duration });
    recordChatMetric({
      body,
      requestedModel,
      upstreamModel,
      provider: isKilo ? 'kilo' : 'openai',
      accountLabel: isKilo ? 'kilo' : creds.email,
      usage: response.usage,
      startTime,
      status: 200,
      duration
    });

    res.json(_buildOpenAIResponse(response, requestedModel));
  } catch (error) {
    recordChatMetric({
      body,
      requestedModel,
      upstreamModel,
      provider: isKilo ? 'kilo' : 'openai',
      accountLabel: isKilo ? 'kilo' : creds?.email,
      startTime,
      status: error.status || 500,
      errorType: classifyMetricError(error)
    });
    handleStreamError(res, error, upstreamModel, startTime);
  }
}

/**
 * POST /v1/messages/count_tokens
 * Returns an approximate token count for the given request body.
 */
export function handleCountTokens(req, res) {
  const body = req.body;
  let text = '';

  if (body.system) {
    if (typeof body.system === 'string') {
      text += body.system + ' ';
    } else if (Array.isArray(body.system)) {
      for (const block of body.system) {
        if (block.type === 'text') text += block.text + ' ';
      }
    }
  }

  if (body.tools) {
    for (const tool of body.tools) {
      text += JSON.stringify(tool) + ' ';
    }
  }

  if (Array.isArray(body.messages)) {
    for (const msg of body.messages) {
      if (typeof msg.content === 'string') {
        text += msg.content + ' ';
      } else if (Array.isArray(msg.content)) {
        for (const block of msg.content) {
          if (block.type === 'text') {
            text += block.text + ' ';
          } else if (block.type === 'tool_use' || block.type === 'tool_result') {
            text += JSON.stringify(block) + ' ';
          }
        }
      }
    }
  }

  const approxTokens = Math.ceil(text.length / 4);
  res.json({ input_tokens: approxTokens });
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Converts an OpenAI Chat Completions request body into an Anthropic-style request.
 * @param {object} body
 * @param {string} upstreamModel
 * @returns {object}
 */
function _buildAnthropicRequest(body, upstreamModel, reasoningLevel = null) {
  const anthropicRequest = {
    model: upstreamModel,
    messages: [],
    system: null,
    stream: false
  };

  if (reasoningLevel) {
    anthropicRequest.reasoningLevel = reasoningLevel;
  }

  if (body.messages) {
    const systemMsg = body.messages.find(m => m.role === 'system');
    if (systemMsg) {
      anthropicRequest.system = systemMsg.content;
    }

    anthropicRequest.messages = body.messages
      .filter(m => m.role !== 'system')
      .map(m => {
        if (m.role === 'tool') {
          return {
            role: 'user',
            content: [{
              type: 'tool_result',
              tool_use_id: m.tool_call_id,
              content: m.content
            }]
          };
        }

        if (m.role === 'assistant' && m.tool_calls) {
          const content = [{ type: 'text', text: m.content || '' }];
          for (const call of m.tool_calls) {
            let input = {};
            try {
              input = typeof call.function.arguments === 'string'
                ? JSON.parse(call.function.arguments)
                : call.function.arguments || {};
            } catch {
              input = {};
            }
            content.push({
              type: 'tool_use',
              id: call.id,
              name: call.function.name,
              input
            });
          }
          return { role: 'assistant', content };
        }

        return m;
      });
  }

  if (body.tools) {
    anthropicRequest.tools = body.tools.map(t => ({
      name: t.function.name,
      description: t.function.description,
      input_schema: t.function.parameters
    }));
  }

  return anthropicRequest;
}

/**
 * Converts an Anthropic-style response into an OpenAI Chat Completions response.
 * @param {object} response
 * @param {string} responseModel
 * @returns {object}
 */
function _buildOpenAIResponse(response, responseModel) {
  const content = response.content || [];
  const textContent = content.find(c => c.type === 'text');
  const toolUses = content.filter(c => c.type === 'tool_use');

  const message = {
    role: 'assistant',
    content: textContent?.text || ''
  };

  if (toolUses.length > 0) {
    message.tool_calls = toolUses.map(t => ({
      id: t.id,
      type: 'function',
      function: {
        name: t.name,
        arguments: JSON.stringify(t.input)
      }
    }));
  }

  return {
    id: response.id,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: responseModel,
    choices: [{
      index: 0,
      message,
      finish_reason: toolUses.length > 0 ? 'tool_calls' : 'stop'
    }],
    usage: {
      prompt_tokens: response.usage?.input_tokens || 0,
      completion_tokens: response.usage?.output_tokens || 0,
      total_tokens: (response.usage?.input_tokens || 0) + (response.usage?.output_tokens || 0)
    }
  };
}

function recordChatMetric(options) {
  const body = options.body || {};
  recordUsageEventSafe({
    startedAt: new Date(options.startTime || Date.now()).toISOString(),
    completedAt: new Date().toISOString(),
    endpoint: '/v1/chat/completions',
    requestedModel: options.requestedModel,
    upstreamModel: options.upstreamModel,
    accountLabel: options.accountLabel,
    provider: options.provider,
    stream: false,
    messageCount: Array.isArray(body.messages) ? body.messages.length : 0,
    toolCount: Array.isArray(body.tools) ? body.tools.length : 0,
    usage: options.usage,
    status: options.status,
    errorType: options.errorType,
    durationMs: options.duration ?? Date.now() - (options.startTime || Date.now())
  });
}

function classifyMetricError(error) {
  const message = error?.message || '';
  if (message.includes('AUTH_EXPIRED')) return 'auth_expired';
  if (message.startsWith('KILO_API_ERROR:')) return 'kilo_api_error';
  if (message.startsWith('API_ERROR:')) return 'api_error';
  return 'unknown_error';
}

export default { handleChatCompletion, handleCountTokens };

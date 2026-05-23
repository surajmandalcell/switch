import { sendMessageStream, sendMessage } from '../direct-api.js';
import { sendKiloMessageStream, sendKiloMessage } from '../kilo-api.js';
import { DEFAULT_OPENAI_MODEL, isKiloEnabled, resolveModelRouting } from '../model-mapper.js';
import { sendAuthError, getCredentialsOrError } from '../middleware/credentials.js';
import { initSSEResponse, pipeSSEStream, handleStreamError } from '../middleware/sse.js';
import { logger } from '../utils/logger.js';
import { recordUsageEventSafe, tapUsageEventStream } from '../usage-metrics.js';

export async function handleMessages(req, res) {
    const startTime = Date.now();
    const body = req.body;
    const requestedModel = body.model || DEFAULT_OPENAI_MODEL;
    const isStreaming = body.stream !== false;
    
    const { isKilo, kiloTarget, upstreamModel, reasoningLevel } = resolveModelRouting(requestedModel);
    
    if (isKilo) {
        if (!isKiloEnabled()) {
            recordMessageMetric({
                body,
                endpoint: '/v1/messages',
                requestedModel,
                upstreamModel,
                provider: 'kilo',
                accountLabel: 'kilo',
                startTime,
                status: 403,
                errorType: 'kilo_disabled'
            });
            return res.status(403).json({
                type: 'error',
                error: {
                    type: 'invalid_request_error',
                    code: 'kilo_disabled',
                    message: 'Kilo routing is disabled. Set CODEX_CLAUDE_PROXY_ENABLE_KILO=true to enable third-party Kilo model routing.'
                }
            });
        }

        return isStreaming
            ? _streamKilo(res, { ...body, model: upstreamModel }, kiloTarget, requestedModel, startTime)
            : _sendKilo(res, { ...body, model: upstreamModel }, kiloTarget, requestedModel, startTime);
    }

    const creds = await getCredentialsOrError();
    if (!creds) {
        recordMessageMetric({
            body,
            endpoint: '/v1/messages',
            requestedModel,
            upstreamModel,
            provider: 'openai',
            startTime,
            status: 401,
            errorType: 'auth_error'
        });
        return sendAuthError(res);
    }

    const anthropicRequest = { ...body, model: upstreamModel, ...(reasoningLevel ? { reasoningLevel } : {}) };
    try {
        if (isStreaming) {
            await _streamDirect(res, anthropicRequest, creds, requestedModel, startTime);
        } else {
            await _sendDirect(res, anthropicRequest, creds, requestedModel, startTime);
        }
        return;
    } catch (error) {
        recordMessageMetric({
            body,
            endpoint: '/v1/messages',
            requestedModel,
            upstreamModel,
            provider: 'openai',
            accountLabel: creds.email,
            startTime,
            status: error.message?.startsWith('RATE_LIMITED:') ? 429 : error.status || 500,
            errorType: classifyMetricError(error)
        });
        return handleStreamError(res, error, requestedModel, startTime);
    }
}

async function _streamDirect(res, anthropicRequest, creds, responseModel, startTime) {
    initSSEResponse(res);
    const sourceStream = sendMessageStream(anthropicRequest, creds.accessToken, creds.accountId);
    let finalUsage = null;
    const stream = tapUsageEventStream(sourceStream, (usage) => {
        finalUsage = usage;
        recordMessageMetric({
            body: anthropicRequest,
            endpoint: '/v1/messages',
            requestedModel: responseModel,
            upstreamModel: anthropicRequest.model,
            provider: 'openai',
            accountLabel: creds.email,
            stream: true,
            usage,
            startTime,
            status: 200
        });
    });
    await pipeSSEStream(res, stream);
    logger.response(200, { model: anthropicRequest.model, usage: finalUsage, duration: Date.now() - startTime });
}

async function _sendDirect(res, anthropicRequest, creds, responseModel, startTime) {
    const response = await sendMessage(anthropicRequest, creds.accessToken, creds.accountId);
    const duration = Date.now() - startTime;
    logger.response(200, { model: anthropicRequest.model, usage: response.usage, duration });
    recordMessageMetric({
        body: anthropicRequest,
        endpoint: '/v1/messages',
        requestedModel: responseModel,
        upstreamModel: anthropicRequest.model,
        provider: 'openai',
        accountLabel: creds.email,
        stream: false,
        usage: response.usage,
        startTime,
        status: 200,
        duration
    });
    res.json({ ...response, model: responseModel });
}

async function _streamKilo(res, anthropicRequest, kiloTarget, responseModel, startTime) {
    initSSEResponse(res);
    const sourceStream = sendKiloMessageStream(anthropicRequest, kiloTarget);
    let finalUsage = null;
    const stream = tapUsageEventStream(sourceStream, (usage) => {
        finalUsage = usage;
        recordMessageMetric({
            body: anthropicRequest,
            endpoint: '/v1/messages',
            requestedModel: responseModel,
            upstreamModel: kiloTarget,
            provider: 'kilo',
            accountLabel: 'kilo',
            stream: true,
            usage,
            startTime,
            status: 200
        });
    });
    await pipeSSEStream(res, stream);
    logger.response(200, { model: kiloTarget, usage: finalUsage, duration: Date.now() - startTime });
}

async function _sendKilo(res, anthropicRequest, kiloTarget, responseModel, startTime) {
    const response = await sendKiloMessage(anthropicRequest, kiloTarget);
    const duration = Date.now() - startTime;
    logger.response(200, { model: kiloTarget, usage: response.usage, duration });
    recordMessageMetric({
        body: anthropicRequest,
        endpoint: '/v1/messages',
        requestedModel: responseModel,
        upstreamModel: kiloTarget,
        provider: 'kilo',
        accountLabel: 'kilo',
        stream: false,
        usage: response.usage,
        startTime,
        status: 200,
        duration
    });
    res.json({
        id: response.id || undefined,
        type: 'message',
        role: 'assistant',
        content: response.content,
        model: responseModel,
        stop_reason: response.stopReason,
        stop_sequence: null,
        usage: response.usage
    });
}

function recordMessageMetric(options) {
    const body = options.body || {};
    recordUsageEventSafe({
        startedAt: new Date(options.startTime || Date.now()).toISOString(),
        completedAt: new Date().toISOString(),
        endpoint: options.endpoint,
        requestedModel: options.requestedModel,
        upstreamModel: options.upstreamModel,
        accountLabel: options.accountLabel,
        provider: options.provider,
        stream: options.stream ?? body.stream !== false,
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
    if (message.startsWith('RATE_LIMITED:')) return 'rate_limited';
    if (message.includes('AUTH_EXPIRED')) return 'auth_expired';
    if (message.startsWith('CLOUDFLARE_BLOCKED:')) return 'cloudflare_blocked';
    if (message.startsWith('FORBIDDEN:')) return 'forbidden';
    if (message.startsWith('INVALID_REQUEST:')) return 'invalid_request';
    if (message.startsWith('KILO_API_ERROR:')) return 'kilo_api_error';
    if (message.startsWith('API_ERROR:')) return 'api_error';
    return 'unknown_error';
}

export default { handleMessages };

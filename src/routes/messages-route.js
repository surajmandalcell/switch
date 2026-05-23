import { sendMessageStream, sendMessage } from '../direct-api.js';
import { sendKiloMessageStream, sendKiloMessage } from '../kilo-api.js';
import { DEFAULT_OPENAI_MODEL, isKiloEnabled, resolveModelRouting } from '../model-mapper.js';
import { sendAuthError, getCredentialsOrError, getCredentialsForAccount } from '../middleware/credentials.js';
import { initSSEResponse, pipeSSEStream, handleStreamError } from '../middleware/sse.js';
import { logger } from '../utils/logger.js';
import { AccountRotator } from '../account-rotation/index.js';
import { listAccounts, getActiveAccount, save } from '../account-manager.js';
import { getServerSettings, isMultiAccountRotationEnabled } from '../server-settings.js';
import { recordUsageEventSafe, tapUsageEventStream } from '../usage-metrics.js';

const MAX_RETRIES = 5;
const MAX_WAIT_BEFORE_ERROR_MS = 120000;
const SHORT_RATE_LIMIT_THRESHOLD_MS = 5000;

let accountRotator = null;
let currentStrategy = null;

function getAccountRotator() {
    const settings = getServerSettings();
    const strategy = settings.accountStrategy || 'sticky';
    
    if (!accountRotator || currentStrategy !== strategy) {
        accountRotator = new AccountRotator({
            listAccounts,
            save,
            getActiveAccount
        }, strategy);
        currentStrategy = strategy;
        logger.info(`[Messages] Account strategy: ${strategy}`);
    }
    return accountRotator;
}

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

    if (!isMultiAccountRotationEnabled()) {
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
                await _streamDirectWithRotation(res, anthropicRequest, creds, requestedModel, startTime, null);
            } else {
                await _sendDirectWithRotation(res, anthropicRequest, creds, requestedModel, startTime, null);
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
                status: error.status || 500,
                errorType: classifyMetricError(error)
            });
            return handleStreamError(res, error, requestedModel, startTime);
        }
    }
    
    const rotator = getAccountRotator();
    const accountSnapshot = listAccounts();

    if (accountSnapshot.total === 0) {
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
        return sendAuthError(res, 'No active account with valid credentials. Add an account via /accounts/add');
    }
    
    rotator.clearExpiredLimits();
    
    const maxAttempts = Math.max(MAX_RETRIES, accountSnapshot.total);
    
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
        if (rotator.isAllRateLimited(upstreamModel)) {
            const minWait = rotator.getMinWaitTimeMs(upstreamModel);
            
            if (minWait > MAX_WAIT_BEFORE_ERROR_MS) {
                recordMessageMetric({
                    body,
                    endpoint: '/v1/messages',
                    requestedModel,
                    upstreamModel,
                    provider: 'openai',
                    startTime,
                    status: 429,
                    errorType: 'rate_limited'
                });
                return handleStreamError(res, new Error(`RESOURCE_EXHAUSTED: All accounts rate-limited. Wait ${Math.round(minWait/1000)}s`), requestedModel, startTime);
            }
            
            logger.info(`[Messages] All accounts rate-limited, waiting ${Math.round(minWait/1000)}s...`);
            await sleep(minWait + 500);
            rotator.clearExpiredLimits();
            attempt--;
            continue;
        }
        
        const { account, waitMs } = rotator.selectAccount(upstreamModel);
        
        if (!account) {
            if (waitMs > 0) {
                await sleep(waitMs);
                attempt--;
                continue;
            }
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
            return sendAuthError(res, 'No available accounts');
        }
        
        const creds = await getCredentialsForAccount(account.email);
        if (!creds) {
            rotator.markInvalid(account.email, 'Failed to get credentials');
            continue;
        }
        
        const anthropicRequest = { ...body, model: upstreamModel, ...(reasoningLevel ? { reasoningLevel } : {}) };
        
        try {
            if (isStreaming) {
                await _streamDirectWithRotation(res, anthropicRequest, creds, requestedModel, startTime, rotator);
            } else {
                await _sendDirectWithRotation(res, anthropicRequest, creds, requestedModel, startTime, rotator);
            }
            rotator.notifySuccess(account, upstreamModel);
            return;
        } catch (error) {
            if (error.message.startsWith('RATE_LIMITED:')) {
                const parts = error.message.split(':');
                const resetMs = parseInt(parts[1], 10);
                const errorText = parts.slice(2).join(':');
                
                rotator.notifyRateLimit(account, upstreamModel);
                
                if (resetMs <= SHORT_RATE_LIMIT_THRESHOLD_MS) {
                    logger.info(`[Messages] Short rate limit on ${account.email}, waiting ${resetMs}ms...`);
                    await sleep(resetMs);
                    attempt--;
                    continue;
                }
                
                logger.info(`[Messages] Rate limit on ${account.email}, switching account...`);
                continue;
            }
            
            if (error.message.includes('AUTH_EXPIRED')) {
                rotator.markInvalid(account.email, 'Auth expired');
                continue;
            }
            
            recordMessageMetric({
                body,
                endpoint: '/v1/messages',
                requestedModel,
                upstreamModel,
                provider: 'openai',
                accountLabel: account.email,
                startTime,
                status: error.status || 500,
                errorType: classifyMetricError(error)
            });
            return handleStreamError(res, error, requestedModel, startTime);
        }
    }
    
    recordMessageMetric({
        body,
        endpoint: '/v1/messages',
        requestedModel,
        upstreamModel,
        provider: 'openai',
        startTime,
        status: 500,
        errorType: 'max_retries'
    });
    return handleStreamError(res, new Error('Max retries exceeded'), requestedModel, startTime);
}

async function _streamDirectWithRotation(res, anthropicRequest, creds, responseModel, startTime, rotator) {
    initSSEResponse(res);
    const sourceStream = sendMessageStream(anthropicRequest, creds.accessToken, creds.accountId, rotator, creds.email);
    const stream = tapUsageEventStream(sourceStream, (usage) => {
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
    logger.response(200, { model: anthropicRequest.model, duration: Date.now() - startTime });
}

async function _sendDirectWithRotation(res, anthropicRequest, creds, responseModel, startTime, rotator) {
    const response = await sendMessage(anthropicRequest, creds.accessToken, creds.accountId);
    const duration = Date.now() - startTime;
    logger.response(200, { model: anthropicRequest.model, tokens: response.usage?.output_tokens || 0, duration });
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
    const stream = tapUsageEventStream(sourceStream, (usage) => {
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
    logger.response(200, { model: kiloTarget, duration: Date.now() - startTime });
}

async function _sendKilo(res, anthropicRequest, kiloTarget, responseModel, startTime) {
    const response = await sendKiloMessage(anthropicRequest, kiloTarget);
    const duration = Date.now() - startTime;
    logger.response(200, { model: kiloTarget, tokens: response.usage?.output_tokens || 0, duration });
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

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
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
    if (message.startsWith('RATE_LIMITED:') || message.startsWith('RESOURCE_EXHAUSTED:')) return 'rate_limited';
    if (message.includes('AUTH_EXPIRED')) return 'auth_expired';
    if (message.startsWith('CLOUDFLARE_BLOCKED:')) return 'cloudflare_blocked';
    if (message.startsWith('FORBIDDEN:')) return 'forbidden';
    if (message.startsWith('INVALID_REQUEST:')) return 'invalid_request';
    if (message.startsWith('KILO_API_ERROR:')) return 'kilo_api_error';
    if (message.startsWith('API_ERROR:')) return 'api_error';
    return 'unknown_error';
}

export default { handleMessages };

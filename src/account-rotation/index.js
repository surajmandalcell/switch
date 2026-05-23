import {
    markRateLimited,
    markInvalid,
    clearInvalid,
    isAllRateLimited,
    getMinWaitTimeMs,
    clearExpiredLimits,
    isAccountCoolingDown
} from './rate-limits.js';

const MAX_WAIT_BEFORE_ERROR_MS = 120000;

export class AccountRotator {
    constructor(accountManager) {
        this.accountManager = accountManager;
    }

    selectAccount(modelId) {
        const { accounts } = this.accountManager.listAccounts();
        return selectAccount(accounts, modelId);
    }

    markRateLimited(email, resetMs, modelId) {
        const { accounts } = this.accountManager.listAccounts();
        markRateLimited(accounts, email, resetMs, modelId);
        this.accountManager.save();
    }

    markInvalid(email, reason) {
        const { accounts } = this.accountManager.listAccounts();
        markInvalid(accounts, email, reason);
        this.accountManager.save();
    }

    clearInvalid(email) {
        const { accounts } = this.accountManager.listAccounts();
        clearInvalid(accounts, email);
        this.accountManager.save();
    }

    isAllRateLimited(modelId) {
        const { accounts } = this.accountManager.listAccounts();
        return isAllRateLimited(accounts, modelId);
    }

    getMinWaitTimeMs(modelId) {
        const { accounts } = this.accountManager.listAccounts();
        return getMinWaitTimeMs(accounts, modelId);
    }

    notifySuccess(account, modelId) {}

    notifyRateLimit(account, modelId) {}

    notifyFailure(account, modelId) {}

    clearExpiredLimits() {
        const { accounts } = this.accountManager.listAccounts();
        clearExpiredLimits(accounts);
        this.accountManager.save();
    }

}

function selectAccount(accounts, modelId) {
    if (!accounts || accounts.length === 0) {
        return { account: null, index: 0, waitMs: 0 };
    }

    const activeIndex = accounts.findIndex((account) => account.isActive);
    const startIndex = activeIndex >= 0 ? activeIndex : 0;

    for (let offset = 0; offset < accounts.length; offset++) {
        const index = (startIndex + offset) % accounts.length;
        const account = accounts[index];

        if (isAccountUsable(account, modelId)) {
            account.lastUsed = Date.now();
            return { account, index, waitMs: 0 };
        }
    }

    const waitMs = getAccountWaitMs(accounts[startIndex], modelId);
    if (waitMs > 0 && waitMs <= MAX_WAIT_BEFORE_ERROR_MS) {
        return { account: null, index: startIndex, waitMs };
    }

    return { account: null, index: startIndex, waitMs: 0 };
}

function isAccountUsable(account, modelId) {
    if (!account) return false;
    if (account.isInvalid) return false;
    if (account.enabled === false) return false;
    if (isAccountCoolingDown(account)) return false;

    const waitMs = getModelRateLimitWaitMs(account, modelId);
    return waitMs === 0;
}

function getAccountWaitMs(account, modelId) {
    if (!account) return 0;
    if (account.isInvalid) return 0;
    if (account.enabled === false) return 0;
    if (isAccountCoolingDown(account)) return 0;

    return getModelRateLimitWaitMs(account, modelId);
}

function getModelRateLimitWaitMs(account, modelId) {
    if (!modelId || !account?.modelRateLimits?.[modelId]) {
        return 0;
    }

    const limit = account.modelRateLimits[modelId];
    if (!limit?.isRateLimited || !limit.resetTime || limit.resetTime <= Date.now()) {
        return 0;
    }

    return limit.resetTime - Date.now();
}

export {
    markRateLimited,
    markInvalid,
    clearInvalid,
    isAllRateLimited,
    getMinWaitTimeMs,
    clearExpiredLimits
};

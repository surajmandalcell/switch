import test from 'node:test';
import assert from 'node:assert/strict';

import { AccountRotator } from '../../src/account-rotation/index.js';

function createTestAccounts() {
    return [
        { email: 'account1@test.com', isActive: true, modelRateLimits: {} },
        { email: 'account2@test.com', modelRateLimits: {} },
        { email: 'account3@test.com', modelRateLimits: {} }
    ];
}

function createAccountManager(accounts = createTestAccounts()) {
    return {
        listAccounts() {
            return {
                accounts,
                activeAccount: accounts.find((account) => account.isActive)?.email || null,
                total: accounts.length
            };
        },
        save() {}
    };
}

test('AccountRotator: ignores legacy strategy constructor argument and prefers active account', () => {
    const accounts = createTestAccounts();
    const rotator = new AccountRotator(createAccountManager(accounts), 'round-robin');

    const first = rotator.selectAccount('gpt-5.2');
    const second = rotator.selectAccount('gpt-5.2');

    assert.equal(first.account.email, 'account1@test.com');
    assert.equal(second.account.email, 'account1@test.com');
});

test('AccountRotator: falls back to the next usable account when active account is rate-limited', () => {
    const accounts = createTestAccounts();
    accounts[0].modelRateLimits['gpt-5.2'] = { isRateLimited: true, resetTime: Date.now() + 60000 };
    const rotator = new AccountRotator(createAccountManager(accounts));

    const result = rotator.selectAccount('gpt-5.2');
    assert.equal(result.account.email, 'account2@test.com');
});

test('AccountRotator: returns null when no account is usable', () => {
    const accounts = createTestAccounts();
    accounts.forEach((account) => {
        account.isInvalid = true;
    });
    const rotator = new AccountRotator(createAccountManager(accounts));

    const result = rotator.selectAccount('gpt-5.2');
    assert.equal(result.account, null);
});

test('AccountRotator: does not expose strategy metadata', () => {
    const rotator = new AccountRotator(createAccountManager());
    assert.equal('getStrategyName' in rotator, false);
    assert.equal('getStrategyLabel' in rotator, false);
});

test('AccountRotator: treats expired model rate limits as usable', () => {
    const accounts = createTestAccounts();
    accounts[0].modelRateLimits['gpt-5.2'] = { isRateLimited: true, resetTime: Date.now() - 1000 };
    const rotator = new AccountRotator(createAccountManager(accounts));

    const result = rotator.selectAccount('gpt-5.2');
    assert.equal(result.account.email, 'account1@test.com');
});

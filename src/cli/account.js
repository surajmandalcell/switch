#!/usr/bin/env node

import { createInterface } from 'readline/promises';
import { stdin, stdout } from 'process';
import { spawn } from 'child_process';
import net from 'net';

import {
    OAUTH_CONFIG,
    generatePKCE,
    generateState,
    getAuthorizationUrl,
    extractCodeFromInput,
    exchangeCodeForTokens,
    extractAccountInfo
} from '../oauth.js';
import {
    ACCOUNT_FILE,
    getActiveAccount,
    listAccounts,
    refreshActiveAccount,
    removeAccount,
    setConfiguredAccount
} from '../account-manager.js';

const DEFAULT_PORT = 8081;

function createRL() {
    return createInterface({ input: stdin, output: stdout });
}

function openBrowser(url) {
    const platform = process.platform;
    let command;
    let args;

    if (platform === 'darwin') {
        command = 'open';
        args = [url];
    } else if (platform === 'win32') {
        command = 'cmd';
        args = ['/c', 'start', '', url.replace(/&/g, '^&')];
    } else {
        command = 'xdg-open';
        args = [url];
    }

    const child = spawn(command, args, { stdio: 'ignore', detached: true });
    child.on('error', () => {
        console.log('\nCould not open browser automatically.');
        console.log('Please open this URL manually:', url);
    });
    child.unref();
}

function isServerRunning(port) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        socket.setTimeout(1000);
        socket.on('connect', () => {
            socket.destroy();
            resolve(true);
        });
        socket.on('timeout', () => {
            socket.destroy();
            resolve(false);
        });
        socket.on('error', () => {
            socket.destroy();
            resolve(false);
        });
        socket.connect(port, 'localhost');
    });
}

async function ensureServerStopped(port) {
    if (await isServerRunning(port)) {
        console.error(`
Error: Proxy server is currently running on port ${port}.

Please stop the server before changing the configured account from the CLI.
Use the dashboard while the server is running.
`);
        process.exit(1);
    }
}

function buildAccount(tokens) {
    const accountInfo = extractAccountInfo(tokens.accessToken);
    return {
        email: accountInfo?.email || 'unknown',
        accountId: accountInfo?.accountId,
        planType: accountInfo?.planType || 'free',
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        idToken: tokens.idToken,
        expiresAt: accountInfo?.expiresAt || (Date.now() + tokens.expiresIn * 1000),
        addedAt: new Date().toISOString(),
        lastUsed: null
    };
}

async function addAccount(rl, { noBrowser }) {
    console.log(noBrowser ? '\n=== Configure Account (No-Browser Mode) ===\n' : '\n=== Configure Account ===\n');

    const { verifier } = generatePKCE();
    const state = generateState();
    const url = getAuthorizationUrl(verifier, state, OAUTH_CONFIG.callbackPort);

    if (noBrowser) {
        console.log('Copy this URL and open it in a browser on another device:\n');
    } else {
        console.log('Opening browser for ChatGPT sign-in...');
        console.log('(If the browser does not open, copy this URL manually)\n');
        openBrowser(url);
    }

    console.log(`   ${url}\n`);
    console.log('After signing in, paste the full callback URL or authorization code.\n');

    const input = await rl.question('Callback URL or authorization code: ');

    try {
        const { code, state: extractedState, port } = extractCodeFromInput(input);
        if (extractedState && extractedState !== state) {
            throw new Error('OAuth state mismatch. Refusing to exchange the authorization code.');
        }

        console.log('\nExchanging authorization code for tokens...');
        const tokens = await exchangeCodeForTokens(code, verifier, port || OAUTH_CONFIG.callbackPort);
        const account = buildAccount(tokens);
        setConfiguredAccount(account);
        console.log(`\nConfigured account: ${account.email}`);
    } catch (error) {
        console.error(`\nAuthentication failed: ${error.message}`);
        process.exitCode = 1;
    }
}

function showAccount() {
    const { account } = listAccounts();
    if (!account) {
        console.log('\nNo account configured.');
        console.log(`Config file: ${ACCOUNT_FILE}`);
        return;
    }

    console.log('\nConfigured account:');
    console.log(`  Email: ${account.email}`);
    console.log(`  Plan: ${account.planType}`);
    console.log(`  Token: ${account.tokenExpired ? 'expired' : 'valid'}`);
    console.log(`  Config file: ${ACCOUNT_FILE}`);
}

async function verifyAccount() {
    const account = getActiveAccount();
    if (!account) {
        console.log('No account configured.');
        return;
    }

    const result = await refreshActiveAccount();
    console.log(result.success ? `OK: ${account.email}` : `Failed: ${result.message}`);
    if (!result.success) process.exitCode = 1;
}

async function removeConfiguredAccount(rl) {
    const account = getActiveAccount();
    if (!account) {
        console.log('No account configured.');
        return;
    }

    const confirm = await rl.question(`Remove configured account ${account.email}? [y/N]: `);
    if (confirm.toLowerCase() !== 'y') {
        console.log('Cancelled.');
        return;
    }

    const result = removeAccount();
    console.log(result.message);
}

function showHelp() {
    console.log(`
Usage:
  codex-proxy account add               Configure account (opens browser)
  codex-proxy account add --no-browser  Configure account manually
  codex-proxy account show              Show configured account
  codex-proxy account verify            Refresh and verify configured account
  codex-proxy account remove            Remove configured account
  codex-proxy account clear             Remove configured account
  codex-proxy account help              Show this help

Adding or importing an account replaces the existing local account.
`);
}

async function main() {
    const args = process.argv.slice(2);
    const command = args[0] || 'help';
    const noBrowser = args.includes('--no-browser');
    const port = parseInt(args.find(a => a.startsWith('--port='))?.split('=')[1]) || DEFAULT_PORT;
    const rl = createRL();

    try {
        switch (command) {
            case 'add':
                await ensureServerStopped(port);
                await addAccount(rl, { noBrowser });
                break;
            case 'show':
                showAccount();
                break;
            case 'verify':
                await verifyAccount();
                break;
            case 'remove':
            case 'clear':
                await ensureServerStopped(port);
                await removeConfiguredAccount(rl);
                break;
            case 'help':
            default:
                showHelp();
                break;
        }
    } finally {
        rl.close();
    }
}

main().catch((error) => {
    console.error('Error:', error.message);
    process.exit(1);
});

document.addEventListener('alpine:init', () => {
    const validTabs = ['dashboard', 'accounts', 'logs', 'settings'];
    const initialTab = () => {
        const params = new URLSearchParams(window.location.search);
        const requested = params.get('tab') || window.location.hash.replace(/^#/, '');
        return validTabs.includes(requested) ? requested : 'dashboard';
    };

    Alpine.data('app', () => ({
        version: '1.0.6',
        connectionStatus: 'connecting',
        activeTab: initialTab(),
        sidebarOpen: window.innerWidth >= 1024,
        loading: false,
        toast: null,
        currentTime: '',
        
        accounts: [],
        searchQuery: '',
        stats: { total: 0, active: 0, expired: 0, planType: '-' },

        haikuKiloModel: 'minimax/minimax-m2.5:free',
        modelMappings: { opus: 'gpt-5.5', sonnet: 'gpt-5.5', haiku: 'gpt-5.4-mini' },
        modelMappingDefaults: { opus: 'gpt-5.5', sonnet: 'gpt-5.5', haiku: 'gpt-5.4-mini' },
        reasoningMappings: { opus: 'high', sonnet: 'medium', haiku: 'low' },
        reasoningMappingDefaults: { opus: 'high', sonnet: 'medium', haiku: 'low' },
        openAiModelOptions: [],
        reasoningLevelOptions: [],
        modelMappingSaving: null,
        reasoningMappingSaving: null,
        accountStrategy: 'sticky',
        multiAccountRotationEnabled: false,
        haikuModelSaving: false,
        strategySaving: false,
        configureClaudeOnStartup: false,
        claudeProxyConfiguring: false,
        claudeProxyStartupSaving: false,
        kiloEnabled: false,
        kiloModels: [],
        kiloModelsLoading: false,

        showAddModal: false,
        showDeleteModal: false,
        deleteTarget: '',
        showQuotaModalView: false,
        selectedAccount: null,
        
        oauthManualMode: false,
        oauthManualUrl: '',
        oauthManualPort: null,
        oauthManualCode: '',
        
        testPrompt: 'Say hello',
        testResponse: '',
        testing: false,

        haikuTestPrompt: 'Say hello',
        haikuTestResponse: '',
        haikuTesting: false,

        haikuModelLabel() {
            return this.modelOptionName(this.modelMappings?.haiku || 'gpt-5.4-mini');
        },

        async testHaikuChat() {
            if (!this.haikuTestPrompt.trim()) return;
            this.haikuTesting = true;
            this.haikuTestResponse = '';
            const { ok, data } = await this.api('/v1/chat/completions', {
                method: 'POST',
                body: JSON.stringify({
                    model: 'claude-haiku-4',
                    messages: [{ role: 'user', content: this.haikuTestPrompt }]
                })
            });
            this.haikuTesting = false;
            if (ok && data.choices) {
                this.haikuTestResponse = data.choices[0].message.content;
            } else {
                this.haikuTestResponse = data?.error?.message || 'Request failed';
            }
        },
        
        configPath: '~/.codex-claude-proxy/accounts.json',
        serverUrl: window.location.origin,
        
        logs: [],
        logSearchQuery: '',
        logFilters: { INFO: true, SUCCESS: true, WARN: true, ERROR: true, DEBUG: false },
        logEventSource: null,

        get filteredLogs() {
            const query = this.logSearchQuery.trim().toLowerCase();
            return this.logs.filter(log => {
                if (!this.logFilters[log.level]) return false;
                if (query && !log.message.toLowerCase().includes(query)) return false;
                return true;
            });
        },

        get filteredAccounts() {
            if (!this.searchQuery) return this.accounts;
            const q = this.searchQuery.toLowerCase();
            return this.accounts.filter(a => a.email.toLowerCase().includes(q));
        },

        init() {
            this.updateTime();
            setInterval(() => this.updateTime(), 1000);
            this.refreshAccounts();
            this.checkHealth();
            setInterval(() => this.checkHealth(), 30000);
            this.startLogStream();
            this.loadModelMappingsSetting();
            this.loadHaikuModelSetting();
            this.loadAccountStrategySetting();
            this.loadClaudeProxySetting();

            window.addEventListener('resize', () => {
                this.sidebarOpen = window.innerWidth >= 1024;
            });

            window.addEventListener('message', (event) => {
                if (event.data && event.data.type === 'oauth-success') {
                    this.showToast(`Account ${event.data.email} added!`, 'success');
                    this.showAddModal = false;
                    this.refreshAccounts();
                }
            });
        },

        updateTime() {
            this.currentTime = new Date().toLocaleTimeString([], {hour: '2-digit', minute: '2-digit', second: '2-digit'});
        },

        setActiveTab(tab) {
            if (!validTabs.includes(tab)) return;
            this.activeTab = tab;
            const nextUrl = new URL(window.location.href);
            if (tab === 'dashboard') {
                nextUrl.searchParams.delete('tab');
                nextUrl.hash = '';
            } else {
                nextUrl.searchParams.set('tab', tab);
                nextUrl.hash = '';
            }
            window.history.replaceState({}, '', nextUrl);
            if (window.innerWidth < 1024) {
                this.sidebarOpen = false;
            }
        },

        async api(endpoint, options = {}) {
            try {
                const response = await fetch(endpoint, {
                    headers: { 'Content-Type': 'application/json' },
                    ...options
                });
                const data = await response.json();
                return { ok: response.ok, data };
            } catch (error) {
                return { ok: false, error: error.message };
            }
        },

        async checkHealth() {
            const { ok } = await this.api('/health');
            this.connectionStatus = ok ? 'connected' : 'disconnected';
        },

        async refreshAccounts() {
            this.loading = true;
            const { ok, data } = await this.api('/accounts');
            
            if (ok && data.accounts) {
                this.accounts = data.accounts;
                this.stats = {
                    total: data.total || data.accounts.length,
                    active: data.accounts.filter(a => a.isActive).length,
                    expired: data.accounts.filter(a => a.tokenExpired).length,
                    planType: data.accounts.find(a => a.isActive)?.planType || '-'
                };

                await this.refreshAllQuotaData();
            }
            this.loading = false;
        },

        async refreshAllQuotaData() {
            if (!this.accounts.length) return;
            const { ok, data } = await this.api('/accounts/quota/all');
            if (!ok || !data?.accounts) return;

            const quotaMap = new Map(
                data.accounts.map((entry) => [entry.email, entry.quota || null])
            );

            this.accounts = this.accounts.map((account) => ({
                ...account,
                quota: quotaMap.has(account.email) ? quotaMap.get(account.email) : account.quota
            }));

            if (this.selectedAccount?.email) {
                const refreshed = this.accounts.find((account) => account.email === this.selectedAccount.email);
                if (refreshed) this.selectedAccount = refreshed;
            }
        },

        getRemainingPercentage(account) {
            const usage = account?.quota?.usage;
            if (!usage) return null;

            const percentage = Number(usage.percentage);
            const usedFromTotal = Number(usage.totalTokenUsage);
            const remainingFromApi = Number(usage.remaining);

            let used = null;
            if (Number.isFinite(percentage)) {
                used = percentage;
            } else if (Number.isFinite(usedFromTotal)) {
                used = usedFromTotal;
            } else if (Number.isFinite(remainingFromApi)) {
                used = 100 - remainingFromApi;
            } else if (usage.limitReached === true || usage.allowed === false) {
                used = 100;
            }

            if (!Number.isFinite(used)) return null;
            const clampedUsed = Math.max(0, Math.min(100, used));
            return Math.max(0, Math.round(100 - clampedUsed));
        },

        isQuotaExhausted(account) {
            const remaining = this.getRemainingPercentage(account);
            if (remaining === null) return false;
            const usage = account?.quota?.usage;
            return remaining <= 0 || usage?.limitReached === true || usage?.allowed === false;
        },

        quotaBarClass(account) {
            const remaining = this.getRemainingPercentage(account);
            if (remaining === null) return 'bg-gray-500';
            if (remaining > 50) return 'bg-neon-green';
            if (remaining > 20) return 'bg-yellow-500';
            return 'bg-red-500';
        },

        quotaTextClass(account) {
            const remaining = this.getRemainingPercentage(account);
            if (remaining === null) return 'text-gray-500';
            return remaining <= 20 ? 'text-red-400' : 'text-gray-400';
        },

        quotaLabel(account) {
            const remaining = this.getRemainingPercentage(account);
            if (remaining === null) return '-';
            return `${remaining}%`;
        },

        getQuotaResetAt(account) {
            const usage = account?.quota?.usage;
            if (!usage) return null;

            if (usage.resetAt) return usage.resetAt;

            const epoch = Number(usage?.raw?.rate_limit?.primary_window?.reset_at);
            if (Number.isFinite(epoch)) {
                return new Date(epoch * 1000).toISOString();
            }

            const resetAfter = Number(
                usage.resetAfterSeconds ?? usage?.raw?.rate_limit?.primary_window?.reset_after_seconds
            );
            if (Number.isFinite(resetAfter) && resetAfter > 0) {
                return new Date(Date.now() + resetAfter * 1000).toISOString();
            }

            return null;
        },

        quotaResetAtLabel(account) {
            const resetAt = this.getQuotaResetAt(account);
            if (!resetAt) return null;
            const date = new Date(resetAt);
            if (Number.isNaN(date.getTime())) return null;
            return date.toLocaleString();
        },

        quotaResetSummary(account) {
            const resetAt = this.getQuotaResetAt(account);
            if (!resetAt) return null;

            const resetMs = new Date(resetAt).getTime();
            if (!Number.isFinite(resetMs)) return null;

            const deltaSec = Math.max(0, Math.floor((resetMs - Date.now()) / 1000));
            if (deltaSec === 0) return 'Reset due now';

            const days = Math.floor(deltaSec / 86400);
            const hours = Math.floor((deltaSec % 86400) / 3600);
            const minutes = Math.floor((deltaSec % 3600) / 60);

            if (days > 0) return `Resets in ${days}d ${hours}h`;
            if (hours > 0) return `Resets in ${hours}h ${minutes}m`;
            return `Resets in ${minutes}m`;
        },

        async startOAuth() {
            await this.api('/accounts/oauth/cleanup', { method: 'POST' });
            const { ok, data } = await this.api('/accounts/add', { method: 'POST' });
            
            if (ok && data.oauth_url) {
                const width = 500, height = 700;
                const left = (screen.width - width) / 2;
                const top = (screen.height - height) / 2;
                window.open(data.oauth_url, 'ChatGPT Login', `width=${width},height=${height},left=${left},top=${top}`);
                
                const checkAdded = setInterval(async () => {
                    const { ok, data } = await this.api('/accounts');
                    if (ok && data.accounts?.length > this.accounts.length) {
                        clearInterval(checkAdded);
                        this.showAddModal = false;
                        this.refreshAccounts();
                    }
                }, 2000);
                
                setTimeout(() => clearInterval(checkAdded), 120000);
            } else {
                this.showToast(data?.message || 'Failed to start OAuth', 'error');
            }
        },

        async startManualOAuth() {
            await this.api('/accounts/oauth/cleanup', { method: 'POST' });
            const { ok, data } = await this.api('/accounts/add', { method: 'POST' });
            
            if (ok && data.oauth_url) {
                this.oauthManualUrl = data.oauth_url;
                this.oauthManualPort = data.callback_port || null;
                this.oauthManualCode = '';
                this.oauthManualMode = true;
            } else {
                this.showToast(data?.message || 'Failed to start OAuth', 'error');
            }
        },

        async submitManualOAuth() {
            if (!this.oauthManualCode) return;
            
            const { ok, data } = await this.api('/accounts/add/manual', {
                method: 'POST',
                body: JSON.stringify({
                    code: this.oauthManualCode,
                    port: this.oauthManualPort
                })
            });
            
            if (ok && data.success) {
                this.showToast(data.message, 'success');
                this.showAddModal = false;
                this.oauthManualMode = false;
                this.refreshAccounts();
            } else {
                this.showToast(data?.error || 'Failed to add account', 'error');
            }
        },

        async copyToClipboard(text) {
            try {
                await navigator.clipboard.writeText(text);
                this.showToast('Copied to clipboard', 'success');
            } catch (e) {
                this.showToast('Failed to copy', 'error');
            }
        },

        async importFromCodex() {
            const { ok, data } = await this.api('/accounts/import', { method: 'POST' });
            if (ok && data.success) {
                this.showToast(data.message, 'success');
                this.showAddModal = false;
                this.refreshAccounts();
            } else {
                this.showToast(data?.message || 'Import failed', 'error');
            }
        },

        async switchAccount(email) {
            const { ok, data } = await this.api('/accounts/switch', {
                method: 'POST',
                body: JSON.stringify({ email })
            });
            if (ok && data.success) {
                this.showToast(data.message, 'success');
                this.refreshAccounts();
            } else {
                this.showToast(data?.message || 'Failed to switch', 'error');
            }
        },

        async refreshToken(email) {
            const { ok, data } = await this.api(`/accounts/${encodeURIComponent(email)}/refresh`, { method: 'POST' });
            if (ok && data.success) {
                this.showToast(data.message, 'success');
                this.refreshAccounts();
            } else {
                this.showToast(data?.message || 'Refresh failed', 'error');
            }
        },

        async refreshAllTokens() {
            this.showToast('Refreshing all tokens...', 'info');
            const { ok, data } = await this.api('/accounts/refresh/all', { method: 'POST' });
            if (ok) {
                this.showToast(data.message, 'success');
                this.refreshAccounts();
            } else {
                this.showToast(data?.message || 'Failed', 'error');
            }
        },

        confirmDelete(email) {
            this.deleteTarget = email;
            this.showDeleteModal = true;
        },

        async executeDelete() {
            const { ok, data } = await this.api(`/accounts/${encodeURIComponent(this.deleteTarget)}`, { method: 'DELETE' });
            this.showDeleteModal = false;
            if (ok && data.success) {
                this.showToast(data.message, 'success');
                this.refreshAccounts();
            } else {
                this.showToast(data?.message || 'Delete failed', 'error');
            }
        },

        showQuotaModal(acc) {
            this.selectedAccount = acc;
            this.showQuotaModalView = true;
        },

        async testChat() {
            if (!this.testPrompt.trim()) return;
            this.testing = true;
            this.testResponse = '';
            const { ok, data } = await this.api('/v1/chat/completions', {
                method: 'POST',
                body: JSON.stringify({
                    model: 'gpt-5.5',
                    messages: [{ role: 'user', content: this.testPrompt }]
                })
            });
            this.testing = false;
            if (ok && data.choices) {
                this.testResponse = data.choices[0].message.content;
            } else {
                this.testResponse = data?.error?.message || 'Request failed';
            }
        },

        async loadHaikuModelSetting() {
            const { ok, data } = await this.api('/settings/haiku-model');
            if (ok && data?.haikuKiloModel) {
                this.haikuKiloModel = data.haikuKiloModel;
            }
            this.kiloEnabled = Boolean(data?.kiloEnabled);
            if (this.kiloEnabled) {
                await this.loadKiloModels();
            }
        },

        async loadKiloModels() {
            if (!this.kiloEnabled) {
                this.kiloModels = [];
                return;
            }
            this.kiloModelsLoading = true;
            const { ok, data } = await this.api('/settings/kilo-models');
            if (ok && data?.enabled === false) {
                this.kiloEnabled = false;
                this.kiloModels = [];
            } else if (ok && data?.models) {
                this.kiloModels = data.models;
                if (data.current) {
                    this.haikuKiloModel = data.current;
                }
            }
            this.kiloModelsLoading = false;
        },

        async setHaikuModel(model) {
            if (this.haikuModelSaving || this.haikuKiloModel === model) return;
            this.haikuModelSaving = true;
            const { ok, data } = await this.api('/settings/haiku-model', {
                method: 'POST',
                body: JSON.stringify({ haikuKiloModel: model })
            });
            this.haikuModelSaving = false;
            if (ok && data?.haikuKiloModel) {
                this.haikuKiloModel = data.haikuKiloModel;
                this.showToast(`Kilo target set to ${data.haikuKiloModel.toUpperCase()}`, 'success');
            } else {
                this.showToast(data?.error || 'Failed to update Kilo model', 'error');
            }
        },

        modelOptionName(modelId) {
            const option = this.openAiModelOptions.find((model) => model.id === modelId);
            return option ? option.name : modelId;
        },

        modelMappingLabel(alias) {
            const labels = { opus: 'Opus', sonnet: 'Sonnet', haiku: 'Haiku' };
            return labels[alias] || alias;
        },

        async loadModelMappingsSetting() {
            const { ok, data } = await this.api('/settings/model-mappings');
            if (!ok || !data?.modelMappings) return;

            this.modelMappings = data.modelMappings;
            this.modelMappingDefaults = data.defaults || this.modelMappingDefaults;
            this.reasoningMappings = data.reasoningMappings || this.reasoningMappings;
            this.reasoningMappingDefaults = data.reasoningDefaults || this.reasoningMappingDefaults;
            this.openAiModelOptions = Array.isArray(data.models) ? data.models : [];
            this.reasoningLevelOptions = Array.isArray(data.reasoningLevels) ? data.reasoningLevels : [];
        },

        async setModelMapping(alias, model) {
            if (this.modelMappingSaving || !alias || !model) return;

            const previous = this.modelMappings[alias];
            if (previous === model) return;

            this.modelMappings = { ...this.modelMappings, [alias]: model };
            this.modelMappingSaving = alias;
            const { ok, data } = await this.api('/settings/model-mappings', {
                method: 'POST',
                body: JSON.stringify({ modelMappings: { [alias]: model } })
            });
            this.modelMappingSaving = null;

            if (ok && data?.modelMappings) {
                this.modelMappings = data.modelMappings;
                this.modelMappingDefaults = data.defaults || this.modelMappingDefaults;
                this.reasoningMappings = data.reasoningMappings || this.reasoningMappings;
                this.reasoningMappingDefaults = data.reasoningDefaults || this.reasoningMappingDefaults;
                this.openAiModelOptions = Array.isArray(data.models) ? data.models : this.openAiModelOptions;
                this.reasoningLevelOptions = Array.isArray(data.reasoningLevels) ? data.reasoningLevels : this.reasoningLevelOptions;
                this.showToast(`${this.modelMappingLabel(alias)} now maps to ${this.modelOptionName(data.modelMappings[alias])}`, 'success');
            } else {
                this.modelMappings = { ...this.modelMappings, [alias]: previous };
                this.showToast(data?.error || 'Failed to update model mapping', 'error');
            }
        },

        reasoningOptionName(reasoningId) {
            const option = this.reasoningLevelOptions.find((level) => level.id === reasoningId);
            return option ? option.name : reasoningId;
        },

        async setReasoningMapping(alias, reasoning) {
            if (this.reasoningMappingSaving || !alias || !reasoning) return;

            const previous = this.reasoningMappings[alias];
            if (previous === reasoning) return;

            this.reasoningMappings = { ...this.reasoningMappings, [alias]: reasoning };
            this.reasoningMappingSaving = alias;
            const { ok, data } = await this.api('/settings/model-mappings', {
                method: 'POST',
                body: JSON.stringify({ reasoningMappings: { [alias]: reasoning } })
            });
            this.reasoningMappingSaving = null;

            if (ok && data?.reasoningMappings) {
                this.reasoningMappings = data.reasoningMappings;
                this.reasoningMappingDefaults = data.reasoningDefaults || this.reasoningMappingDefaults;
                this.reasoningLevelOptions = Array.isArray(data.reasoningLevels) ? data.reasoningLevels : this.reasoningLevelOptions;
                this.showToast(`${this.modelMappingLabel(alias)} reasoning set to ${this.reasoningOptionName(data.reasoningMappings[alias])}`, 'success');
            } else {
                this.reasoningMappings = { ...this.reasoningMappings, [alias]: previous };
                this.showToast(data?.error || 'Failed to update reasoning level', 'error');
            }
        },

        async loadAccountStrategySetting() {
            const { ok, data } = await this.api('/settings/account-strategy');
            if (ok && data?.accountStrategy) {
                this.accountStrategy = data.accountStrategy;
                this.multiAccountRotationEnabled = data.rotationEnabled === true;
            }
        },

        async setAccountStrategy(strategy) {
            if (!this.multiAccountRotationEnabled || this.strategySaving || this.accountStrategy === strategy) return;
            this.strategySaving = true;
            const { ok, data } = await this.api('/settings/account-strategy', {
                method: 'POST',
                body: JSON.stringify({ accountStrategy: strategy })
            });
            this.strategySaving = false;
            if (ok && data?.accountStrategy) {
                this.accountStrategy = data.accountStrategy;
                this.multiAccountRotationEnabled = data.rotationEnabled === true;
                this.showToast(`Account strategy set to ${data.accountStrategy === 'sticky' ? 'Sticky' : 'Round-Robin'}`, 'success');
            } else {
                this.showToast(data?.error || 'Failed to update strategy', 'error');
            }
        },

        async loadClaudeProxySetting() {
            const { ok, data } = await this.api('/settings/claude-proxy');
            if (ok && typeof data?.configureClaudeOnStartup === 'boolean') {
                this.configureClaudeOnStartup = data.configureClaudeOnStartup;
            }
        },

        async configureClaudeProxy() {
            if (this.claudeProxyConfiguring) return;
            this.claudeProxyConfiguring = true;
            const { ok, data, error } = await this.api('/claude/config/proxy', { method: 'POST' });
            this.claudeProxyConfiguring = false;

            if (ok && data?.success) {
                this.showToast(data.message || 'Claude Code configured to use this proxy.', 'success');
            } else {
                this.showToast(data?.error || error || 'Failed to update Claude Code settings.json', 'error');
            }
        },

        async setConfigureClaudeOnStartup(enabled) {
            if (this.claudeProxyStartupSaving) return;
            const previous = this.configureClaudeOnStartup;
            this.configureClaudeOnStartup = enabled;
            this.claudeProxyStartupSaving = true;
            const { ok, data, error } = await this.api('/settings/claude-proxy', {
                method: 'POST',
                body: JSON.stringify({ configureClaudeOnStartup: enabled })
            });
            this.claudeProxyStartupSaving = false;

            if (ok && typeof data?.configureClaudeOnStartup === 'boolean') {
                this.configureClaudeOnStartup = data.configureClaudeOnStartup;
                this.showToast(
                    data.configureClaudeOnStartup
                        ? 'Claude Code will be configured on proxy startup.'
                        : 'Startup Claude Code configuration disabled.',
                    'success'
                );
            } else {
                this.configureClaudeOnStartup = previous;
                this.showToast(data?.error || error || 'Failed to update startup setting', 'error');
            }
        },

        showToast(message, type = 'success') {
            this.toast = { message, type };
            setTimeout(() => { this.toast = null; }, 3000);
        },

        startLogStream() {
            if (this.logEventSource) this.logEventSource.close();
            
            this.logEventSource = new EventSource('/api/logs/stream?history=true');
            this.logEventSource.onmessage = (event) => {
                try {
                    const log = JSON.parse(event.data);
                    this.logs.unshift(log);
                    
                    if (this.logs.length > 500) {
                        this.logs = this.logs.slice(0, 500);
                    }
                } catch (e) {}
            };
            
            this.logEventSource.onerror = () => {
                setTimeout(() => this.startLogStream(), 3000);
            };
        },

        clearLogs() {
            this.logs = [];
        },

        formatLogMessage(message) {
            if (!message) return '';
            const match = message.match(/^\[(\w+)\]\s*/);
            if (match) {
                return message.replace(match[0], '');
            }
            return message;
        },

        getLogDetails(message) {
            if (!message) return null;
            const details = {};
            
            const patterns = [
                ['model', /model=([^\s|,]+)/],
                ['account', /account=([^\s|,]+)/],
                ['stream', /stream=(true|false)/],
                ['messages', /messages=(\d+)/],
                ['tools', /tools=(\d+)/],
                ['tokens', /tokens=(\d+)/],
                ['duration', /(\d+)ms/],
                ['status', /status=(\d+)/],
                ['error', /error=([^\s|]+)/]
            ];
            
            for (const [key, pattern] of patterns) {
                const match = message.match(pattern);
                if (match) {
                    details[key] = match[1];
                }
            }
            
            return Object.keys(details).length > 0 ? details : null;
        }
    }));
});

export class RuntimeState {
  constructor() {
    this.accounts = new Map();
  }

  get(accountId) {
    return this.accounts.get(accountId) ?? { inflight: 0, failures: 0, successes: 0, latencyEwmaMs: null, cooldownUntil: 0, attention: false, lastErrorCode: null };
  }

  snapshot() {
    return new Map([...this.accounts].map(([key, value]) => [key, { ...value }]));
  }

  begin(accountId) {
    const state = this.get(accountId);
    this.accounts.set(accountId, { ...state, inflight: state.inflight + 1 });
  }

  succeed(accountId, latencyMs) {
    const state = this.get(accountId);
    const latencyEwmaMs = state.latencyEwmaMs == null ? latencyMs : state.latencyEwmaMs * 0.75 + latencyMs * 0.25;
    this.accounts.set(accountId, { ...state, inflight: Math.max(0, state.inflight - 1), failures: 0, successes: state.successes + 1, latencyEwmaMs, cooldownUntil: 0, attention: false, lastErrorCode: null });
  }

  fail(accountId, error, now = Date.now()) {
    const state = this.get(accountId);
    this.accounts.set(accountId, {
      ...state,
      inflight: Math.max(0, state.inflight - 1),
      failures: state.failures + 1,
      cooldownUntil: error.cooldownMs ? Math.max(state.cooldownUntil ?? 0, now + error.cooldownMs) : state.cooldownUntil ?? 0,
      attention: Boolean(error.attention),
      lastErrorCode: error.code,
    });
  }

  cancel(accountId) {
    const state = this.get(accountId);
    this.accounts.set(accountId, { ...state, inflight: Math.max(0, state.inflight - 1) });
  }

  clear(accountId) {
    this.accounts.delete(accountId);
  }

  clearAll() {
    this.accounts.clear();
  }
}

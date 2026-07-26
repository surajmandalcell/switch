function periodStart(period, now) {
  const date = new Date(now);
  if (period === 'minute') return new Date(date.getFullYear(), date.getMonth(), date.getDate(), date.getHours(), date.getMinutes()).getTime();
  if (period === 'day') return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  return new Date(date.getFullYear(), date.getMonth(), 1).getTime();
}

export function evaluateAccountLimits(account, usage = {}, now = Date.now()) {
  const limits = account.limits ?? {};
  const minute = usage.requestsSince?.(account.id, periodStart('minute', now)) ?? usage.requestsMinute ?? 0;
  const dayTokens = usage.tokensSince?.(account.id, periodStart('day', now)) ?? usage.tokensDay ?? 0;
  const monthTokens = usage.tokensSince?.(account.id, periodStart('month', now)) ?? usage.tokensMonth ?? 0;
  const monthCost = usage.costSince?.(account.id, periodStart('month', now)) ?? usage.costMonthUsd ?? 0;
  const reasons = [];
  if (limits.requestsPerMinute !== null && limits.requestsPerMinute !== undefined && minute >= limits.requestsPerMinute) reasons.push('requests_per_minute');
  if (limits.tokensPerDay !== null && limits.tokensPerDay !== undefined && dayTokens >= limits.tokensPerDay) reasons.push('tokens_per_day');
  if (limits.tokensPerMonth !== null && limits.tokensPerMonth !== undefined && monthTokens >= limits.tokensPerMonth) reasons.push('tokens_per_month');
  if (limits.costPerMonthUsd !== null && limits.costPerMonthUsd !== undefined && monthCost >= limits.costPerMonthUsd) reasons.push('cost_per_month');
  return { allowed: reasons.length === 0, reasons, observed: { minute, dayTokens, monthTokens, monthCost } };
}

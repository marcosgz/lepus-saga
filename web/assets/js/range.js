const KEY = "lepus-saga:range";

export const RANGES = [
  { key: "1h", ms: 3_600_000, bucket: 120, short: "1 h", phrase: "the last hour", per: "2 minutes" },
  { key: "24h", ms: 86_400_000, bucket: 1800, short: "24 h", phrase: "the last 24 hours", per: "half hour" },
  { key: "7d", ms: 604_800_000, bucket: 21_600, short: "7 d", phrase: "the last 7 days", per: "6 hours" }
];

export const findRange = (key) => RANGES.find((range) => range.key === key) || null;

export const rangeFrom = (range, now = Date.now()) => new Date(now - range.ms).toISOString();

export function storedRange() {
  try { return findRange(localStorage.getItem(KEY)); } catch { return null; }
}

export function storeRange(range) {
  try { localStorage.setItem(KEY, range.key); } catch {}
}

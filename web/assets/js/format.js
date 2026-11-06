export const STATUSES = ["running", "compensating", "failed", "compensation_failed", "compensated", "completed"];

const STATUS_LABELS = {
  running: "Running",
  compensating: "Compensating",
  completed: "Completed",
  compensated: "Compensated",
  failed: "Failed",
  compensation_failed: "Compensation failed",
  succeeded: "Succeeded",
  skipped: "Skipped",
  stalled: "Stalled"
};

export const RANGES = [
  { key: "1h", label: "1 h", seconds: 3600 },
  { key: "24h", label: "24 h", seconds: 86400 },
  { key: "7d", label: "7 d", seconds: 7 * 86400 }
];

const numberFormat = new Intl.NumberFormat();
const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const shortFormat = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
const fullFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "medium" });

export function statusLabel(status) {
  return STATUS_LABELS[status] || humanize(status);
}

export function humanize(value) {
  if (!value) return "";
  const text = String(value).replace(/[_-]+/g, " ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

export function count(value) {
  return numberFormat.format(value || 0);
}

export function parseTime(value) {
  return value ? new Date(value) : null;
}

export function clock(value) {
  const date = value instanceof Date ? value : parseTime(value);
  return date ? timeFormat.format(date) : "";
}

export function shortTime(value) {
  const date = value instanceof Date ? value : parseTime(value);
  return date ? shortFormat.format(date) : "";
}

export function fullTime(value) {
  const date = value instanceof Date ? value : parseTime(value);
  return date ? fullFormat.format(date) : "";
}

export function ago(value, now = Date.now()) {
  const date = value instanceof Date ? value : parseTime(value);
  if (!date) return "";
  const seconds = Math.max(0, Math.round((now - date.getTime()) / 1000));
  if (seconds < 45) return "just now";
  if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86400)} d ago`;
}

export function duration(ms) {
  if (ms === null || ms === undefined || Number.isNaN(ms)) return "";
  if (ms < 1) return "<1 ms";
  if (ms < 1000) return `${Math.round(ms)} ms`;
  const seconds = ms / 1000;
  if (seconds < 60) return `${seconds.toFixed(seconds < 10 ? 2 : 1)} s`;
  const total = Math.round(seconds);
  const minutes = Math.floor(total / 60);
  if (minutes < 60) return `${minutes} min ${total % 60} s`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours} h ${minutes % 60} min`;
  return `${Math.floor(hours / 24)} d ${hours % 24} h`;
}

export function elapsed(start, end) {
  const from = parseTime(start);
  if (!from) return null;
  const to = end ? parseTime(end) : new Date();
  return to.getTime() - from.getTime();
}

export function shortId(id) {
  if (!id) return "";
  return id.length > 13 ? `${id.slice(0, 8)}…${id.slice(-4)}` : id;
}

export function resource(execution) {
  return `${execution.resource_type} ${execution.resource_id}`;
}

export function rangeWindow(key, now = new Date()) {
  const range = RANGES.find((item) => item.key === key);
  if (!range) return {};
  return { from: new Date(now.getTime() - range.seconds * 1000).toISOString(), to: now.toISOString() };
}

export function tone(status) {
  switch (status) {
    case "completed":
    case "succeeded":
    case "running":
      return "proceed";
    case "compensating":
    case "compensated":
      return "reverse";
    case "failed":
    case "compensation_failed":
      return "stop";
    case "stalled":
      return "caution";
    default:
      return "muted";
  }
}

export function json(value) {
  return JSON.stringify(value ?? {}, null, 2);
}

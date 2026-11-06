const numbers = new Intl.NumberFormat();
const timeOfDay = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });
const dayTime = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" });

const STATUS = {
  running: "Running",
  compensating: "Compensating",
  completed: "Completed",
  compensated: "Compensated",
  failed: "Failed",
  compensation_failed: "Compensation failed"
};

export const statusLabel = (status) => STATUS[status] || status;
export const count = (value) => numbers.format(value || 0);
export const plural = (n, one, many = `${one}s`) => `${count(n)} ${n === 1 ? one : many}`;
export const toTime = (value) => (value ? Date.parse(value) : null);
export const hourMinute = (value) => timeOfDay.format(new Date(value));
export const stamp = (value) => (value ? dayTime.format(new Date(value)) : "");

export function duration(ms) {
  if (ms === null || ms === undefined || Number.isNaN(ms)) return "";
  if (ms < 1000) return `${Math.round(ms)} ms`;
  const seconds = ms / 1000;
  if (seconds < 10) return `${seconds.toFixed(1)} s`;
  if (seconds < 60) return `${Math.round(seconds)} s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    const rest = Math.round(seconds - minutes * 60);
    return rest ? `${minutes} min ${rest} s` : `${minutes} min`;
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 48) {
    const rest = minutes - hours * 60;
    return rest ? `${hours} h ${rest} min` : `${hours} h`;
  }
  return `${Math.round(hours / 24)} days`;
}

export function ago(value, now = Date.now()) {
  const time = typeof value === "number" ? value : toTime(value);
  if (!time) return "";
  const ms = Math.max(0, now - time);
  if (ms < 45_000) return "just now";
  if (ms >= 86_400_000) return `${waited(ms)} ago`;
  return `${duration(Math.round(ms / 60_000) * 60_000)} ago`;
}

export function offset(ms) {
  if (ms < 1000) return "+0 s";
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `+${seconds} s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `+${minutes}:${String(seconds % 60).padStart(2, "0")}`;
  const hours = Math.floor(minutes / 60);
  return `+${hours} h ${minutes % 60}m`;
}

export function waited(ms) {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} h ${minutes % 60} min`;
  return `${Math.floor(hours / 24)} d ${hours % 24} h`;
}

const dayOfMonth = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });

export const dayMonth = (value) => dayOfMonth.format(new Date(value));

export function compact(value) {
  const n = value || 0;
  if (n < 1000) return String(n);
  const [scaled, unit] = n < 1_000_000 ? [n / 1000, "k"] : [n / 1_000_000, "M"];
  const digits = scaled < 10 ? 1 : 0;
  const rounded = Number(scaled.toFixed(digits));
  if (rounded >= 1000 && unit === "k") return compact(1_000_000);
  return `${rounded}${unit}`;
}

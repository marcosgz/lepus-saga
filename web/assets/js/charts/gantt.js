import { s, svgSize, showTip, hideTip } from "../dom.js";
import { duration, parseTime, statusLabel, tone } from "../format.js";

const ROW = window.matchMedia("(pointer: coarse)").matches ? 44 : 30;
const BAR = 14;
const AXIS = 26;
const LABEL = 190;
const RIGHT = 32;
const BAND_HEAD = 22;
const MIN_WIDTH = 560;
const TICK_STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 43200, 86400];

function niceStep(spanSeconds, slots) {
  return TICK_STEPS.find((step) => spanSeconds / step <= slots) || TICK_STEPS[TICK_STEPS.length - 1];
}

function fit(text, pixels) {
  const max = Math.max(4, Math.floor(pixels / 7.5));
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function offsetLabel(seconds) {
  if (seconds === 0) return "0";
  if (seconds < 60) return `+${seconds} s`;
  if (seconds < 3600) return seconds % 60 ? `+${Math.floor(seconds / 60)} min ${seconds % 60} s` : `+${seconds / 60} min`;
  if (seconds < 86400) return `+${+(seconds / 3600).toFixed(1)} h`;
  return `+${+(seconds / 86400).toFixed(1)} d`;
}

function failMark(x, y) {
  return s("path", { class: "gantt-fail", d: `M${x} ${y - 4} L${x + 8} ${y + 4} M${x + 8} ${y - 4} L${x} ${y + 4}` });
}

function epochBands(attempts) {
  const bands = [];
  attempts.forEach((attempt, index) => {
    const last = bands[bands.length - 1];
    if (last && last.epoch === attempt.epoch) last.end = index;
    else bands.push({ epoch: attempt.epoch, start: index, end: index });
  });
  return bands;
}

export function gantt({ attempts, execution, width, onAttempt, selectedId }) {
  if (!attempts.length) return null;
  const chartWidth = Math.max(width, MIN_WIDTH);
  const now = Date.now();
  const starts = attempts.map((attempt) => parseTime(attempt.started_at).getTime());
  const ends = attempts.map((attempt) => (attempt.finished_at ? parseTime(attempt.finished_at).getTime() : now));
  const origin = Math.min(parseTime(execution.started_at)?.getTime() ?? Infinity, ...starts);
  const finish = Math.max(...ends, execution.finished_at ? parseTime(execution.finished_at).getTime() : 0);
  const span = Math.max(finish - origin, 1000);
  const plotLeft = LABEL;
  const plotWidth = chartWidth - plotLeft - RIGHT;
  const x = (time) => plotLeft + ((time - origin) / span) * plotWidth;
  const bands = epochBands(attempts);
  const bandHead = bands.length > 1 ? BAND_HEAD : 0;
  const rowY = attempts.map((_, index) => AXIS + index * ROW + (bands.findIndex((band) => index <= band.end) + 1) * bandHead);
  const height = AXIS + attempts.length * ROW + bands.length * bandHead + 6;
  const svg = svgSize(chartWidth, height, { class: "gantt", role: "group", "aria-label": "Step attempts over time" });

  if (bandHead) bands.forEach((band, index) => {
    const y = rowY[band.start] - bandHead;
    const bandHeight = (band.end - band.start + 1) * ROW + bandHead;
    svg.append(s("rect", { class: ["epoch-band", index % 2 ? "epoch-band-alt" : null], x: 0, y, width: chartWidth, height: bandHeight }));
    svg.append(s("line", { class: "epoch-rule", x1: 0, x2: chartWidth, y1: y, y2: y }));
    svg.append(s("text", { class: "epoch-label", x: 10, y: y + 15 }, `Epoch ${band.epoch}`));
  });

  const step = niceStep(span / 1000, Math.max(2, Math.floor(plotWidth / 90)));
  for (let seconds = 0; seconds * 1000 <= span; seconds += step) {
    const tickX = x(origin + seconds * 1000);
    svg.append(s("line", { class: "grid", x1: tickX, x2: tickX, y1: AXIS - 4, y2: height }));
    const anchor = seconds === 0 ? "start" : tickX > chartWidth - 40 ? "end" : "middle";
    svg.append(s("text", { class: "axis-label", x: tickX, y: AXIS - 10, "text-anchor": anchor }, offsetLabel(seconds)));
  }

  attempts.forEach((attempt, index) => {
    const y = rowY[index];
    const left = x(starts[index]);
    const barWidth = Math.max(3, x(ends[index]) - left);
    const reverse = attempt.direction === "compensate";
    const row = s("g", {
      class: ["gantt-row", attempt.id === selectedId ? "selected" : null],
      tabindex: 0,
      role: "button",
      dataset: { key: `attempt:${attempt.id}` },
      "aria-label": `${attempt.step_name}, ${reverse ? "compensation" : "attempt"} ${attempt.attempt}, epoch ${attempt.epoch}: ${statusLabel(attempt.status)}, ${duration(attempt.duration_ms)}`
    },
    s("rect", { class: "gantt-hit", x: 0, y, width: chartWidth, height: ROW }),
    s("text", { class: "gantt-label", x: 10, y: y + ROW / 2 + 5 }, fit(`${reverse ? "↩ " : ""}${attempt.step_name}`, LABEL - 56)),
    s("text", { class: "gantt-attempt", x: LABEL - 12, y: y + ROW / 2 + 5, "text-anchor": "end" }, `#${attempt.attempt}`),
    s("rect", {
      class: ["gantt-bar", `bar-${attempt.status}`, reverse ? "bar-reverse" : null],
      x: left, y: y + (ROW - BAR) / 2, width: barWidth, height: BAR, rx: 3
    }),
    attempt.status === "failed" ? failMark(left + barWidth + 4, y + ROW / 2) : null);
    row.addEventListener("pointermove", (event) => showTip(event, [
      [`${attempt.step_name}, ${reverse ? "compensation" : "attempt"} ${attempt.attempt}`, `epoch ${attempt.epoch}`],
      [statusLabel(attempt.status), attempt.finished_at ? duration(attempt.duration_ms) : `${duration(now - starts[index])} so far`, tone(reverse && attempt.status === "succeeded" ? "compensated" : attempt.status)],
      attempt.error_class ? [attempt.error_class] : null
    ].filter(Boolean)));
    row.addEventListener("pointerleave", hideTip);
    row.addEventListener("click", () => onAttempt(attempt));
    row.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        onAttempt(attempt);
      }
    });
    svg.append(row);
  });
  return svg;
}

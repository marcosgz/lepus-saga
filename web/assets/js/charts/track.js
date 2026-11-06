import { s, svgSize, showTip, hideTip } from "../dom.js";
import { count, duration, statusLabel, tone } from "../format.js";

const LAMPS = ["running", "compensating", "failed", "compensation_failed"];
const LAMP_SHAPES = { running: "ring", compensating: "ring", failed: "square", compensation_failed: "square" };
const MIN_SPACING = 116;
const PAD = 56;
const LAMP_HEIGHT = 24;
const TICK = 10;
const TICK_GAP = 3;
const TOUCH_TICK = 16;
const TOUCH_GAP = 8;
const MAX_TICKS = 8;

function stepNames(steps, extra) {
  const names = steps.map((step) => step.name);
  for (const name of extra) if (name && !names.includes(name)) names.push(name);
  return names;
}

function isHorizontal(width, size) {
  return width >= size * MIN_SPACING + PAD;
}

function positions(width, size) {
  if (size === 1) return [width / 2];
  const spacing = (width - PAD * 2) / (size - 1);
  return Array.from({ length: size }, (_, index) => PAD + index * spacing);
}

function fit(text, pixels, charWidth = 7) {
  const max = Math.max(4, Math.floor(pixels / charWidth));
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function label(text, attrs, pixels) {
  const shown = fit(text, pixels);
  return s("text", { class: "station-label", ...attrs }, shown, shown === text ? null : s("title", {}, text));
}

function keyboardActivate(node, callback) {
  node.addEventListener("click", callback);
  node.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      callback(event);
    }
  });
}

function compensatable(steps) {
  return steps.filter((step) => step.compensate).map((step) => step.name);
}

function lampWidth(value) {
  return Math.max(40, count(value).length * 8 + 30);
}

function lampGlyph(x, y, status) {
  return LAMP_SHAPES[status] === "ring"
    ? s("circle", { class: "lamp-glyph", cx: x, cy: y, r: 3.5 })
    : s("rect", { class: "lamp-glyph lamp-glyph-square", x: x - 3.5, y: y - 3.5, width: 7, height: 7, rx: 1 });
}

function cross(x, y, size) {
  const inset = size * 0.25;
  return `M${x + inset} ${y + inset} L${x + size - inset} ${y + size - inset} M${x + size - inset} ${y + inset} L${x + inset} ${y + size - inset}`;
}

function lamp(x, y, status, value, href, stepName, { anchor = "middle", hitHeight = LAMP_HEIGHT, gap = 4 } = {}) {
  const text = count(value);
  const width = lampWidth(value);
  const left = anchor === "middle" ? x - width / 2 : anchor === "end" ? x - width : x;
  const body = LAMP_HEIGHT - 4;
  return s("a", { href, class: ["lamp", `tone-${tone(status)}`, status === "compensation_failed" ? "lamp-outline" : null], dataset: { key: href }, "aria-label": `${text} ${statusLabel(status).toLowerCase()} at ${stepName}` },
    s("title", {}, `${text} ${statusLabel(status).toLowerCase()} at ${stepName}`),
    s("rect", { class: "lamp-hit", x: left - gap / 2, y: y + body / 2 - hitHeight / 2, width: width + gap, height: hitHeight, rx: 4 }),
    s("rect", { class: "lamp-body", x: left, y, width, height: body, rx: 10 }),
    lampGlyph(left + 11, y + body / 2, status),
    s("text", { x: left + 16 + (width - 16) / 2, y: y + 14.5, "text-anchor": "middle" }, text));
}

function stationLamps(station) {
  return LAMPS.filter((status) => station && station[status] > 0);
}

function stationTip(event, name, station, sagaName) {
  const lines = [[name, sagaName]];
  for (const status of LAMPS) if (station?.[status]) lines.push([statusLabel(status), count(station[status]), tone(status)]);
  if (station?.attempt_failures) lines.push(["Failed attempts in range", count(station.attempt_failures)]);
  if (lines.length === 1) lines.push(["Nothing in progress"]);
  showTip(event, lines);
}

export function overviewTrack(saga, { width, hrefFor }) {
  const names = stepNames(saga.steps, Object.keys(saga.stations));
  if (!names.length) return null;
  const compensated = compensatable(saga.steps);
  const horizontal = isHorizontal(width, names.length);
  return horizontal
    ? horizontalOverview(saga, names, compensated, width, hrefFor)
    : verticalOverview(saga, names, compensated, width, hrefFor);
}

function horizontalOverview(saga, names, compensated, width, hrefFor) {
  const xs = positions(width, names.length);
  const stack = Math.max(1, ...names.map((name) => stationLamps(saga.stations[name]).length));
  const railY = 8 + stack * LAMP_HEIGHT + 12;
  const returnY = railY + 14;
  const height = railY + 48;
  const spacing = names.length > 1 ? xs[1] - xs[0] : width;
  const svg = svgSize(width, height, { class: "track", role: "group", "aria-label": `${saga.name} line` });

  svg.append(s("line", { class: "rail", x1: xs[0] - 18, x2: xs[xs.length - 1] + 18, y1: railY, y2: railY }));
  svg.append(s("line", { class: "rail-stop", x1: xs[xs.length - 1] + 18, x2: xs[xs.length - 1] + 18, y1: railY - 8, y2: railY + 8 }));
  const returnXs = names.map((name, index) => (compensated.includes(name) ? xs[index] : null)).filter((x) => x !== null);
  if (returnXs.length) {
    svg.append(s("line", { class: "return-line", x1: Math.min(...returnXs), x2: Math.max(...returnXs), y1: returnY, y2: returnY }));
    for (const x of returnXs) svg.append(s("circle", { class: "return-point", cx: x, cy: returnY, r: 3 }));
  }

  names.forEach((name, index) => {
    const x = xs[index];
    const station = saga.stations[name];
    const lit = stationLamps(station);
    if (lit.length) svg.append(s("line", { class: "post", x1: x, x2: x, y1: railY - 10, y2: railY - 6 - lit.length * LAMP_HEIGHT + 4 }));
    lit.forEach((status, slot) => {
      svg.append(lamp(x, railY - 10 - (slot + 1) * LAMP_HEIGHT, status, station[status], hrefFor(name, status), name));
    });
    const node = s("a", { href: hrefFor(name), class: ["station", station?.attempt_failures ? "station-warn" : null], dataset: { key: hrefFor(name) }, "aria-label": `${name}: all executions at this step` },
      s("circle", { class: "station-hit", cx: x, cy: railY, r: 18 }),
      s("circle", { class: "station-dot", cx: x, cy: railY, r: 8 }));
    node.addEventListener("pointermove", (event) => stationTip(event, name, station, saga.name));
    node.addEventListener("pointerleave", hideTip);
    svg.append(node);
    svg.append(label(name, { x, y: returnY + 22, "text-anchor": "middle" }, spacing - 12));
  });
  return svg;
}

function verticalOverview(saga, names, compensated, width, hrefFor) {
  const row = 48;
  const railX = 22;
  const height = names.length * row + 4;
  const ys = names.map((_, index) => 24 + index * row);
  const svg = svgSize(width, height, { class: "track track-vertical", role: "group", "aria-label": `${saga.name} line` });

  svg.append(s("line", { class: "rail", x1: railX, x2: railX, y1: ys[0] - 14, y2: ys[ys.length - 1] + 14 }));
  svg.append(s("line", { class: "rail-stop", x1: railX - 8, x2: railX + 8, y1: ys[ys.length - 1] + 14, y2: ys[ys.length - 1] + 14 }));
  const returnYs = names.map((name, index) => (compensated.includes(name) ? ys[index] : null)).filter((y) => y !== null);
  if (returnYs.length) {
    svg.append(s("line", { class: "return-line", x1: 6, x2: 6, y1: Math.min(...returnYs), y2: Math.max(...returnYs) }));
    for (const y of returnYs) svg.append(s("circle", { class: "return-point", cx: 6, cy: y, r: 3 }));
  }

  names.forEach((name, index) => {
    const y = ys[index];
    const station = saga.stations[name];
    const lit = stationLamps(station);
    let right = width - 2;
    const lamps = lit.map((status) => {
      const node = lamp(right, y - 10, status, station[status], hrefFor(name, status), name, { anchor: "end", hitHeight: row - 4, gap: 6 });
      right -= lampWidth(station[status]) + 6;
      return node;
    });
    const node = s("a", { href: hrefFor(name), class: ["station", station?.attempt_failures ? "station-warn" : null], dataset: { key: hrefFor(name) }, "aria-label": `${name}: all executions at this step` },
      s("rect", { class: "station-hit", x: 0, y: y - row / 2, width: right, height: row }),
      s("circle", { class: "station-dot", cx: railX, cy: y, r: 8 }));
    node.addEventListener("pointermove", (event) => stationTip(event, name, station, saga.name));
    node.addEventListener("pointerleave", hideTip);
    svg.append(node, label(name, { x: railX + 22, y: y + 5 }, right - railX - 30), ...lamps);
  });
  return svg;
}

function attemptState(name, attempts, execution) {
  const execute = attempts.filter((attempt) => attempt.step_name === name && attempt.direction === "execute");
  const succeeded = execute.some((attempt) => attempt.status === "succeeded" || attempt.status === "skipped");
  const here = execution.current_step === name;
  if (here && execution.status === "running") return "current-proceed";
  if (here && execution.status === "compensating") return "current-reverse";
  if (here && (execution.status === "failed" || execution.status === "compensation_failed")) return "current-stop";
  return succeeded ? "done" : execute.length ? "touched" : "ahead";
}

function tickNode(x, y, attempt, onAttempt, size = TICK, pad = 3) {
  const node = s("g", {
    class: ["tick", `tick-${attempt.status}`, attempt.direction === "compensate" ? "tick-reverse" : null],
    tabindex: 0,
    role: "button",
    dataset: { key: `attempt:${attempt.id}` },
    "aria-label": `${attempt.step_name} ${attempt.direction === "compensate" ? "compensation" : "attempt"} ${attempt.attempt}, epoch ${attempt.epoch}: ${statusLabel(attempt.status)}`
  },
  s("rect", { class: "tick-hit", x: x - pad, y: y - pad, width: size + pad * 2, height: size + pad * 2 }),
  s("rect", { class: "tick-mark", x, y, width: size, height: size, rx: 2 }),
  attempt.status === "failed" ? s("path", { class: "tick-glyph", d: cross(x, y, size) }) : null);
  node.addEventListener("pointermove", (event) => showTip(event, [
    [`${attempt.step_name}, ${attempt.direction === "compensate" ? "compensation" : "attempt"} ${attempt.attempt}`, `epoch ${attempt.epoch}`],
    [statusLabel(attempt.status), duration(attempt.duration_ms), tone(attempt.status === "succeeded" && attempt.direction === "compensate" ? "compensated" : attempt.status)],
    attempt.error_class ? [attempt.error_class] : null
  ].filter(Boolean)));
  node.addEventListener("pointerleave", hideTip);
  keyboardActivate(node, () => onAttempt(attempt));
  return node;
}

function touchTick(x, y, attempt, onAttempt) {
  return tickNode(x, y, attempt, onAttempt, TOUCH_TICK, TOUCH_GAP / 2);
}

function tickOffsets(list, size = TICK, gap = TICK_GAP) {
  let offset = 0;
  return list.slice(0, MAX_TICKS).map((attempt, index) => {
    if (index > 0 && attempt.epoch !== list[index - 1].epoch) offset += 4;
    const value = offset;
    offset += size + gap;
    return value;
  });
}

function overflow(list) {
  return list.length > MAX_TICKS ? `+${list.length - MAX_TICKS}` : null;
}

export function executionTrack({ steps, attempts, execution, width, onAttempt }) {
  const names = stepNames(steps, [...attempts.map((attempt) => attempt.step_name), execution.current_step]);
  if (!names.length) return null;
  const byStep = (name, direction) => attempts.filter((attempt) => attempt.step_name === name && attempt.direction === direction);
  const reachedIndex = Math.max(0, ...names.map((name, index) => (byStep(name, "execute").length || execution.current_step === name ? index : 0)));
  const returned = names.map((name, index) => (byStep(name, "compensate").length ? index : null)).filter((index) => index !== null);
  const context = { names, byStep, reachedIndex, returned, execution, onAttempt };
  return isHorizontal(width, names.length) ? horizontalExecution(context, width) : verticalExecution(context, width);
}

function horizontalExecution({ names, byStep, reachedIndex, returned, execution, onAttempt }, width) {
  const xs = positions(width, names.length);
  const spacing = names.length > 1 ? xs[1] - xs[0] : width;
  const stackUp = Math.max(1, ...names.map((name) => Math.min(MAX_TICKS, byStep(name, "execute").length)));
  const stackDown = Math.max(0, ...names.map((name) => Math.min(MAX_TICKS, byStep(name, "compensate").length)));
  const railY = 12 + stackUp * (TICK + TICK_GAP) + 16;
  const labelY = railY + 30;
  const returnY = labelY + 16;
  const height = returnY + (stackDown ? 12 + stackDown * (TICK + TICK_GAP) : 0) + 10;
  const svg = svgSize(width, height, { class: "track", role: "group", "aria-label": `${execution.saga_name} progress` });

  svg.append(s("line", { class: "rail-muted", x1: xs[0] - 18, x2: xs[xs.length - 1] + 18, y1: railY, y2: railY }));
  svg.append(s("line", { class: "rail", x1: xs[0] - 18, x2: xs[reachedIndex], y1: railY, y2: railY }));
  svg.append(s("line", { class: "rail-stop", x1: xs[xs.length - 1] + 18, x2: xs[xs.length - 1] + 18, y1: railY - 8, y2: railY + 8 }));
  if (returned.length) {
    const start = xs[Math.max(...returned)];
    const end = xs[Math.min(...returned)];
    svg.append(s("path", { class: "return-path", d: `M${start} ${returnY} H${end - 12}` }));
    svg.append(s("path", { class: "return-head", d: `M${end - 4} ${returnY - 5} L${end - 14} ${returnY} L${end - 4} ${returnY + 5} Z` }));
  }

  names.forEach((name, index) => {
    const x = xs[index];
    const state = attemptState(name, [...byStep(name, "execute")], execution);
    if (state.startsWith("current")) svg.append(s("circle", { class: ["station-ring", state], cx: x, cy: railY, r: 14 }));
    svg.append(s("circle", { class: ["station-dot", `station-${state}`], cx: x, cy: railY, r: 8 }));
    svg.append(label(name, { x, y: labelY, "text-anchor": "middle" }, spacing - 12));

    const execute = byStep(name, "execute");
    tickOffsets(execute).forEach((offset, slot) => {
      svg.append(tickNode(x - TICK / 2, railY - 16 - TICK - offset, execute[slot], onAttempt));
    });
    if (overflow(execute)) svg.append(s("text", { class: "tick-more", x: x + 10, y: railY - 18 }, overflow(execute)));
    const compensate = byStep(name, "compensate");
    tickOffsets(compensate).forEach((offset, slot) => {
      svg.append(tickNode(x - TICK / 2, returnY + 10 + offset, compensate[slot], onAttempt));
    });
    if (overflow(compensate)) svg.append(s("text", { class: "tick-more", x: x + 10, y: returnY + 20 }, overflow(compensate)));
  });
  return svg;
}

function verticalExecution({ names, byStep, reachedIndex, returned, execution, onAttempt }, width) {
  const row = 64;
  const railX = 26;
  const pitch = TOUCH_TICK + TOUCH_GAP;
  const columns = Math.max(2, Math.floor((width - railX - 24 - 18 - 32) / pitch));
  const perStep = Math.min(MAX_TICKS, columns);
  const ys = names.map((_, index) => 22 + index * row);
  const height = names.length * row;
  const svg = svgSize(width, height, { class: "track track-vertical", role: "group", "aria-label": `${execution.saga_name} progress` });

  svg.append(s("line", { class: "rail-muted", x1: railX, x2: railX, y1: ys[0] - 14, y2: ys[ys.length - 1] + 14 }));
  svg.append(s("line", { class: "rail", x1: railX, x2: railX, y1: ys[0] - 14, y2: ys[reachedIndex] }));
  svg.append(s("line", { class: "rail-stop", x1: railX - 8, x2: railX + 8, y1: ys[ys.length - 1] + 14, y2: ys[ys.length - 1] + 14 }));
  if (returned.length) {
    const start = ys[Math.max(...returned)];
    const end = ys[Math.min(...returned)];
    svg.append(s("path", { class: "return-path", d: `M6 ${start} V${end - 10}` }));
    svg.append(s("path", { class: "return-head", d: `M1 ${end - 4} L6 ${end - 14} L11 ${end - 4} Z` }));
  }

  names.forEach((name, index) => {
    const y = ys[index];
    const state = attemptState(name, byStep(name, "execute"), execution);
    if (state.startsWith("current")) svg.append(s("circle", { class: ["station-ring", state], cx: railX, cy: y, r: 14 }));
    svg.append(s("circle", { class: ["station-dot", `station-${state}`], cx: railX, cy: y, r: 8 }));
    svg.append(label(name, { x: railX + 24, y: y + 5 }, width - railX - 32));

    const tickY = y + 14;
    const execute = byStep(name, "execute");
    const compensate = byStep(name, "compensate");
    const shownExecute = execute.slice(0, compensate.length ? Math.max(1, perStep - 2) : perStep);
    const shownCompensate = compensate.slice(0, Math.max(0, perStep - shownExecute.length - 1));
    let x = railX + 24;
    const placeTicks = (list) => {
      const offsets = tickOffsets(list, TOUCH_TICK, TOUCH_GAP);
      offsets.forEach((offset, slot) => svg.append(touchTick(x + offset, tickY, list[slot], onAttempt)));
      if (offsets.length) x += offsets[offsets.length - 1] + pitch;
    };
    placeTicks(shownExecute);
    if (compensate.length) {
      svg.append(s("path", { class: "return-glyph", d: `M${x + 10} ${tickY + 8} H${x + 2} M${x + 5} ${tickY + 5} L${x + 2} ${tickY + 8} L${x + 5} ${tickY + 11}` }));
      x += 18;
      placeTicks(shownCompensate);
    }
    const hidden = execute.length + compensate.length - shownExecute.length - shownCompensate.length;
    if (hidden > 0) svg.append(s("text", { class: "tick-more", x, y: tickY + 13 }, `+${hidden}`));
  });
  return svg;
}

import { s, svgSize, showTip, hideTip } from "../dom.js";
import { count, shortTime, clock } from "../format.js";
import { dataTable } from "../ui.js";

export const SERIES = [
  { key: "completed", label: "Completed", tone: "proceed" },
  { key: "compensated", label: "Compensated", tone: "reverse" },
  { key: "failed", label: "Failed", tone: "stop" }
];

const TOP = 12;
const BOTTOM = 26;
const LEFT = 40;
const RIGHT = 8;

function niceMax(value) {
  if (value <= 4) return 4;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  const step = [1, 2, 2.5, 5, 10].find((factor) => factor * magnitude >= value / 4) * magnitude;
  return Math.ceil(value / step) * step;
}

function failed(row) {
  return (row.failed || 0) + (row.compensation_failed || 0);
}

function value(row, key) {
  return key === "failed" ? failed(row) : row[key] || 0;
}

export function throughputTable({ rows, bucket }) {
  const active = rows.filter((row) => row.started || SERIES.some((series) => value(row, series.key)));
  return dataTable({
    caption: "Executions per interval, intervals with activity only",
    columns: [{ label: "Interval" }, { label: "Started", num: true }, ...SERIES.map((series) => ({ label: series.label, num: true }))],
    rows: active.map((row) => [
      `${shortTime(row.t)} – ${clock(new Date(row.t).getTime() + bucket * 1000)}`,
      count(row.started || 0),
      ...SERIES.map((series) => count(value(row, series.key)))
    ])
  });
}

export function throughput({ rows, bucket, width, height = 180, onZoom }) {
  const svg = svgSize(width, height, { class: "throughput", role: "img", "aria-label": "Executions finished per interval, stacked by outcome, with starts as a line" });
  if (!rows.length) return svg;
  const plotWidth = width - LEFT - RIGHT;
  const plotHeight = height - TOP - BOTTOM;
  const slot = plotWidth / rows.length;
  const gap = slot > 6 ? 2 : slot > 3 ? 1 : 0;
  const totals = rows.map((row) => SERIES.reduce((sum, series) => sum + value(row, series.key), 0));
  const max = niceMax(Math.max(1, ...totals, ...rows.map((row) => row.started || 0)));
  const y = (amount) => TOP + plotHeight - (amount / max) * plotHeight;
  const times = rows.map((row) => new Date(row.t).getTime());

  for (let index = 0; index <= 2; index++) {
    const level = (max / 2) * index;
    svg.append(s("line", { class: index === 0 ? "baseline" : "grid", x1: LEFT, x2: width - RIGHT, y1: y(level), y2: y(level) }));
    svg.append(s("text", { class: "axis-label", x: LEFT - 6, y: y(level) + 4, "text-anchor": "end" }, count(level)));
  }

  const labelEvery = Math.ceil(rows.length / Math.max(2, Math.floor(plotWidth / 110)));
  const longRange = rows.length * bucket > 86400;
  rows.forEach((row, index) => {
    const left = LEFT + index * slot + gap / 2;
    const barWidth = Math.max(1, slot - gap);
    let base = 0;
    for (const series of SERIES) {
      const amount = value(row, series.key);
      if (!amount) continue;
      const top = y(base + amount);
      const segment = Math.max(1, y(base) - top - (base > 0 ? 1 : 0));
      svg.append(s("rect", { class: ["bar", `tone-${series.tone}`], x: left, y: top, width: barWidth, height: segment, rx: Math.min(2, barWidth / 2) }));
      base += amount;
    }
    if (index % labelEvery === 0) {
      svg.append(s("text", { class: "axis-label", x: left, y: height - 8 }, longRange ? shortTime(row.t) : clock(row.t).replace(/:\d\d$/, "")));
    }
  });

  const line = rows.map((row, index) => `${index ? "L" : "M"}${LEFT + index * slot} ${y(row.started || 0)} H${LEFT + (index + 1) * slot}`).join(" ");
  svg.append(s("path", { class: "started-line", d: line }));

  const cursor = s("rect", { class: "cursor", x: 0, y: TOP, width: slot, height: plotHeight, visibility: "hidden" });
  const selection = s("rect", { class: "selection", x: 0, y: TOP, width: 0, height: plotHeight, visibility: "hidden" });
  const overlay = s("rect", { class: "overlay", x: LEFT, y: TOP, width: plotWidth, height: plotHeight });
  svg.append(cursor, selection, overlay);

  const indexAt = (event) => {
    const box = svg.getBoundingClientRect();
    const px = ((event.clientX - box.left) / box.width) * width;
    return Math.min(rows.length - 1, Math.max(0, Math.floor((px - LEFT) / slot)));
  };
  let dragFrom = null;

  overlay.addEventListener("pointerdown", (event) => {
    dragFrom = indexAt(event);
    overlay.setPointerCapture(event.pointerId);
  });
  overlay.addEventListener("pointermove", (event) => {
    const index = indexAt(event);
    const row = rows[index];
    cursor.setAttribute("x", LEFT + index * slot);
    cursor.setAttribute("visibility", "visible");
    if (dragFrom !== null && index !== dragFrom) {
      const first = Math.min(dragFrom, index);
      selection.setAttribute("x", LEFT + first * slot);
      selection.setAttribute("width", (Math.abs(index - dragFrom) + 1) * slot);
      selection.setAttribute("visibility", "visible");
    }
    showTip(event, [
      [`${shortTime(row.t)} – ${clock(times[index] + bucket * 1000)}`],
      ["Started", count(row.started)],
      ...SERIES.map((series) => [series.label, count(value(row, series.key)), series.tone]),
      row.compensation_failed ? ["of which compensation failed", count(row.compensation_failed)] : null
    ].filter(Boolean));
  });
  overlay.addEventListener("pointerup", (event) => {
    const index = indexAt(event);
    if (dragFrom !== null && index !== dragFrom && onZoom) {
      const first = Math.min(dragFrom, index);
      const last = Math.max(dragFrom, index);
      onZoom(new Date(times[first]), new Date(times[last] + bucket * 1000));
    }
    dragFrom = null;
    selection.setAttribute("visibility", "hidden");
  });
  overlay.addEventListener("pointerleave", () => {
    cursor.setAttribute("visibility", "hidden");
    hideTip();
  });
  return svg;
}

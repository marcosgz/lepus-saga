import { s, svgSize, showTip, hideTip } from "../dom.js";
import { count, duration } from "../format.js";
import { dataTable } from "../ui.js";

const ROW = 30;
const HEADER = 30;
const AXIS = 24;
const DECADES = [1, 10, 100, 1000, 10000, 60000, 600000, 3600000];

function labelWidth(width) {
  return width < 520 ? 120 : 200;
}

function fit(text, pixels) {
  const max = Math.max(4, Math.floor(pixels / 7));
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function tickLabel(ms) {
  if (ms < 1000) return `${ms} ms`;
  if (ms < 60000) return `${ms / 1000} s`;
  return ms < 3600000 ? `${ms / 60000} min` : `${ms / 3600000} h`;
}

function diamond(x, y, r = 5.5) {
  return `M${x} ${y - r} L${x + r} ${y} L${x} ${y + r} L${x - r} ${y} Z`;
}

function groups(rows) {
  const result = [];
  for (const row of rows) {
    const last = result[result.length - 1];
    if (last && last.saga === row.saga_name) last.rows.push(row);
    else result.push({ saga: row.saga_name, rows: [row] });
  }
  return result;
}

export function latency({ rows, width }) {
  const grouped = groups(rows);
  const height = AXIS + grouped.length * HEADER + rows.length * ROW + 8;
  const svg = svgSize(width, height, { class: "latency", role: "img", "aria-label": "Step duration percentiles on a logarithmic scale" });
  if (!rows.length) return svg;
  const left = labelWidth(width);
  const right = width - 16;
  const low = Math.max(0.5, Math.min(...rows.map((row) => row.p50 || 1)) / 1.5);
  const high = Math.max(...rows.map((row) => row.max || row.p99 || 1)) * 1.3;
  const scale = (ms) => left + ((Math.log10(Math.max(ms, low)) - Math.log10(low)) / (Math.log10(high) - Math.log10(low))) * (right - left);

  for (const tick of DECADES.filter((tick) => tick >= low && tick <= high)) {
    svg.append(s("line", { class: "grid", x1: scale(tick), x2: scale(tick), y1: AXIS - 4, y2: height }));
    svg.append(s("text", { class: "axis-label", x: scale(tick), y: AXIS - 10, "text-anchor": "middle" }, tickLabel(tick)));
  }

  let y = AXIS;
  for (const group of grouped) {
    svg.append(s("text", { class: "latency-saga", x: 0, y: y + 20 }, fit(group.saga, width)));
    y += HEADER;
    for (const row of group.rows) {
      const middle = y + ROW / 2;
      const reverse = row.direction === "compensate";
      const node = s("g", { class: ["latency-row", reverse ? "latency-reverse" : null] },
        s("rect", { class: "latency-hit", x: 0, y, width, height: ROW }),
        s("text", { class: "latency-label", x: 12, y: middle + 5 }, fit(`${reverse ? "↩ " : ""}${row.step_name}`, left - 20)),
        s("line", { class: "latency-span", x1: scale(row.p50), x2: scale(row.p99), y1: middle, y2: middle }),
        s("line", { class: "latency-max", x1: scale(row.max), x2: scale(row.max), y1: middle - 6, y2: middle + 6 }),
        s("path", { class: "mark-p99", d: diamond(scale(row.p99), middle) }),
        s("circle", { class: "mark-p95", cx: scale(row.p95), cy: middle, r: 4.5 }),
        s("circle", { class: "mark-p50", cx: scale(row.p50), cy: middle, r: 5 }));
      node.addEventListener("pointermove", (event) => showTip(event, [
        [row.step_name, reverse ? "compensation" : "execute"],
        ["Attempts", count(row.count)],
        ["p50", duration(row.p50)],
        ["p95", duration(row.p95)],
        ["p99", duration(row.p99)],
        ["Max", duration(row.max)]
      ]));
      node.addEventListener("pointerleave", hideTip);
      svg.append(node);
      y += ROW;
    }
  }
  return svg;
}

export function latencyTable(rows) {
  return dataTable({
    caption: "Step duration percentiles",
    columns: [{ label: "Saga" }, { label: "Step" }, { label: "Attempts", num: true }, { label: "p50", num: true }, { label: "p95", num: true }, { label: "p99", num: true }, { label: "Max", num: true }],
    rows: rows.map((row) => [
      row.saga_name,
      `${row.direction === "compensate" ? "↩ " : ""}${row.step_name}`,
      count(row.count),
      duration(row.p50),
      duration(row.p95),
      duration(row.p99),
      duration(row.max)
    ])
  });
}

export function latencyLegend() {
  const item = (cls, text) => s("g", {},
    cls === "mark-p99" ? s("path", { class: cls, d: diamond(6, 8) }) : s("circle", { class: cls, cx: 6, cy: 8, r: 4.5 }),
    s("text", { class: "axis-label", x: 16, y: 12 }, text));
  const legend = svgSize(250, 16, { class: "latency-legend", "aria-hidden": "true" });
  const p50 = item("mark-p50", "p50");
  const p95 = item("mark-p95", "p95");
  const p99 = item("mark-p99", "p99");
  const max = s("g", {}, s("line", { class: "latency-max", x1: 6, x2: 6, y1: 2, y2: 14 }), s("text", { class: "axis-label", x: 14, y: 12 }, "Max"));
  p95.setAttribute("transform", "translate(56 0)");
  p99.setAttribute("transform", "translate(112 0)");
  max.setAttribute("transform", "translate(168 0)");
  legend.append(p50, p95, p99, max);
  return legend;
}

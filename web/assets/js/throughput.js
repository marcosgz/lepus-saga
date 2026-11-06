import { h, s, clear } from "./dom.js";
import { count, hourMinute } from "./format.js";

const DAY = 86_400_000;
const TICK_STEPS = [5, 10, 15, 30, 60, 120, 180, 360, 720, 1440, 2880].map((minutes) => minutes * 60_000);
const weekdayName = new Intl.DateTimeFormat(undefined, { weekday: "short" });
const weekday = { format: (date) => `${weekdayName.format(date)} ${date.getDate()}` };
const OUTCOMES = [
  ["completed", "Completed", "p-done"],
  ["compensated", "Compensated", "p-back"],
  ["failed", "Failed", "p-stop"]
];

function niceTop(value) {
  if (value <= 4) return 4;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  for (const m of [1, 2, 3, 4, 5, 6, 8, 10]) if (m * magnitude >= value) return m * magnitude;
  return 10 * magnitude;
}

function label(time) {
  const date = new Date(time);
  return date.getHours() === 0 && date.getMinutes() === 0 ? weekday.format(date) : hourMinute(date);
}

const sameDay = (a, b) => new Date(a).toDateString() === new Date(b).toDateString();

function timeTicks(start, end, px) {
  const span = end - start;
  const step = TICK_STEPS.find((ms) => (ms / span) * px >= 92) || TICK_STEPS[TICK_STEPS.length - 1];
  const date = new Date(start);
  date.setSeconds(0, 0);
  if (step >= DAY) {
    date.setHours(24, 0, 0, 0);
  } else {
    const minutes = step / 60_000;
    const mod = (date.getHours() * 60 + date.getMinutes()) % minutes;
    if (mod) date.setMinutes(date.getMinutes() + minutes - mod);
  }
  const ticks = [];
  while (date.getTime() <= end) {
    ticks.push(date.getTime());
    if (step >= DAY) date.setDate(date.getDate() + step / DAY);
    else date.setMinutes(date.getMinutes() + step / 60_000);
  }
  return ticks;
}

function normalize(rows) {
  return rows.map((row) => ({
    t: Date.parse(row.t),
    started: row.started || 0,
    completed: row.completed || 0,
    compensated: row.compensated || 0,
    failed: (row.failed || 0) + (row.compensation_failed || 0)
  }));
}

// Started and finished executions per bucket for the selected window: the
// finished ones stacked by outcome, the started ones as a stepped line.
export class Throughput {
  constructor(host) {
    this.host = host;
    this.totals = h("dl", { class: "tp-totals" });
    this.chart = h("div", { class: "tp-chart" });
    this.readout = h("p", { class: "tp-readout", "aria-hidden": "true" });
    this.tableBody = h("tbody");
    this.caption = h("caption", { class: "visually-hidden" });
    host.append(
      this.totals,
      this.chart,
      h("div", { class: "tp-foot" },
        this.readout,
        h("details", { class: "tp-table" },
          h("summary", {}, "Show as table"),
          h("div", { class: "tp-scroll" },
            h("table", {},
              this.caption,
              h("thead", {}, h("tr", {},
                h("th", { scope: "col" }, "From"),
                h("th", { scope: "col" }, "Started"),
                OUTCOMES.map(([, name]) => h("th", { scope: "col" }, name)))),
              this.tableBody))))
    );
    this.observer = new ResizeObserver(() => {
      const width = Math.round(this.chart.clientWidth);
      if (width && width !== this.width && this.data) this.draw();
    });
    this.observer.observe(this.chart);
  }

  destroy() {
    this.observer.disconnect();
  }

  set(series, range) {
    const rows = normalize(series.rows || []);
    const bucket = (series.bucket || range.bucket) * 1000;
    const to = Date.parse(series.to) || Date.now();
    const from = Date.parse(series.from) || to - range.ms;
    const start = rows.length ? rows[0].t : from;
    const end = rows.length ? rows[rows.length - 1].t + bucket : to;
    this.data = {
      rows, bucket, range, start, end,
      partial: (row) => row.t < from || row.t + bucket > to,
      when: (time) => (sameDay(start, end - 1) ? hourMinute(time) : `${weekday.format(new Date(time))}, ${hourMinute(time)}`)
    };
    this.draw();
    this.drawTotals();
    this.drawTable();
  }

  sums() {
    const sums = { started: 0, completed: 0, compensated: 0, failed: 0 };
    for (const row of this.data.rows) for (const key in sums) sums[key] += row[key];
    return sums;
  }

  drawTotals() {
    const sums = this.sums();
    const item = (key, name, value) => h("div", {}, h("dt", {}, h("i", { class: `k-${key}` }), name), h("dd", {}, count(value)));
    clear(this.totals).append(
      item("start", "Started", sums.started),
      ...OUTCOMES.map(([key, name, cls]) => item(cls.slice(2), name, sums[key])));
  }

  drawTable() {
    const { rows, range, when } = this.data;
    this.caption.textContent = `Executions started and finished per ${range.per} in ${range.phrase}`;
    clear(this.tableBody);
    for (const row of [...rows].reverse()) {
      this.tableBody.append(h("tr", {},
        h("th", { scope: "row" }, when(row.t)),
        h("td", {}, count(row.started)),
        OUTCOMES.map(([key]) => h("td", {}, count(row[key])))));
    }
  }

  draw() {
    const { rows, bucket, range, start, end, partial, when } = this.data;
    const width = Math.max(280, Math.round(this.chart.clientWidth) || 800);
    this.width = width;
    const compact = width < 600;
    const height = compact ? 170 : 210;
    const m = { top: 28, right: 4, bottom: 26, left: 34 };
    const plotW = width - m.left - m.right;
    const plotH = height - m.top - m.bottom;
    const x = (time) => m.left + ((time - start) / (end - start)) * plotW;
    const finished = (row) => row.completed + row.compensated + row.failed;
    let peak = 0;
    let peakIndex = -1;
    let ceiling = 0;
    const complete = rows.some((row) => !partial(row));
    rows.forEach((row, index) => {
      if (complete && partial(row)) return;
      const total = finished(row);
      if (total > peak) { peak = total; peakIndex = index; }
      ceiling = Math.max(ceiling, total, row.started);
    });
    const top = niceTop(ceiling);
    const y = (value) => m.top + plotH - (Math.min(value, top) / top) * plotH;
    const sums = this.sums();

    const svg = s("svg", {
      viewBox: `0 0 ${width} ${height}`, width, height, role: "img",
      "aria-label": `In ${range.phrase}: ${count(sums.started)} started, ${count(sums.completed)} completed, ${count(sums.compensated)} compensated and ${count(sums.failed)} failed.` +
        (peak ? ` Busiest full ${range.per} began at ${when(rows[peakIndex].t)} with ${count(peak)} finished.` : "")
    });

    for (const value of [0, top / 2, top]) {
      const gy = Math.round(y(value)) + 0.5;
      svg.append(
        s("line", { class: value ? "p-grid" : "p-rule", x1: m.left, x2: width - m.right, y1: gy, y2: gy }),
        s("text", { class: "p-axis", x: m.left - 8, y: gy + 4, "text-anchor": "end" }, count(value)));
    }

    const highlight = s("rect", { class: "p-hover", x: 0, y: m.top, width: 0, height: plotH, visibility: "hidden" });
    svg.append(highlight);

    const slot = (bucket / (end - start)) * plotW;
    const gap = Math.min(3, slot * 0.25);
    const bars = s("g");
    rows.forEach((row) => {
      const bx = x(row.t) + gap / 2;
      const bw = Math.max(1, slot - gap);
      const group = s("g", { class: partial(row) ? "is-partial" : null });
      let base = y(0);
      for (const [key, , cls] of OUTCOMES) {
        if (!row[key] || base <= m.top) continue;
        const hgt = Math.min(base - m.top, Math.max(1.5, y(0) - y(row[key])));
        const sep = cls === "p-done" ? 0 : 1;
        group.append(s("rect", { class: cls, x: bx, y: base - hgt, width: bw, height: Math.max(1, hgt - sep) }));
        if (cls === "p-done") group.append(s("rect", { class: "p-done-edge", x: bx, y: base - hgt, width: bw, height: Math.min(1.5, hgt) }));
        base -= hgt;
      }
      if (finished(row) > top) {
        group.append(s("path", { class: "p-break", d: `M${bx - 1} ${m.top + 9}L${bx + bw + 1} ${m.top + 5}M${bx - 1} ${m.top + 14}L${bx + bw + 1} ${m.top + 10}` }));
      }
      bars.append(group);
    });
    svg.append(bars);

    if (rows.length) {
      let d = `M${x(rows[0].t)} ${y(rows[0].started)}`;
      rows.forEach((row, index) => {
        if (index) d += `V${y(row.started)}`;
        d += `H${x(row.t) + slot}`;
      });
      svg.append(s("path", { class: "p-start", d }));
    }

    const ticks = timeTicks(start, end, plotW);
    for (const tick of ticks) {
      const text = label(tick);
      const tx = x(tick);
      const half = text.length * 3.4;
      if (tx - half < m.left - 6 || tx + half > width) continue;
      svg.append(
        s("line", { class: "p-tick", x1: tx, x2: tx, y1: y(0), y2: y(0) + 4 }),
        s("text", { class: "p-axis", x: tx, y: height - 6, "text-anchor": "middle" }, text));
    }

    if (peak) {
      const row = rows[peakIndex];
      const cx = x(row.t) + slot / 2;
      const text = compact ? `Peak ${count(peak)}, ${when(row.t)}` : `Busiest: ${count(peak)} finished, ${when(row.t)}`;
      const textW = text.length * 6.3;
      const preferEnd = cx > m.left + plotW * 0.66;
      const tx = Math.max(0, Math.min(width - textW, preferEnd ? cx - 6 - textW : cx + 6));
      svg.append(
        s("line", { class: "p-lead", x1: cx, x2: cx, y1: 16, y2: Math.max(18, y(peak) - 4) }),
        s("text", { class: "p-note", x: tx, y: 12 }, text));
    }

    const hit = s("rect", { class: "p-hit", x: m.left, y: 0, width: plotW, height });
    const show = (event) => {
      const box = svg.getBoundingClientRect();
      const px = ((event.clientX - box.left) / box.width) * width;
      const index = Math.floor(((px - m.left) / plotW) * rows.length);
      const row = rows[index];
      if (!row) return hide();
      highlight.setAttribute("x", x(row.t));
      highlight.setAttribute("width", slot);
      highlight.setAttribute("visibility", "visible");
      const part = partial(row) ? " (partial)" : "";
      clear(this.readout).append(
        h("b", {}, `${when(row.t)} to ${hourMinute(row.t + bucket)}${part}: `),
        `${count(row.started)} started, ${count(row.completed)} completed, ${count(row.compensated)} compensated, ${count(row.failed)} failed`);
    };
    const hide = () => {
      highlight.setAttribute("visibility", "hidden");
      this.readout.textContent = "Point at a bar to read its counts.";
    };
    hit.addEventListener("pointermove", show);
    hit.addEventListener("pointerdown", show);
    hit.addEventListener("pointerleave", hide);
    svg.append(hit);
    hide();

    clear(this.chart).append(svg);
  }
}

import { h, replace, observeWidth, keepFocus } from "../dom.js";
import { serial } from "../poller.js";
import { api } from "../api.js";
import { href, replaceQuery } from "../router.js";
import { count, RANGES, rangeWindow, shortTime, statusLabel } from "../format.js";
import { segmented, signal, empty, failure, heading, sectionHead } from "../ui.js";
import { overviewTrack } from "../charts/track.js";
import { throughput, throughputTable, SERIES } from "../charts/throughput.js";

const TOTAL_ORDER = ["completed", "compensated", "failed", "compensation_failed", "running", "compensating"];

export function overview(root, { route }) {
  let range = RANGES.some((item) => item.key === route.query.range) ? route.query.range : "24h";
  let zoom = route.query.from && route.query.to ? { from: route.query.from, to: route.query.to } : null;
  let sagas = null;
  let series = null;
  let width = 0;
  let snapshot = null;
  const queue = serial();

  const lines = h("div", { class: "lines" });
  const chart = h("div", { class: "chart-frame" });
  const zoomNote = h("div", { class: "zoom-note" });
  const rangeControl = segmented({
    label: "Time range",
    options: RANGES.map((item) => ({ value: item.key, label: item.label })),
    value: range,
    onChange: (next) => {
      range = next;
      zoom = null;
      sync();
      reload();
    }
  });

  replace(root,
    heading("Overview", rangeControl),
    h("section", { class: "section" },
      sectionHead("Lines", trackLegend()),
      lines),
    h("section", { class: "section" },
      sectionHead("Throughput", legend(), zoomNote),
      h("p", { class: "section-note" }, "Executions finished per interval by outcome; the line counts starts. Drag across the chart to zoom."),
      chart));

  const stop = observeWidth(lines, (next) => {
    width = next;
    draw();
  });

  function sync() {
    replaceQuery("/", { range, from: zoom?.from, to: zoom?.to });
  }

  function seriesWindow() {
    return zoom || rangeWindow(range);
  }

  function hrefFor(saga) {
    const filters = { saga: saga.name, range };
    return (step, status) => {
      if (!status) return href("/executions", { saga: saga.name, step });
      const inProgress = status === "running" || status === "compensating";
      return href("/executions", { ...filters, step, status, range: inProgress ? null : range });
    };
  }

  function draw() {
    if (!sagas || !width) return;
    keepFocus(lines, () => {
      if (!sagas.length) replace(lines, empty("No sagas yet.", "Executions show up here once a saga definition is loaded or a run is recorded."));
      else replace(lines, sagas.map((saga) => line(saga)));
    });
    drawChart();
  }

  function line(saga) {
    const totals = TOTAL_ORDER.filter((status) => saga.totals[status]).map((status) => `${count(saga.totals[status])} ${statusLabel(status).toLowerCase()}`);
    const started = Object.values(saga.totals).reduce((sum, value) => sum + value, 0);
    const track = overviewTrack(saga, { width, hrefFor: hrefFor(saga) });
    return h("article", { class: "line" },
      h("header", { class: "line-head" },
        h("h3", {}, h("a", { href: href("/executions", { saga: saga.name, range }), dataset: { key: `saga:${saga.name}` } }, saga.name)),
        saga.partition ? h("span", { class: "chip" }, `Partition ${saga.partition}`) : null,
        saga.known ? null : h("span", { class: "chip chip-caution" }, "Definition not loaded"),
        h("p", { class: "line-totals" }, [`${count(started)} started`, ...totals].join(", "))),
      track || h("p", { class: "muted" }, "No steps known."));
  }

  function drawChart() {
    if (!series || !width) return;
    const total = series.rows.reduce((sum, row) => sum + SERIES.reduce((acc, item) => acc + (row[item.key] || 0), row.started || 0), 0);
    const open = chart.querySelector("details")?.open;
    replace(chart, total
      ? [throughput({ rows: series.rows, bucket: series.bucket, width, height: width < 700 ? 150 : 190, onZoom }), throughputTable(series)]
      : empty("Nothing started or finished in this range."));
    if (open) chart.querySelector("details")?.setAttribute("open", "");
    keepFocus(zoomNote, () => replace(zoomNote,
      zoom ? h("span", { class: "muted" }, `${shortTime(zoom.from)} – ${shortTime(zoom.to)}`) : null,
      zoom ? h("button", { type: "button", class: "button button-quiet", dataset: { key: "reset-zoom" }, onclick: resetZoom }, "Reset zoom") : null,
      series.truncated ? h("span", { class: "chip chip-caution" }, "Sampled") : null));
  }

  function onZoom(from, to) {
    zoom = { from: from.toISOString(), to: to.toISOString() };
    sync();
    reload();
  }

  function resetZoom() {
    zoom = null;
    sync();
    reload();
  }

  function reload() {
    refresh().catch(() => null);
  }

  function refresh() {
    return queue(load);
  }

  async function load() {
    const span = seriesWindow();
    try {
      const [sagaData, seriesData] = await Promise.all([api.sagas(rangeWindow(range)), api.series(span)]);
      const next = JSON.stringify([range, zoom, sagaData.sagas, seriesData.rows, seriesData.bucket, seriesData.truncated]);
      if (next === snapshot) return;
      snapshot = next;
      sagas = sagaData.sagas;
      series = seriesData;
      draw();
    } catch (error) {
      snapshot = null;
      replace(lines, failure(error));
      throw error;
    }
  }

  return { refresh, destroy: stop };
}

function trackLegend() {
  return h("ul", { class: "legend" },
    h("li", {}, signal("running", "In progress")),
    h("li", {}, signal("compensating", "Compensating")),
    h("li", {}, signal("failed", "Failed")),
    h("li", {}, h("span", { class: "key key-return" }), "Compensation path"));
}

function legend() {
  return h("ul", { class: "legend" },
    SERIES.map((item) => h("li", {}, h("span", { class: ["key", `tone-${item.tone}`] }), item.label)),
    h("li", {}, h("span", { class: "key key-line" }), "Started"));
}

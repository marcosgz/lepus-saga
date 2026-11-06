import { h, replace, observeWidth, keepFocus } from "../dom.js";
import { serial } from "../poller.js";
import { api } from "../api.js";
import { href, replaceQuery } from "../router.js";
import { ago, count, fullTime, RANGES, rangeWindow, shortId } from "../format.js";
import { segmented, select, empty, failure, heading, sectionHead, signal } from "../ui.js";
import { latency, latencyLegend, latencyTable } from "../charts/latency.js";

const STALL_OPTIONS = [
  { value: "15", label: "15 min" },
  { value: "60", label: "1 h" },
  { value: "240", label: "4 h" }
];

export function insights(root, { route }) {
  let range = RANGES.some((item) => item.key === route.query.range) ? route.query.range : "24h";
  let saga = route.query.saga || "";
  let stallMinutes = STALL_OPTIONS.some((item) => item.value === route.query.stalled) ? route.query.stalled : "15";
  let latencyRows = null;
  let width = 0;
  let snapshot = null;
  const queue = serial();

  const failuresFrame = h("div", {});
  const latencyFrame = h("div", { class: "chart-frame" });
  const latencyNote = h("span", {});
  const stalledFrame = h("div", {});
  const sagaSlot = h("span", {});

  replace(root,
    heading("Insights",
      sagaSlot,
      segmented({
        label: "Time range",
        options: RANGES.map((item) => ({ value: item.key, label: item.label })),
        value: range,
        onChange: (next) => {
          range = next;
          changed();
        }
      })),
    h("section", { class: "section" },
      sectionHead("Failures"),
      h("p", { class: "section-note" }, "Failed attempts grouped by error, saga and step, most frequent first."),
      failuresFrame),
    h("section", { class: "section" },
      sectionHead("Step latency", latencyLegend(), latencyNote),
      h("p", { class: "section-note" }, "Duration of finished attempts, logarithmic scale. Compensations are marked ↩."),
      latencyFrame),
    h("section", { class: "section" },
      sectionHead("Stalled",
        select({ label: "No progress for", value: stallMinutes, options: STALL_OPTIONS.map((item) => ({ ...item, label: `No progress for ${item.label}` })), onChange: (value) => { stallMinutes = value; changed(); } })),
      h("p", { class: "section-note" }, "Executions in progress whose cursor has not moved. Lepus::Saga.resume_stuck re-publishes them on its next sweep; retry one from its page to resume it now."),
      stalledFrame));

  api.sagas({}).then((data) => {
    replace(sagaSlot, select({
      label: "Saga",
      value: saga,
      options: [{ value: "", label: "All sagas" }, ...data.sagas.map((item) => ({ value: item.name, label: item.name }))],
      onChange: (value) => {
        saga = value;
        changed();
      }
    }));
  }).catch(() => null);

  const stop = observeWidth(latencyFrame, (next) => {
    width = next;
    drawLatency();
  });

  function changed() {
    replaceQuery("/insights", { range, saga, stalled: stallMinutes === "15" ? "" : stallMinutes });
    refresh().catch(() => null);
  }

  function drawLatency() {
    if (!latencyRows || !width) return;
    const open = latencyFrame.querySelector("details")?.open;
    keepFocus(latencyFrame, () => replace(latencyFrame, latencyRows.length ? [latency({ rows: latencyRows, width }), latencyTable(latencyRows)] : empty("No finished attempts in this range.")));
    if (open) latencyFrame.querySelector("details")?.setAttribute("open", "");
  }

  function drawFailures(rows) {
    if (!rows.length) {
      replace(failuresFrame, empty("No failed attempts in this range."));
      return;
    }
    replace(failuresFrame, h("table", { class: "table failures-table" },
      h("thead", {}, h("tr", {},
        h("th", { scope: "col" }, "Error"),
        h("th", { scope: "col" }, "Saga and step"),
        h("th", { scope: "col", class: "num" }, "Count"),
        h("th", { scope: "col", class: "col-seen" }, "Last seen"),
        h("th", { scope: "col", class: "col-message" }, "Latest message"))),
      h("tbody", {}, rows.map((row) => h("tr", {},
        h("td", { class: "col-error" }, h("strong", {}, row.error_class || "Unknown error")),
        h("td", { class: "col-where" }, h("span", { class: "where-saga" }, row.saga_name), h("span", { class: "where-step" }, row.step_name)),
        h("td", { class: "num col-count" }, count(row.count)),
        h("td", { class: "col-seen" }, h("time", { datetime: row.last_seen_at, title: fullTime(row.last_seen_at) }, ago(row.last_seen_at))),
        h("td", { class: "col-message" },
          h("span", { class: "clamp" }, row.sample_message || ""),
          " ",
          h("a", { href: href(`/executions/${encodeURIComponent(row.sample_execution_id)}`), class: "sample-link", dataset: { key: `sample:${row.error_class}:${row.saga_name}:${row.step_name}` } }, "Latest execution")))))));
  }

  function drawStalled(data) {
    if (!data.executions.length) {
      replace(stalledFrame, empty(`Nothing has been stuck for more than ${STALL_OPTIONS.find((item) => item.value === stallMinutes).label}.`));
      return;
    }
    replace(stalledFrame, h("table", { class: "table stalled-table" },
      h("thead", {}, h("tr", {},
        h("th", { scope: "col" }, "Status"),
        h("th", { scope: "col" }, "Saga"),
        h("th", { scope: "col" }, "Step"),
        h("th", { scope: "col" }, "Last progress"),
        h("th", { scope: "col", class: "num" }, "Resumes"),
        h("th", { scope: "col", class: "col-id" }, "Id"))),
      h("tbody", {}, data.executions.map((row) => h("tr", {},
        h("td", {}, signal("stalled", row.status === "compensating" ? "Stalled compensating" : "Stalled")),
        h("td", {}, h("a", { href: href(`/executions/${encodeURIComponent(row.id)}`), dataset: { key: `stalled:${row.id}` } }, row.saga_name)),
        h("td", {}, row.current_step || ""),
        h("td", {}, h("time", { datetime: row.last_progress_at, title: fullTime(row.last_progress_at) }, ago(row.last_progress_at))),
        h("td", { class: "num" }, String(row.resume_count)),
        h("td", { class: "col-id" }, shortId(row.id)))))));
  }

  function refresh() {
    return queue(load);
  }

  async function load() {
    const params = { ...rangeWindow(range), saga };
    try {
      const [failures, latencies, stalled] = await Promise.all([
        api.failures(params),
        api.latency(params),
        api.stalled({ minutes: stallMinutes })
      ]);
      const next = JSON.stringify([stallMinutes, failures.failures, latencies.rows, latencies.truncated, stalled.executions]);
      if (next === snapshot) return;
      snapshot = next;
      keepFocus(failuresFrame, () => drawFailures(failures.failures));
      latencyRows = latencies.rows;
      replace(latencyNote, latencies.truncated ? h("span", { class: "chip chip-caution" }, "Sampled from the newest attempts") : null);
      drawLatency();
      keepFocus(stalledFrame, () => drawStalled(stalled));
    } catch (error) {
      snapshot = null;
      replace(failuresFrame, failure(error));
      throw error;
    }
  }

  return { refresh, destroy: stop };
}

import { api } from "../api.js";
import { h, s, refill } from "../dom.js";
import { every, pollMs } from "../live.js";
import { sagaDefinitions } from "../sagas.js";
import { ago, duration, statusLabel, toTime, waited } from "../format.js";
import { findRange, rangeFrom } from "../range.js";

const GROUPS = [
  { key: "", label: "All", statuses: null },
  { key: "moving", label: "In flight", statuses: ["running", "compensating"] },
  { key: "failed", label: "Failed", statuses: ["failed", "compensation_failed"] },
  { key: "compensated", label: "Compensated", statuses: ["compensated"] },
  { key: "completed", label: "Completed", statuses: ["completed"] }
];

// A line the width of a table cell: done stops in ink, the rest pale, and a
// mark where the execution is.
function glyph(execution, definition) {
  const steps = definition ? definition.steps : [];
  const n = Math.max(1, steps.length);
  const width = 112;
  const x = (i) => 6 + (n === 1 ? 50 : ((width - 12) * i) / (n - 1));
  const at = Math.max(0, steps.findIndex((step) => step.name === execution.current_step));
  const done = execution.status === "completed" ? n - 1 : execution.status === "compensated" ? -1 : at;
  const svg = s("svg", { class: "glyph", viewBox: `0 0 ${width} 16`, width, height: 16, "aria-hidden": "true" });
  svg.append(s("line", { class: "g-line is-future", x1: x(0), x2: x(n - 1), y1: 8, y2: 8 }));
  if (done > 0) svg.append(s("line", { class: "g-line", x1: x(0), x2: x(done), y1: 8, y2: 8 }));
  for (let i = 0; i < n; i++) {
    svg.append(s("circle", { class: i <= done ? "g-dot" : "g-dot is-future", cx: x(i), cy: 8, r: 3 }));
  }
  const status = execution.status;
  if (status === "failed" || status === "compensation_failed") {
    svg.append(s("rect", { class: "g-stop", x: x(at) - 2, y: 0, width: 4, height: 16, rx: 1.5 }));
  } else if (status === "running") {
    svg.append(s("rect", { class: "t-token", x: x(at) - 7, y: 3.5, width: 14, height: 9, rx: 4.5 }));
  } else if (status === "compensating" || status === "compensated") {
    svg.append(s("rect", { class: "t-token is-back", x: x(status === "compensated" ? 0 : at) - 7, y: 3.5, width: 14, height: 9, rx: 4.5 }));
  } else if (status === "completed") {
    svg.append(s("rect", { class: "t-token is-done", x: x(n - 1) - 7, y: 3.5, width: 14, height: 9, rx: 4.5 }));
  }
  return svg;
}

const shortError = (name) => name.split("::").pop();

// Only these columns sort: the API pages along either one.
const SORTS = [
  { key: "started", api: "started_at", label: "Started", desc: "latest first", asc: "earliest first" },
  { key: "took", api: "duration", label: "Took", desc: "longest first", asc: "shortest first" }
];
const PAGE = 40;
const REFRESH_MAX = 200;
const ARROWS = { descending: "M2.5 3.5L5 6l2.5-2.5", ascending: "M2.5 6.5L5 4l2.5 2.5", none: "M2.5 3.8L5 1.5l2.5 2.3M2.5 6.2L5 8.5l2.5-2.3" };

export function executions(root, { params, me }) {
  const stalled = params.get("stalled") === "1";
  const stallText = duration((me.stalled_after || 900) * 1000);
  const range = stalled ? null : findRange(params.get("range"));
  const group = stalled ? GROUPS[1] : GROUPS.find((candidate) => candidate.key === (params.get("status") || "")) || GROUPS[0];
  const saga = params.get("saga") || "";
  const step = params.get("step") || "";
  const error = params.get("error") || "";
  const errorStep = params.get("error_step") || "";
  const sorts = stalled ? SORTS.slice(0, 1) : SORTS;
  let sort = sorts.find((candidate) => candidate.key === params.get("sort")) || SORTS[0];
  let dir = params.get("dir") === "asc" ? "asc" : "desc";
  let destroyed = false;
  let rows = [];
  let next = null;
  let version = 0;

  const hashFor = (changes) => {
    const query = new URLSearchParams({
      status: stalled ? "" : group.key, saga, step, error, error_step: errorStep,
      range: range ? range.key : "", stalled: stalled ? "1" : "",
      sort: sort === SORTS[0] ? "" : sort.key, dir: dir === "desc" ? "" : dir, ...changes
    });
    for (const [key, value] of [...query]) if (!value) query.delete(key);
    return `#/executions${query.toString() ? `?${query}` : ""}`;
  };
  const go = (changes) => { location.hash = hashFor(changes); };

  const seg = h("div", { class: "seg", role: "group", "aria-label": "Status" },
    GROUPS.map((candidate) => h("button", {
      type: "button", "aria-pressed": String(candidate === group), onclick: () => go({ status: candidate.key, stalled: "" })
    }, candidate.label)));
  const select = h("select", { class: "select", "aria-label": "Saga" }, h("option", { value: "" }, "Every saga"));
  select.addEventListener("change", () => go({ saga: select.value, step: "" }));
  const chip = step ? h("button", { type: "button", class: "chip", onclick: () => go({ step: "" }), "aria-label": `Stop filtering by ${step}` },
    "at ", h("b", {}, step), h("span", { "aria-hidden": "true" }, "×")) : null;
  const rangeChip = range ? h("button", { type: "button", class: "chip", onclick: () => go({ range: "" }), "aria-label": `Stop limiting to ${range.phrase}` },
    "in ", h("b", {}, range.phrase.replace("the ", "")), h("span", { "aria-hidden": "true" }, "×")) : null;
  const stalledChip = stalled ? h("button", { type: "button", class: "chip", onclick: () => go({ stalled: "", status: "moving" }), "aria-label": "Show every execution in flight" },
    h("b", {}, `no progress for ${stallText}+`), h("span", { "aria-hidden": "true" }, "×")) : null;
  const errorLabel = [error && shortError(error), errorStep && `at ${errorStep}`].filter(Boolean).join(" ");
  const errorChip = error || errorStep ? h("button", { type: "button", class: "chip", onclick: () => go({ error: "", error_step: "" }), "aria-label": `Stop filtering by ${errorLabel}`, title: error || null },
    "failed with ", h("b", {}, errorLabel), h("span", { "aria-hidden": "true" }, "×")) : null;

  const headers = new Map();
  const sortHeader = (candidate) => {
    const path = s("path", {});
    const th = h("th", { scope: "col" },
      h("button", { type: "button", class: "sort", onclick: () => pickSort(candidate, null) }, candidate.label,
        s("svg", { viewBox: "0 0 10 10", width: 10, height: 10, "aria-hidden": "true" }, path)));
    headers.set(candidate.key, { th, path });
    return th;
  };
  const picker = h("select", { class: "select sort-pick", "aria-label": "Sort" },
    sorts.flatMap((candidate) => ["desc", "asc"].map((way) => h("option", { value: `${candidate.key}:${way}` }, `${candidate.label}, ${candidate[way]}`))));
  picker.addEventListener("change", () => {
    const [key, way] = picker.value.split(":");
    pickSort(SORTS.find((candidate) => candidate.key === key), way);
  });

  const caption = h("caption", { class: "visually-hidden" });
  const body = h("tbody");
  const table = h("table", { class: "rows" },
    caption,
    h("thead", {}, h("tr", {},
      h("th", { class: "r-glyph", scope: "col" }, h("span", { class: "visually-hidden" }, "Position on the line")),
      h("th", { scope: "col" }, "Resource"),
      h("th", { class: "r-saga-col", scope: "col" }, "Saga"),
      h("th", { scope: "col" }, "Step"),
      h("th", { scope: "col" }, "Status"),
      sortHeader(SORTS[0]),
      stalled ? h("th", { scope: "col" }, "Waiting") : sortHeader(SORTS[1]))),
    body);
  const more = h("button", { type: "button", class: "btn btn-quiet", hidden: true });
  const status = h("p", { class: "empty", hidden: true });

  root.append(
    h("div", { class: "list-head" },
      h("h1", { class: "list-title" }, saga ? saga : stalled ? "Stalled executions" : "Executions"),
      h("div", { class: "filters" }, seg, select, picker, chip, errorChip, rangeChip, stalledChip)),
    table, status, h("div", { class: "more-row" }, more));

  let definitions = new Map();

  function showSort() {
    for (const [key, { th, path }] of headers) {
      const state = key === sort.key ? (dir === "desc" ? "descending" : "ascending") : "none";
      if (state === "none") th.removeAttribute("aria-sort");
      else th.setAttribute("aria-sort", state);
      path.setAttribute("d", ARROWS[state]);
    }
    picker.value = `${sort.key}:${dir}`;
    table.classList.toggle("is-by-took", sort.key === "took");
    caption.textContent = `Executions, sorted by ${sort.label.toLowerCase()}, ${sort[dir]}`;
    more.textContent = sort === SORTS[0] && dir === "desc" ? "Show older" : "Show more";
  }

  // A header sorts by its column, or flips the direction when it already
  // does. The list starts over in the new order; the URL keeps it.
  function pickSort(candidate, way) {
    dir = way || (candidate === sort ? (dir === "desc" ? "asc" : "desc") : "desc");
    sort = candidate;
    history.replaceState(null, "", hashFor({}));
    showSort();
    version++;
    rows = [];
    next = null;
    more.hidden = true;
    refresh().catch(() => {});
  }

  function draw() {
    const now = Date.now();
    refill(body, rows.map((execution) => {
      const href = `#/executions/${encodeURIComponent(execution.id)}`;
      const started = toTime(execution.started_at);
      const end = toTime(execution.finished_at);
      const tr = h("tr", {},
        h("td", { class: "r-glyph" }, glyph(execution, definitions.get(execution.saga_name))),
        h("td", { class: "r-res" }, h("a", { href }, `${execution.resource_type} ${execution.resource_id}`)),
        h("td", { class: "r-saga-col" }, execution.saga_name),
        h("td", { class: "r-step" }, execution.current_step || ""),
        h("td", { class: "r-state" }, h("span", { class: `state state-${execution.status}` }, statusLabel(execution.status))),
        h("td", { class: "r-when" }, h("time", { datetime: execution.started_at }, ago(started))),
        h("td", { class: "r-took" }, stalled ? waited(now - toTime(execution.last_progress_at)) : took(execution, started, end)));
      tr.addEventListener("click", (event) => { if (!event.target.closest("a")) location.hash = href; });
      return tr;
    }));
    status.hidden = rows.length > 0;
    status.textContent = "No executions match these filters. Try another status or saga.";
    more.hidden = !next;
  }

  // With an error filter the range bounds when the attempt failed, as the
  // counts under "Needs attention" do, rather than when the execution started.
  function took(execution, started, end) {
    if (execution.duration_ms !== null && execution.duration_ms !== undefined) return duration(execution.duration_ms);
    return end ? duration(end - started) : "";
  }

  function query(after, limit = PAGE) {
    const since = range ? rangeFrom(range) : null;
    const byError = Boolean(error || errorStep);
    return {
      status: group.statuses, saga: saga || null, step: step || null, error: error || null, error_step: errorStep || null,
      stalled: stalled ? 1 : null, from: byError ? null : since, error_from: byError ? since : null,
      sort: sort.api, dir, after, limit
    };
  }

  // Polls reload every row shown so far, in the current order.
  async function refresh() {
    if (rows.length > REFRESH_MAX) return;
    const asked = version;
    const [defs, data] = await Promise.all([sagaDefinitions(), api.executions(query(null, Math.min(REFRESH_MAX, Math.max(PAGE, rows.length))))]);
    if (destroyed || asked !== version) return;
    definitions = defs;
    if (select.options.length === 1) {
      for (const name of defs.keys()) select.append(h("option", { value: name, selected: name === saga }, name));
    }
    rows = data.executions;
    next = data.next;
    draw();
  }

  more.addEventListener("click", async () => {
    const asked = version;
    more.disabled = true;
    try {
      const data = await api.executions(query(next));
      if (destroyed || asked !== version) return;
      const shown = new Set(rows.map((execution) => execution.id));
      rows = rows.concat(data.executions.filter((execution) => !shown.has(execution.id)));
      next = data.next;
      draw();
    } finally {
      more.disabled = false;
    }
  });

  showSort();

  const stop = every(pollMs, refresh);
  return { destroy() { destroyed = true; stop(); } };
}

import { h, replace, keepFocus } from "../dom.js";
import { serial } from "../poller.js";
import { api } from "../api.js";
import { href, replaceQuery } from "../router.js";
import { ago, fullTime, rangeWindow, shortId, shortTime, statusLabel, STATUSES } from "../format.js";
import { signal, select, empty, failure, heading, liveDuration } from "../ui.js";

const PAGE = 50;
const MAX_REFRESH = 200;
const RANGE_OPTIONS = [
  { value: "", label: "Any time" },
  { value: "1h", label: "Last hour" },
  { value: "24h", label: "Last 24 h" },
  { value: "7d", label: "Last 7 d" }
];

function readFilters(query) {
  return {
    saga: query.saga || "",
    status: (query.status || "").split(",").filter(Boolean),
    step: query.step || "",
    partition: query.partition || "",
    resource: query.resource || "",
    range: query.range || ""
  };
}

export function executions(root, { route, navigate }) {
  const filters = readFilters(route.query);
  let rows = [];
  let nextBefore = null;
  let seen = new Map();
  let loaded = false;
  let generation = 0;
  let snapshot = null;
  const queue = serial();

  const body = h("tbody");
  const results = h("div", { class: "results" });
  const more = h("div", { class: "more" });
  const sheet = h("div", { class: "filters", id: "filters" });
  const sheetToggle = h("button", { type: "button", class: "button filters-toggle", "aria-controls": "filters", "aria-expanded": "false" });
  sheetToggle.addEventListener("click", () => toggleSheet());
  sheet.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && sheet.classList.contains("open")) {
      event.stopPropagation();
      toggleSheet(false);
    }
  });

  replace(root,
    heading("Executions", sheetToggle),
    sheet,
    results,
    more);

  api.sagas({}).then((data) => buildFilters(data.sagas)).catch(() => buildFilters([]));

  function activeCount() {
    return [filters.saga, filters.step, filters.partition, filters.resource, filters.range].filter(Boolean).length + (filters.status.length ? 1 : 0);
  }

  function toggleSheet(open = !sheet.classList.contains("open")) {
    const wasOpen = sheet.classList.contains("open");
    sheet.classList.toggle("open", open);
    sheetToggle.setAttribute("aria-expanded", String(open));
    if (open) sheet.querySelector("select, input, button")?.focus();
    else if (wasOpen) sheetToggle.focus();
  }

  function buildFilters(sagas) {
    const partitions = [...new Set(sagas.map((saga) => saga.partition).filter(Boolean))].sort();
    const statusGroup = h("div", { class: "chips", role: "group", "aria-label": "Status" },
      STATUSES.map((status) => {
        const button = h("button", { type: "button", class: "chip-toggle", "aria-pressed": String(filters.status.includes(status)) }, signal(status));
        button.addEventListener("click", () => {
          filters.status = filters.status.includes(status) ? filters.status.filter((item) => item !== status) : [...filters.status, status];
          button.setAttribute("aria-pressed", String(filters.status.includes(status)));
          changed();
        });
        return button;
      }));
    const search = h("input", { type: "search", class: "input", placeholder: "Resource type or id", value: filters.resource, "aria-label": "Search resource" });
    let debounce;
    search.addEventListener("input", () => {
      clearTimeout(debounce);
      debounce = setTimeout(() => {
        filters.resource = search.value.trim();
        changed();
      }, 300);
    });

    replace(sheet,
      h("div", { class: "filters-row" },
        field("Saga", select({ label: "Saga", value: filters.saga, options: [{ value: "", label: "All sagas" }, ...sagas.map((saga) => ({ value: saga.name, label: saga.name }))], onChange: (value) => set("saga", value) })),
        field("Partition", select({ label: "Partition", value: filters.partition, options: [{ value: "", label: "Any partition" }, ...partitions.map((name) => ({ value: name, label: name }))], onChange: (value) => set("partition", value) })),
        field("Started", select({ label: "Started", value: filters.range, options: RANGE_OPTIONS, onChange: (value) => set("range", value) })),
        field("Resource", search)),
      h("div", { class: "filters-row" },
        statusGroup,
        filters.step ? h("button", { type: "button", class: "chip chip-removable", "aria-label": `Remove step filter ${filters.step}`, onclick: removeStep }, `Step ${filters.step}`, h("span", { "aria-hidden": "true" }, " ×")) : null,
        activeCount() ? h("button", { type: "button", class: "button button-quiet", onclick: clearAll }, "Clear filters") : null,
        h("button", { type: "button", class: "button sheet-done", onclick: () => toggleSheet(false) }, "Show results")));
    sheetToggle.textContent = activeCount() ? `Filters (${activeCount()})` : "Filters";
  }

  function field(label, control) {
    return h("label", { class: "field" }, h("span", { class: "field-label" }, label), control);
  }

  function set(key, value) {
    filters[key] = value;
    changed();
  }

  function clearAll() {
    navigate(href("/executions"));
  }

  function removeStep() {
    navigate(href("/executions", { ...filters, step: "" }));
  }

  function changed() {
    replaceQuery("/executions", filters);
    sheetToggle.textContent = activeCount() ? `Filters (${activeCount()})` : "Filters";
    generation += 1;
    snapshot = null;
    rows = [];
    nextBefore = null;
    seen = new Map();
    loaded = false;
    refresh().catch(() => null);
  }

  function params(extra) {
    return {
      saga: filters.saga,
      status: filters.status,
      step: filters.step,
      partition: filters.partition,
      resource: filters.resource,
      ...rangeWindow(filters.range),
      ...extra
    };
  }

  function refresh() {
    return queue(load);
  }

  async function load() {
    const ticket = generation;
    const limit = Math.min(MAX_REFRESH, Math.max(PAGE, rows.length));
    try {
      const data = await api.executions(params({ limit }));
      if (ticket !== generation) return;
      const next = JSON.stringify(data);
      if (next === snapshot) return;
      snapshot = next;
      if (rows.length > MAX_REFRESH && data.executions.length) {
        const oldest = data.executions[data.executions.length - 1].id;
        rows = [...data.executions, ...rows.filter((row) => row.id < oldest)];
      } else {
        rows = data.executions;
        nextBefore = data.next_before;
      }
      render();
    } catch (error) {
      if (ticket === generation) {
        snapshot = null;
        replace(results, failure(error));
      }
      throw error;
    }
  }

  function loadOlder(button) {
    button.disabled = true;
    queue(async () => {
      const ticket = generation;
      if (!nextBefore) return;
      try {
        const data = await api.executions(params({ limit: PAGE, before: nextBefore }));
        if (ticket !== generation) return;
        rows = [...rows, ...data.executions];
        nextBefore = data.next_before;
        snapshot = null;
        render();
      } catch (error) {
        if (ticket === generation) replace(more, failure(error));
      }
    });
  }

  function render() {
    const changedIds = new Set(rows.filter((row) => loaded && seen.get(row.id) !== row.status).map((row) => row.id));
    seen = new Map(rows.map((row) => [row.id, row.status]));
    loaded = true;
    if (!rows.length) {
      replace(results, empty("No executions match these filters."));
      replace(more);
      return;
    }
    keepFocus(root, () => {
      replace(body, rows.map((row) => tableRow(row, changedIds.has(row.id))));
      drawTable();
    });
  }

  function drawTable() {
    replace(results, h("table", { class: "table executions-table" },
      h("caption", { class: "visually-hidden" }, "Executions, newest first"),
      h("thead", {}, h("tr", {},
        h("th", { scope: "col" }, "Status"),
        h("th", { scope: "col" }, "Saga"),
        h("th", { scope: "col" }, "Resource"),
        h("th", { scope: "col", class: "col-step" }, "Step"),
        h("th", { scope: "col", class: "col-partition" }, "Partition"),
        h("th", { scope: "col", class: "col-started" }, "Started"),
        h("th", { scope: "col", class: "col-duration num" }, "Duration"),
        h("th", { scope: "col", class: "col-id" }, "Id"))),
      body));
    replace(more, nextBefore ? h("button", { type: "button", class: "button", dataset: { key: "load-older" }, onclick: (event) => loadOlder(event.currentTarget) }, "Load older") : h("p", { class: "muted" }, `${rows.length} shown, that is all of them.`));
  }

  function tableRow(row, flash) {
    const link = href(`/executions/${encodeURIComponent(row.id)}`);
    const node = h("tr", { class: ["row-link", flash ? "flash" : null] },
      h("td", { class: "col-status" }, signal(row.status)),
      h("td", { class: "col-saga" }, h("a", { href: link, class: "saga-name", dataset: { key: `row:${row.id}` } }, row.saga_name)),
      h("td", { class: "col-resource" }, h("span", { class: "muted" }, row.resource_type), " ", row.resource_id),
      h("td", { class: "col-step" }, row.direction === "compensate" ? `↩ ${row.current_step || ""}` : row.current_step || ""),
      h("td", { class: "col-partition" }, row.partition || ""),
      h("td", { class: "col-started" }, h("time", { datetime: row.started_at || row.created_at, title: fullTime(row.started_at || row.created_at) }, shortTime(row.started_at || row.created_at))),
      h("td", { class: "col-duration num" }, liveDuration(row)),
      h("td", { class: "col-id" }, h("span", { title: row.id }, shortId(row.id))),
      h("td", { class: "col-age", "aria-hidden": "true" }, ago(row.started_at || row.created_at)));
    node.addEventListener("click", (event) => {
      if (event.target.closest("a, button") || window.getSelection()?.toString()) return;
      navigate(link);
    });
    node.title = `${row.saga_name}: ${statusLabel(row.status).toLowerCase()}`;
    return node;
  }

  return { refresh, destroy() {} };
}

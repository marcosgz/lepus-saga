import { api } from "../api.js";
import { h, s, clear, refill } from "../dom.js";
import { every, pollMs } from "../live.js";
import { LineMap } from "../map.js";
import { rememberSagas } from "../sagas.js";
import { ago, compact, count, dayMonth, duration, hourMinute, plural, toTime, waited } from "../format.js";
import { Throughput } from "../throughput.js";
import { RANGES, findRange, rangeFrom, storeRange, storedRange } from "../range.js";

const MEDIAN_FALLBACK_MS = 3000;
const ERRORS_SHOWN = 8;
const WAITING_SHOWN = 10;
const PER_STATION = 9;
const STATIONS_FETCHED = 40;
const SETTLE_PER_POLL = 12;
const SLOW_MS = 30_000;

function symbol(kind) {
  const svg = s("svg", { viewBox: "0 0 20 20", "aria-hidden": "true" });
  if (kind === "move") svg.append(s("rect", { class: "sym-token", x: 1, y: 5, width: 18, height: 10, rx: 5 }));
  if (kind === "idle") svg.append(s("rect", { class: "sym-idle", x: 2, y: 5.5, width: 16, height: 9, rx: 4.5 }));
  if (kind === "stop") svg.append(s("rect", { class: "sym-stop", x: 7, y: 0, width: 6, height: 20, rx: 2 }));
  if (kind === "back") svg.append(s("rect", { class: "sym-back", x: 1, y: 5, width: 18, height: 10, rx: 5 }));
  return h("span", { class: "sym" }, svg);
}

const shortError = (name) => (name ? name.split("::").pop() : "Unknown error");
const withoutStep = (message, step) => (message || "").replace(`${step}: `, "");

// A compact number for the eye and the exact one for screen readers.
function amount(n, { exact = count(n), cls = "n" } = {}) {
  const shown = typeof n === "number" ? compact(n) : n;
  if (shown === exact) return h("span", { class: cls }, shown);
  return h("span", { class: cls, title: exact },
    h("span", { "aria-hidden": "true" }, shown),
    h("span", { class: "visually-hidden" }, exact));
}

function stationHref(saga, step, status, range) {
  const query = new URLSearchParams({ saga, step });
  if (status) query.set("status", status);
  if (status && range) query.set("range", range.key);
  return `#/executions?${query}`;
}

function errorHref(group, range) {
  const query = new URLSearchParams({ saga: group.saga_name, error: group.error_class || "", error_step: group.step_name, range: range.key });
  return `#/executions?${query}`;
}

function stationCounts(station) {
  const stalled = station.stalled || {};
  const idleFwd = stalled.running || 0;
  const idleBack = stalled.compensating || 0;
  return {
    moving: Math.max(0, (station.running || 0) - idleFwd),
    undoing: Math.max(0, (station.compensating || 0) - idleBack),
    stalled: idleFwd + idleBack
  };
}

export function overview(root, { me, params }) {
  const stallText = duration((me.stalled_after || 900) * 1000);
  let range = findRange(params && params.get("range")) || storedRange() || findRange("24h");
  const rangeHash = () => `#/?range=${range.key}`;
  if (location.hash !== rangeHash()) history.replaceState(null, "", rangeHash());

  const headline = h("h1", { class: "headline" }, h("span", { class: "quiet" }, "Reading the lines"));
  const rangeButtons = RANGES.map((candidate) => h("button", {
    type: "button",
    "aria-pressed": String(candidate === range),
    onclick: () => pickRange(candidate)
  }, candidate.short));
  const rangeGroup = h("div", { class: "range-row" },
    h("span", { class: "range-label", id: "range-label" }, "Time range"),
    h("div", { class: "seg range", role: "group", "aria-labelledby": "range-label" }, rangeButtons));
  const subline = h("p", { class: "subline" });
  const mapHost = h("div", { class: "map" });
  const throughputNote = h("p", { class: "section-note" });
  const throughputHost = h("div", { class: "tp" });
  const attention = h("ul", { class: "errs" });
  const attentionNote = h("p", { class: "section-note" });
  const attentionShowMore = h("button", { type: "button", class: "btn btn-quiet btn-small", hidden: true, onclick: () => showMoreErrors() });
  const attentionMore = h("a", { class: "link-more" });
  const waiting = h("ul", { class: "stops" });
  const waitingNote = h("p", { class: "section-note" });
  const waitingMore = h("a", { class: "link-more", href: "#/executions?stalled=1" });
  root.append(
    headline,
    rangeGroup,
    subline,
    mapHost,
    h("section", { class: "through", "aria-labelledby": "through-title" },
      h("div", { class: "through-head" },
        h("h2", { class: "section-title", id: "through-title" }, "Throughput"),
        throughputNote),
      throughputHost),
    h("div", { class: "lower" },
      h("section", { "aria-labelledby": "attention-title" },
        h("h2", { class: "section-title", id: "attention-title" }, "Needs attention"),
        attentionNote,
        attention,
        h("div", { class: "list-foot" }, attentionShowMore, attentionMore)),
      h("section", { "aria-labelledby": "waiting-title" },
        h("h2", { class: "section-title", id: "waiting-title" }, "Waiting the longest"),
        waitingNote,
        waiting,
        h("div", { class: "list-foot" }, waitingMore)))
  );
  const throughput = new Throughput(throughputHost);

  function describeRange() {
    subline.textContent = `Each line is a saga and each stop a step. Tokens are executions in flight right now, placed by how long they have spent in the step: halfway to the next stop at the step's median. Red bars are failures in ${range.phrase}. Point at a stop for exact counts, select it to list its executions.`;
    throughputNote.textContent = `Executions per ${range.per} in ${range.phrase}, stacked by how they ended. The line counts starts.`;
    attentionMore.href = `#/executions?status=failed&range=${range.key}`;
  }
  describeRange();

  let failureTotal = null;
  let errorGroups = null;
  let errorsShown = ERRORS_SHOWN;

  function pickRange(next) {
    if (next === range) return;
    range = next;
    storeRange(range);
    history.replaceState(null, "", rangeHash());
    rangeButtons.forEach((button, index) => button.setAttribute("aria-pressed", String(RANGES[index] === range)));
    describeRange();
    errorsShown = ERRORS_SHOWN;
    map.setTerminals(terminals(null));
    refresh().catch(() => {});
    refreshSlow().catch(() => {});
  }

  const map = new LineMap(mapHost, { label: "Saga lines with executions in flight" });
  map.setTerminals(terminals(null));
  const tokens = new Map();
  let definitions = new Map();
  let expected = new Map();
  let first = true;
  let destroyed = false;

  const lineFor = (saga) => definitions.get(saga);
  const stepIndex = (saga, step) => {
    const def = lineFor(saga);
    return def ? def.steps.findIndex((candidate) => candidate.name === step) : -1;
  };

  async function loadLatency() {
    try {
      const data = await api.latency();
      expected = new Map(data.rows.filter((row) => row.p50).map((row) => [`${row.saga_name}|${row.step_name}|${row.direction}`, row.p50]));
    } catch {}
  }

  function tokenSpec(token) {
    const def = lineFor(token.saga);
    const n = def ? def.steps.length : 0;
    const back = token.direction === "compensate";
    const spec = { id: token.id, line: token.saga, rail: back ? "back" : "fwd", target: token.index };
    if (token.exit === "completed") return { ...spec, rail: "fwd", target: n, kind: "move", leave: true, creep: null, linger: 0.2 };
    if (token.exit === "compensated") return { ...spec, rail: "back", target: -1, kind: "back", leave: true, creep: null, linger: 0.2 };
    if (token.exit === "failed") return { ...spec, kind: "stop", leave: true, creep: null, linger: 1.6 };
    if (token.exit) return { ...spec, leave: true, creep: null };
    const ms = expected.get(`${token.saga}|${token.step}|${token.direction}`) || MEDIAN_FALLBACK_MS;
    return {
      ...spec,
      kind: back ? "back" : "move",
      creep: { from: token.since, ms, dir: back ? -1 : 1 }
    };
  }

  let partialStations = null;

  function sync() {
    const specs = [...tokens.values()].map((token) => {
      const spec = tokenSpec(token);
      if (token.fresh) {
        token.fresh = false;
        return { ...spec, from: -1 };
      }
      return spec;
    });
    map.setTokens(specs, partialStations);
  }

  async function settle(id) {
    const token = tokens.get(id);
    try {
      const { execution } = await api.execution(id);
      token.exit = ["completed", "compensated", "failed", "compensation_failed"].includes(execution.status)
        ? (execution.status === "compensation_failed" ? "failed" : execution.status)
        : "gone";
      token.index = stepIndex(token.saga, execution.current_step);
    } catch {
      token.exit = "gone";
    }
    sync();
    setTimeout(() => { tokens.delete(id); }, 4000);
  }

  function renderHeadline({ moving, back, stalled, failed }) {
    const parts = [];
    const add = (n, kind, words) => parts.push([h("span", { class: "part" }, symbol(kind), amount(n), " ", words)]);
    add(moving, "move", "moving");
    if (back) add(back, "back", "compensating");
    if (stalled) add(stalled, "idle", "stalled");
    add(failed, "stop", failed === 1 ? "failure" : "failures");
    clear(headline);
    parts.forEach((part, index) => {
      if (index > 0) headline.append(index === parts.length - 1 ? " and " : ", ");
      headline.append(...part);
    });
    headline.append(h("span", { class: "window" }, ` in ${range.phrase}`), ".");
  }

  function renderLines(sagas) {
    const lines = sagas.filter((saga) => saga.steps.length).map((saga) => {
      const totals = saga.totals || {};
      const failed = (totals.failed || 0) + (totals.compensation_failed || 0);
      const runs = Object.values(totals).reduce((sum, n) => sum + n, 0);
      const decor = {};
      saga.steps.forEach((step, index) => {
        const station = saga.stations[step.name] || {};
        const blocks = (station.failed || 0) + (station.compensation_failed || 0);
        const { moving, undoing, stalled } = stationCounts(station);
        const tip = [`${step.name}, step ${index + 1} of ${saga.steps.length}`];
        if (moving || undoing || stalled) {
          const bits = [];
          if (moving) bits.push(`${count(moving)} running`);
          if (undoing) bits.push(`${count(undoing)} compensating`);
          if (stalled) bits.push(`${count(stalled)} waiting ${stallText}+`);
          tip.push(`Now: ${bits.join(", ")}`);
        } else {
          tip.push("Nothing here right now");
        }
        if (blocks) tip.push(`${plural(blocks, "execution")} failed here in ${range.phrase}`);
        if (station.attempt_failures) tip.push(`${plural(station.attempt_failures, "failed attempt")}, retries included`);
        decor[index] = { blocks, moving, undoing, stalled, tip, title: tip.join(". ") };
      });
      const meta = [{ text: `${plural(runs, "run")} in ${range.short}` }];
      if (failed) meta.push({ text: ", " }, { text: `${count(failed)} failed`, stop: true });
      return {
        name: saga.name,
        steps: saga.steps,
        meta,
        decor,
        sagaHref: `#/executions?saga=${encodeURIComponent(saga.name)}`,
        href: (index) => stationHref(saga.name, saga.steps[index].name, (decor[index].blocks ? "failed" : null), range)
      };
    });
    map.setLines(lines);
  }

  function row(execution, { idle, when, side, detail }) {
    return h("li", {},
      h("a", { class: "stop-row", href: `#/executions/${encodeURIComponent(execution.id)}` },
        h("span", { class: idle ? "stop-bar is-idle" : "stop-bar", "aria-hidden": "true" }),
        h("span", { class: "stop-title" },
          `${execution.resource_type} ${execution.resource_id} `,
          h("span", { class: "at" }, `at ${execution.saga_name} / ${execution.current_step}`)),
        h("span", { class: idle ? "stop-when is-wait" : "stop-when" }, side),
        h("span", { class: idle ? "stop-reason is-idle" : "stop-reason" }, detail),
        when ? h("span", { class: "visually-hidden" }, when) : null));
  }

  function terminals(sums) {
    const n = (key) => (sums ? count(sums[key]) : "…");
    return {
      start: { n: n("started"), label: `started in ${range.short}` },
      end: { n: n("completed"), label: `completed in ${range.short}` }
    };
  }

  function showMoreErrors() {
    const first = attention.children.length;
    errorsShown += ERRORS_SHOWN;
    renderAttention();
    const next = attention.children[first];
    if (next) next.querySelector("a")?.focus();
  }

  function errorRow(group, top) {
    const share = h("span", { class: "err-share", "aria-hidden": "true" }, h("i"));
    share.firstChild.style.inlineSize = `${Math.max(2, (group.count / top) * 100)}%`;
    return h("li", { class: "err" },
      h("span", { class: "err-count" },
        amount(group.count, { cls: "err-n", exact: plural(group.count, "failed attempt") }),
        h("span", { class: "err-unit", "aria-hidden": "true" }, group.count === 1 ? "attempt" : "attempts")),
      h("div", { class: "err-body" },
        h("p", { class: "err-title" },
          h("b", {}, shortError(group.error_class)),
          h("span", { class: "at" }, ` at ${group.saga_name} / ${group.step_name}`)),
        share,
        group.sample_message ? h("p", { class: "err-msg" }, withoutStep(group.sample_message, group.step_name)) : null,
        h("p", { class: "err-links" },
          h("span", {}, `Last ${ago(group.last_seen_at)}`),
          group.sample_execution_id ? h("a", { href: `#/executions/${encodeURIComponent(group.sample_execution_id)}` }, "Latest example") : null,
          h("a", { href: errorHref(group, range) }, `${plural(group.execution_count, "execution")} hit this`))));
  }

  // Failed attempts grouped by error, saga and step, most frequent first.
  function renderAttention() {
    const groups = errorGroups || [];
    const total = groups.reduce((sum, group) => sum + group.count, 0);
    const shown = groups.slice(0, errorsShown);
    const left = groups.length - shown.length;
    attentionMore.href = `#/executions?status=failed&range=${range.key}`;
    attentionMore.textContent = `All ${count(failureTotal || 0)} failed executions in ${range.phrase}`;
    attentionMore.hidden = !failureTotal;
    attentionShowMore.hidden = left <= 0;
    attentionShowMore.textContent = `Show ${Math.min(left, ERRORS_SHOWN)} more of ${count(left)}`;
    if (!groups.length) {
      attentionNote.textContent = failureTotal ? `No failed attempts recorded in ${range.phrase}.` : "";
      const wider = RANGES[RANGES.indexOf(range) + 1];
      refill(attention, h("li", { class: "empty" },
        `Nothing failed in ${range.phrase}. `,
        wider
          ? h("button", { type: "button", class: "inline-link", onclick: () => pickRange(wider) }, `Look back over ${wider.phrase.replace("the last ", "")}`)
          : "Every line ran clean all week."));
      return;
    }
    const kinds = groups.length === 1 ? "" : `, in ${count(groups.length)} groups by error and step, most frequent first`;
    attentionNote.textContent = `${plural(total, "failed attempt")} in ${range.phrase}${kinds}. Retries count, so one execution can fail more than once.`;
    const top = groups[0].count;
    refill(attention, shown.map((group) => errorRow(group, top)));
  }

  function renderWaiting(stalled, total) {
    const now = Date.now();
    const shown = Math.min(stalled.length, WAITING_SHOWN);
    waitingNote.textContent = total > shown
      ? `No progress for ${stallText} or more, right now. The ${shown} longest waits of ${count(total)}.`
      : `No progress for ${stallText} or more, right now. Longest wait first.`;
    const more = total - shown;
    waitingMore.textContent = more > 0 ? `+${count(more)} more stalled executions` : `All ${count(total)} stalled executions`;
    waitingMore.hidden = !total;
    if (!stalled.length) {
      refill(waiting, h("li", { class: "empty" }, `Every execution in flight made progress in the last ${stallText}. Tokens on the map show where each one is.`));
      return;
    }
    refill(waiting, stalled.slice(0, WAITING_SHOWN).map((execution) => {
      const at = toTime(execution.last_progress_at) || toTime(execution.updated_at);
      const steps = lineFor(execution.saga_name)?.steps || [];
      const index = steps.findIndex((step) => step.name === execution.current_step);
      const bits = [index >= 0 ? `Step ${index + 1} of ${steps.length}` : "Step not in the current definition"];
      if (execution.direction === "compensate") bits.push("compensating");
      if (execution.resume_count) bits.push(`resumed ${plural(execution.resume_count, "time")}`);
      bits.push(`stuck since ${new Date(at).toDateString() === new Date(now).toDateString() ? hourMinute(at) : dayMonth(at)}`);
      return row(execution, {
        idle: true,
        side: h("span", {}, h("span", { class: "visually-hidden" }, "Waiting "), waited(now - at)),
        detail: bits.join(", ")
      });
    }));
  }

  async function refresh() {
    const asked = range;
    const [sagaData, stalledData, movingData] = await Promise.all([
      api.sagas({ from: rangeFrom(asked) }),
      api.stalled({ limit: WAITING_SHOWN }),
      api.moving({ per_station: PER_STATION, stations: STATIONS_FETCHED })
    ]);
    if (destroyed || asked !== range) return;
    rememberSagas(sagaData.sagas);
    definitions = new Map(sagaData.sagas.map((saga) => [saga.name, saga]));

    const totals = { moving: 0, back: 0, stalled: 0, failed: 0 };
    const busy = new Set();
    for (const saga of sagaData.sagas) {
      const sagaTotals = saga.totals || {};
      totals.failed += (sagaTotals.failed || 0) + (sagaTotals.compensation_failed || 0);
      for (const [step, station] of Object.entries(saga.stations || {})) {
        const { moving, undoing, stalled } = stationCounts(station);
        totals.moving += moving;
        totals.back += undoing;
        totals.stalled += stalled;
        if (moving || undoing) busy.add(`${saga.name}|${step}`);
      }
    }

    renderLines(sagaData.sagas);
    renderWaiting(stalledData.executions, totals.stalled);
    renderHeadline(totals);
    failureTotal = totals.failed;
    if (errorGroups) renderAttention();

    // A station whose list was cut short, or left out, draws the rest of its
    // count as a pill; its missing tokens may still be there.
    const partial = new Set(busy);
    const seen = new Set();
    for (const station of movingData.stations) {
      const key = `${station.saga_name}|${station.step_name}`;
      if (station.executions.length >= station.count) partial.delete(key);
      for (const execution of station.executions) {
        const index = stepIndex(execution.saga_name, execution.current_step);
        if (index < 0) continue;
        seen.add(execution.id);
        const existing = tokens.get(execution.id);
        const since = toTime(execution.last_progress_at) || Date.now();
        if (existing && !existing.exit) {
          if (existing.index !== index || existing.direction !== execution.direction) existing.since = since;
          Object.assign(existing, { index, step: execution.current_step, direction: execution.direction });
        } else if (!existing) {
          const token = { id: execution.id, saga: execution.saga_name, index, step: execution.current_step, direction: execution.direction, since };
          tokens.set(execution.id, token);
          if (!first) token.fresh = true;
        }
      }
    }

    partialStations = new Set([...partial].map((key) => {
      const [saga, step] = key.split("|");
      return `${saga}|${stepIndex(saga, step)}`;
    }));

    // Tokens that left a fully listed station are looked up to show how they
    // ended; at a partial one they just drop out.
    let settling = 0;
    for (const [id, token] of tokens) {
      if (seen.has(id) || token.exit || token.settling) continue;
      if (partial.has(`${token.saga}|${token.step}`) || settling >= SETTLE_PER_POLL) {
        tokens.delete(id);
        continue;
      }
      token.settling = true;
      settling++;
      settle(id);
    }
    sync();
    first = false;
  }

  async function refreshSlow() {
    const asked = range;
    const from = rangeFrom(asked);
    const current = () => !destroyed && asked === range;
    await Promise.all([
      api.series({ from, bucket: asked.bucket }).then((series) => {
        if (!current()) return;
        throughput.set(series, asked);
        map.setTerminals(terminals(throughput.sums()));
      }),
      api.failures({ from, limit: 200 }).then((failures) => {
        if (!current()) return;
        errorGroups = failures.failures;
        renderAttention();
      }),
      expected.size ? null : loadLatency()
    ]);
  }

  const stops = [every(pollMs, refresh), every(() => Math.max(SLOW_MS, pollMs()), refreshSlow)];

  return {
    destroy() {
      destroyed = true;
      stops.forEach((stop) => stop());
      map.destroy();
      throughput.destroy();
    }
  };
}

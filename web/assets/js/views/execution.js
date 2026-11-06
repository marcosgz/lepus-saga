import { api } from "../api.js";
import { h, s, clear, toast, copyButton, reducedMotion } from "../dom.js";
import { every, pollMs } from "../live.js";
import { LineMap } from "../map.js";
import { ago, duration, offset, plural, stamp, statusLabel, toTime } from "../format.js";

const SECONDS_PER_EVENT = 0.85;

// One keyframe per attempt, plus the start and, once it ends, the end.
function keyframes(data) {
  const { execution, definition, attempts } = data;
  const steps = definition.steps;
  const n = steps.length;
  const index = (name) => steps.findIndex((step) => step.name === name);
  const start = toTime(execution.started_at || execution.created_at);
  const frames = [{ kind: "start", pos: -1, rail: "fwd", at: start }];
  const sorted = [...attempts].sort((a, b) => toTime(a.started_at) - toTime(b.started_at));
  for (const attempt of sorted) {
    frames.push({
      kind: "attempt",
      attempt,
      pos: index(attempt.step_name),
      rail: attempt.direction === "compensate" ? "back" : "fwd",
      at: toTime(attempt.started_at)
    });
  }
  const end = toTime(execution.finished_at);
  const last = frames[frames.length - 1];
  if (execution.status === "completed") frames.push({ kind: "end", pos: n, rail: "fwd", at: end, status: "completed" });
  if (execution.status === "compensated") frames.push({ kind: "end", pos: -1, rail: "back", at: end, status: "compensated" });
  if (execution.status === "failed" || execution.status === "compensation_failed") {
    frames.push({ kind: "end", pos: last.pos, rail: last.rail, at: end || last.at, status: execution.status });
  }
  return frames.map((frame) => ({ ...frame, offset: Math.max(0, (frame.at || start) - start) }));
}

function frameOutcome(frame) {
  if (frame.kind === "start") return "start";
  if (frame.kind === "end") return ["failed", "compensation_failed"].includes(frame.status) ? "stop" : frame.status === "compensated" ? "back" : "ok";
  const { status, direction } = frame.attempt;
  if (status === "failed") return "stop";
  if (status === "running") return "run";
  return direction === "compensate" ? "back" : "ok";
}

function describe(frame, execution) {
  if (frame.kind === "start") return [h("b", {}, "Started"), ` for ${execution.resource_type} ${execution.resource_id}`];
  if (frame.kind === "end") {
    if (frame.status === "completed") return [h("b", {}, "Completed"), " every step"];
    if (frame.status === "compensated") return [h("b", {}, "Compensated"), ", every completed step undone"];
    return [h("b", {}, statusLabel(frame.status)), execution.failure_reason ? `: ${execution.failure_reason}` : ""];
  }
  const { attempt } = frame;
  const verb = attempt.direction === "compensate" ? "undo" : "attempt";
  const outcome = { succeeded: "succeeded", failed: "failed", running: "running", skipped: "skipped" }[attempt.status] || attempt.status;
  return [h("b", {}, attempt.step_name), ` ${verb} ${attempt.attempt} ${outcome}`, attempt.error_message ? `: ${attempt.error_message.replace(`${attempt.step_name}: `, "")}` : ""];
}

function story(data, frames, stallMs) {
  const { execution, attempts } = data;
  const tries = attempts.filter((a) => a.step_name === execution.current_step && a.direction === "execute").length;
  const undone = attempts.filter((a) => a.direction === "compensate" && a.status === "succeeded").length;
  const took = duration(toTime(execution.finished_at) - toTime(execution.started_at));
  const step = h("b", {}, execution.current_step);
  switch (execution.status) {
    case "completed": return ["Completed ", plural(data.definition.steps.length, "step"), " in ", took, "."];
    case "failed": return ["Failed at ", step, " after ", plural(tries, "attempt"), ", ", took, " after it started."];
    case "compensation_failed": return ["Compensation stopped at ", step, ". Some steps may still need undoing by hand."];
    case "compensated": {
      const failedStep = attempts.filter((a) => a.direction === "execute" && a.status === "failed").pop();
      return failedStep
        ? [h("b", {}, failedStep.step_name), " failed, then ", plural(undone, "step"), undone === 1 ? " was undone in " : " were undone in ", took, "."]
        : ["Compensated: ", plural(undone, "step"), " undone in ", took, "."];
    }
    case "compensating": return ["Undoing ", step, " now."];
    default: {
      const idle = Date.now() - toTime(execution.last_progress_at);
      if (idle > stallMs) return ["Waiting at ", step, " with no progress for ", duration(idle), ". The step message may be lost."];
      return ["Running ", step, tries > 1 ? `, attempt ${tries}` : "", "."];
    }
  }
}

export function execution(root, { id, me }) {
  root.append(h("p", { class: "loading" }, "Loading the execution"));
  let destroyed = false;
  let data = null;
  let frames = [];
  let u = 0;
  let playing = false;
  let raf = null;
  let map = null;
  let els = null;

  const stallMs = (me.stalled_after || 900) * 1000;
  const canAct = (action) => !me.read_only && me.actions && me.actions[action];

  function stationDecor(upTo) {
    const decor = {};
    const n = data.definition.steps.length;
    for (let i = 0; i < n; i++) decor[i] = { blocks: 0, state: null, title: data.definition.steps[i].name };
    let reached = -1;
    let backFrom = null;
    let backTo = null;
    frames.forEach((frame, k) => {
      if (k > upTo || frame.pos < 0 || frame.pos >= n) return;
      const d = decor[frame.pos];
      if (frame.kind !== "attempt") return;
      const { attempt } = frame;
      if (attempt.status === "failed") d.blocks += 1;
      if (attempt.direction === "execute") {
        reached = Math.max(reached, frame.pos);
        if (attempt.status === "succeeded") d.state = "passed";
        if (attempt.status === "running") d.state = "current";
      } else {
        if (backFrom === null) backFrom = frame.pos;
        backTo = frame.pos;
        if (attempt.status === "succeeded") d.state = "undone";
      }
    });
    const last = frames[Math.min(upTo, frames.length - 1)];
    if (last && last.kind === "end" && last.status === "completed") reached = n;
    if (last && last.kind === "end" && last.status === "compensated" && backTo !== null) backTo = -1;
    for (const [i, d] of Object.entries(decor)) {
      const bits = [data.definition.steps[i].name];
      if (d.state) bits.push(d.state === "passed" ? "succeeded" : d.state === "undone" ? "undone" : "running");
      if (d.blocks) bits.push(plural(d.blocks, "failed attempt"));
      d.title = bits.join(", ");
    }
    return { decor, progress: { reached, backFrom, backTo } };
  }

  function ease(t) {
    return t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
  }

  function seek(value, { fromInput = false } = {}) {
    const max = frames.length - 1;
    u = Math.max(0, Math.min(max, value));
    const k = Math.floor(u + 1e-6);
    const t = u - k;
    const a = frames[k];
    const b = frames[Math.min(max, k + 1)];
    const e = ease(t);
    const pos = a.pos + (b.pos - a.pos) * e;
    const rail = t > 0.02 ? b.rail : a.rail;
    const outcome = frameOutcome(frames[Math.min(max, Math.round(u))]);
    const kind = outcome === "stop" ? "stop" : rail === "back" ? "back" : outcome === "ok" && a.kind === "end" ? "done" : "move";
    map.place({ id: "replay", line: data.execution.saga_name, target: pos, rail, kind, big: true });
    const { decor, progress } = stationDecor(k);
    const line = map.lines[0];
    line.decor = decor;
    map.setLines([line]);
    map.setProgress({ ...progress, reached: Math.max(progress.reached, a.rail === "fwd" ? Math.min(pos, Math.max(a.pos, b.pos)) : progress.reached) });

    if (!fromInput) els.range.value = String(u);
    els.range.setAttribute("aria-valuetext", textOf(frames[k]));
    const current = frames[Math.round(u)] ? Math.round(u) : k;
    clear(els.now).append(h("span", {}, offset(frames[current].offset), "  "), ...describe(frames[current], data.execution));
    els.rows.forEach((row, index) => {
      if (index === current) row.setAttribute("aria-current", "step");
      else row.removeAttribute("aria-current");
      row.classList.toggle("is-future", index > current);
    });
    renderContext(current);
  }

  function textOf(frame) {
    const div = h("span", {}, ...describe(frame, data.execution));
    return `${offset(frame.offset)}, ${div.textContent}`;
  }

  function setPlaying(on) {
    playing = on;
    els.play.setAttribute("aria-label", on ? "Pause replay" : "Replay this execution");
    clear(els.play).append(on
      ? s("svg", { viewBox: "0 0 16 16", width: 16, height: 16, "aria-hidden": "true" }, s("rect", { x: 3, y: 2, width: 3.5, height: 12, rx: 1 }), s("rect", { x: 9.5, y: 2, width: 3.5, height: 12, rx: 1 }))
      : s("svg", { viewBox: "0 0 16 16", width: 16, height: 16, "aria-hidden": "true" }, s("path", { d: "M4 2.5v11a.7.7 0 0 0 1 .6l9-5.5a.7.7 0 0 0 0-1.2l-9-5.5a.7.7 0 0 0-1 .6z" })));
    cancelAnimationFrame(raf);
    if (!on) return;
    let last = null;
    const step = (time) => {
      if (!playing || destroyed) return;
      const dt = last === null ? 0 : (time - last) / 1000;
      last = time;
      const next = u + dt / SECONDS_PER_EVENT;
      if (next >= frames.length - 1) {
        seek(frames.length - 1);
        setPlaying(false);
        return;
      }
      seek(next);
      raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
  }

  function renderContext(k) {
    if (!els.ctx) return;
    let latest = null;
    let previous = null;
    for (let i = 0; i <= k; i++) {
      const frame = frames[i];
      if (frame.kind === "attempt" && frame.attempt.status === "succeeded" && frame.attempt.context_after && Object.keys(frame.attempt.context_after).length) {
        previous = latest;
        latest = frame.attempt.context_after;
      }
    }
    if (k === frames.length - 1 && data.execution.context) latest = latest ? { ...data.execution.context, ...latest } : data.execution.context;
    clear(els.ctx);
    if (!latest) {
      els.ctx.append(h("p", { class: "empty" }, "The context appears once the first step succeeds."));
      return;
    }
    const pre = h("pre", {});
    pre.append("{\n");
    const keys = Object.keys(latest);
    keys.forEach((key, index) => {
      const fresh = previous && !(key in previous);
      const line = h("span", { class: fresh ? "new" : null }, "  ", h("span", { class: "k" }, JSON.stringify(key)), ": ", JSON.stringify(latest[key]), index < keys.length - 1 ? "," : "");
      pre.append(line, "\n");
    });
    pre.append("}");
    els.ctx.append(pre);
  }

  async function act(kind, button) {
    button.disabled = true;
    try {
      if (kind === "retry") await api.retry(id);
      else await api.compensate(id, "compensated from the console");
      toast(kind === "retry" ? `Retried from ${data.execution.current_step}` : "Compensation started");
      await load(true);
    } catch (error) {
      toast(error.message, { error: true });
      button.disabled = false;
    }
  }

  function actions() {
    const { execution } = data;
    const wrap = h("div", { class: "x-actions" });
    const stalled = execution.status === "running" && Date.now() - toTime(execution.last_progress_at) > stallMs;
    if (canAct("retry") && (["failed", "compensation_failed"].includes(execution.status) || stalled)) {
      wrap.append(h("button", { type: "button", class: "btn", onclick: (event) => act("retry", event.currentTarget) },
        `Retry from ${execution.current_step}`));
    }
    if (canAct("compensate") && execution.status === "running") {
      const start = h("button", { type: "button", class: "btn btn-danger" }, "Compensate");
      start.addEventListener("click", () => {
        const confirm = h("div", { class: "x-confirm" },
          h("span", {}, "Undo the steps that already ran?"),
          h("button", { type: "button", class: "btn btn-danger", onclick: (event) => act("compensate", event.currentTarget) }, "Compensate now"),
          h("button", { type: "button", class: "btn btn-quiet", onclick: () => { confirm.replaceWith(start); start.focus(); } }, "Cancel"));
        start.replaceWith(confirm);
        confirm.querySelector("button").focus();
      });
      wrap.append(start);
    }
    return wrap;
  }

  function historyRow(frame, index) {
    const outcome = frameOutcome(frame);
    const classes = ["h-row", `is-${outcome}`];
    if (frame.rail === "back") classes.push("is-back");
    if (frame.kind === "end") classes.push("is-end");
    if (frame.rail === "back" && outcome === "back") classes.push("is-ok");
    const row = h("li", { class: classes.join(" ") },
      h("button", { type: "button", class: "h-at", "aria-label": `Move the replay to ${offset(frame.offset)}` }, offset(frame.offset)),
      h("span", { class: "h-mark", "aria-hidden": "true" }, h("i")),
      h("span", { class: "h-what" }, ...describe(frame, data.execution).map((part) => (typeof part === "string" && part.includes(": ") ? part.split(": ")[0] : part))),
      h("span", { class: "h-took" }, frame.attempt && frame.attempt.duration_ms !== null ? duration(frame.attempt.duration_ms) : ""));
    const error = frame.attempt && frame.attempt.error_message;
    if (error) {
      row.append(h("span", { class: "h-error" }, frame.attempt.error_class ? `${frame.attempt.error_class.split("::").pop()}: ` : "", error.replace(`${frame.attempt.step_name}: `, "")));
      if (frame.attempt.error_backtrace) {
        row.append(h("details", { class: "h-trace" }, h("summary", {}, "Backtrace"), h("pre", {}, String(frame.attempt.error_backtrace))));
      }
    }
    row.addEventListener("click", (event) => {
      if (event.target.closest("details")) return;
      setPlaying(false);
      seek(index);
    });
    return row;
  }

  function facts() {
    const { execution } = data;
    const rows = [
      ["Execution", [execution.id.slice(0, 8) + "…" + execution.id.slice(-4), copyButton(execution.id, "execution id")]],
      ["Status", h("span", { class: `state state-${execution.status}` }, statusLabel(execution.status))],
      ["Saga", h("a", { href: `#/executions?saga=${encodeURIComponent(execution.saga_name)}` }, execution.saga_name)],
      ["Partition", execution.partition],
      ["Correlation", execution.correlation_id ? [execution.correlation_id, copyButton(execution.correlation_id, "correlation id")] : "None"],
      ["Epoch", String(execution.epoch)],
      ["Resumed", plural(execution.resume_count || 0, "time")],
      ["Started", stamp(execution.started_at)],
      ["Finished", execution.finished_at ? stamp(execution.finished_at) : "Not yet"],
      ["Last progress", ago(execution.last_progress_at)]
    ];
    return h("dl", { class: "facts" }, rows.map(([term, value]) => [h("dt", {}, term), h("dd", {}, value)]));
  }

  function render() {
    const { execution, related } = data;
    clear(root);
    const definition = data.definition;
    frames = keyframes(data);

    const play = h("button", { type: "button", class: "scrub-play" });
    play.addEventListener("click", () => {
      if (!playing && u >= frames.length - 1.001) seek(0);
      setPlaying(!playing);
    });
    const range = h("input", { type: "range", min: 0, max: frames.length - 1, step: "any", value: 0, "aria-label": "Replay position" });
    range.addEventListener("input", () => { setPlaying(false); seek(Number(range.value), { fromInput: true }); });
    range.addEventListener("keydown", (event) => {
      if (["ArrowRight", "ArrowUp", "ArrowLeft", "ArrowDown"].includes(event.key)) {
        event.preventDefault();
        setPlaying(false);
        const dir = event.key === "ArrowRight" || event.key === "ArrowUp" ? 1 : -1;
        seek(dir > 0 ? Math.floor(u + 1e-6) + 1 : Math.ceil(u - 1e-6) - 1);
      }
    });
    const ticks = s("svg", { "aria-hidden": "true", preserveAspectRatio: "none" },
      s("line", { class: "tick-base", x1: "0", x2: "100%", y1: 14, y2: 14 }));
    frames.forEach((frame, index) => {
      const outcome = frameOutcome(frame);
      const pct = frames.length > 1 ? (index / (frames.length - 1)) * 100 : 0;
      ticks.append(s("rect", { class: `tick is-${outcome}`, x: `${pct}%`, y: outcome === "stop" ? 4 : 8, width: 3, height: outcome === "stop" ? 20 : 12, rx: 1, transform: "translate(-1.5 0)" }));
    });
    const now = h("div", { class: "scrub-now", "aria-live": "off" });
    const mapHost = h("div", { class: "map" });
    const history = h("ol", { class: "history", "aria-label": "Attempt history" });
    const rows = frames.map(historyRow);
    history.append(...rows);
    const ctx = h("div", {});

    root.append(
      h("p", { class: "crumbs" }, h("a", { href: "#/executions" }, "Executions"), " / ",
        h("a", { href: `#/executions?saga=${encodeURIComponent(execution.saga_name)}` }, execution.saga_name)),
      h("div", { class: "x-head" },
        h("h1", { class: "x-title", tabindex: "-1" }, `${execution.resource_type} `, h("b", {}, execution.resource_id)),
        actions()),
      h("p", { class: "x-story" }, ...story(data, frames, stallMs)),
      execution.failure_reason ? h("p", {}, h("span", { class: "x-reason" }, execution.failure_reason)) : null,
      h("section", { class: "replay", "aria-label": "Journey replay" },
        mapHost,
        h("div", { class: "scrub" }, play, h("div", { class: "scrub-track" }, h("div", { class: "scrub-ticks" }, ticks), range), now)),
      h("div", { class: "x-body" },
        h("section", { "aria-labelledby": "history-title" },
          h("h2", { class: "section-title", id: "history-title" }, "History"),
          h("p", { class: "section-note" }, "Every attempt in order, timed from the start. Select a time to move the replay there."),
          history),
        h("aside", {},
          h("h2", { class: "section-title" }, "Details"),
          facts(),
          h("div", { class: "ctx" },
            h("h2", { class: "section-title" }, "Context at this point"),
            h("p", { class: "section-note" }, "Keys a step added are highlighted."),
            ctx),
          related.length ? h("div", { class: "ctx" },
            h("h2", { class: "section-title" }, "Other runs for this resource"),
            h("ul", { class: "related" }, related.map((other) => h("li", {}, h("a", { href: `#/executions/${encodeURIComponent(other.id)}` },
              h("span", { class: `state state-${other.status}` }, statusLabel(other.status)), stamp(other.started_at)))))) : null))
    );

    els = { play, range, now, rows, ctx };
    map = new LineMap(mapHost, { mode: "single", label: `${execution.saga_name} line` });
    map.setLines([{ name: execution.saga_name, steps: definition.steps, decor: {} }]);
    setPlaying(false);
    if (reducedMotion.matches) {
      seek(frames.length - 1);
    } else {
      seek(0);
      setTimeout(() => { if (!destroyed && !playing && u === 0) setPlaying(true); }, 500);
    }
  }

  // A poll waits while the reader is in the middle of something the redraw
  // would throw away: a confirmation, the scrubber, the history or an open
  // backtrace.
  function interacting() {
    const active = document.activeElement;
    return Boolean(root.querySelector(".x-confirm, .h-trace[open]") ||
      (active && root.contains(active) && active.closest(".x-actions, .scrub, .history")));
  }

  let signature = "";
  async function load(force = false) {
    const next = await api.execution(id);
    if (destroyed) return;
    const sig = `${next.execution.status}|${next.attempts.length}|${next.execution.updated_at}`;
    if (!force && (sig === signature || (els && interacting()))) return;
    const atEnd = frames.length && u >= frames.length - 1.001;
    const hadFocus = force || root.contains(document.activeElement);
    signature = sig;
    data = next;
    if (!els) return render();
    const wasPlaying = playing;
    if (map) map.destroy();
    render();
    if (atEnd || wasPlaying) { setPlaying(false); seek(frames.length - 1); }
    if (hadFocus) root.querySelector(".x-title").focus();
  }

  const stop = every(pollMs, async () => {
    try {
      await load();
    } catch (error) {
      if (!data) clear(root).append(h("p", { class: "error" }, error.status === 404 ? "This execution no longer exists. It may have been pruned." : error.message));
    }
  });

  return {
    destroy() {
      destroyed = true;
      playing = false;
      cancelAnimationFrame(raf);
      stop();
      if (map) map.destroy();
    }
  };
}

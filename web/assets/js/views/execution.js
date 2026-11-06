import { h, replace, observeWidth, copyButton, keepFocus } from "../dom.js";
import { api } from "../api.js";
import { href } from "../router.js";
import { ago, duration, fullTime, json, shortId, shortTime, statusLabel } from "../format.js";
import { signal, empty, failure, sectionHead, liveDuration } from "../ui.js";
import { executionTrack } from "../charts/track.js";
import { gantt } from "../charts/gantt.js";

const RETRYABLE = ["failed", "compensation_failed", "running", "compensating"];
const TERMINAL = ["completed", "compensated", "failed", "compensation_failed"];

export function execution(root, { route, me, drawer, toast }) {
  const id = route.id;
  let data = null;
  let selected = null;
  let confirming = null;
  let submitting = false;
  let actionsKey = null;
  let snapshot = null;
  let trackWidth = 0;
  let ganttWidth = 0;

  const head = h("div", { class: "execution-head" });
  const actions = h("div", { class: "actions" });
  const reason = h("div", {});
  const trackFrame = h("div", { class: "panel track-panel" });
  const ganttFrame = h("div", { class: "gantt-frame", tabindex: 0, role: "region", "aria-label": "Attempt timeline, scrolls sideways" });
  const details = h("div", { class: "execution-details" });

  replace(root,
    h("nav", { class: "crumbs", "aria-label": "Breadcrumb" }, h("a", { href: href("/executions") }, "Executions"), h("span", { "aria-hidden": "true" }, " / "), h("span", {}, shortId(id))),
    head,
    reason,
    actions,
    h("section", { class: "section" }, sectionHead("Line"), trackFrame),
    h("section", { class: "section" }, sectionHead("Attempts"), h("div", { class: "panel" }, ganttFrame)),
    details);

  const stopTrack = observeWidth(trackFrame, (width) => {
    trackWidth = width;
    drawTrack();
  });
  const stopGantt = observeWidth(ganttFrame, (width) => {
    ganttWidth = width;
    drawGantt();
  });

  function openAttempt(attempt) {
    selected = attempt.id;
    drawer.open(`${attempt.step_name}, ${attempt.direction === "compensate" ? "compensation" : "attempt"} ${attempt.attempt}`, attemptDetail(attempt), () => {
      selected = null;
      drawGantt();
    });
    drawGantt();
  }

  function drawTrack() {
    if (!data || !trackWidth) return;
    keepFocus(trackFrame, () => replace(trackFrame, executionTrack({
      steps: data.definition.steps,
      attempts: data.attempts,
      execution: data.execution,
      width: trackWidth,
      onAttempt: openAttempt
    }) || empty("No steps known for this saga.")));
  }

  function drawGantt() {
    if (!data || !ganttWidth) return;
    const chart = gantt({ attempts: data.attempts, execution: data.execution, width: ganttWidth, onAttempt: openAttempt, selectedId: selected });
    keepFocus(ganttFrame, () => replace(ganttFrame, chart || empty("No attempts yet.", "The first step has not been picked up by a worker.")));
  }

  function drawHead() {
    const execution = data.execution;
    replace(head,
      h("div", { class: "execution-title" },
        h("h1", {}, execution.saga_name),
        signal(execution.status)),
      h("p", { class: "execution-resource" },
        h("span", { class: "muted" }, execution.resource_type), " ", execution.resource_id,
        copyButton(execution.resource_id, "Copy resource id")),
      h("dl", { class: "facts" },
        fact("Execution", h("span", { class: "id" }, shortId(execution.id), copyButton(execution.id, "Copy execution id"))),
        fact("Current step", execution.current_step ? `${execution.direction === "compensate" ? "↩ " : ""}${execution.current_step}` : "None"),
        fact("Epoch", h("span", { class: "num" }, String(execution.epoch))),
        fact("Partition", execution.partition || "None"),
        fact("Correlation id", execution.correlation_id ? h("span", { class: "id" }, shortId(execution.correlation_id), copyButton(execution.correlation_id, "Copy correlation id")) : "None"),
        fact("Started", h("time", { datetime: execution.started_at, title: fullTime(execution.started_at) }, shortTime(execution.started_at))),
        fact(execution.finished_at ? "Took" : "Running for", liveDuration(execution)),
        fact("Last progress", h("time", { datetime: execution.last_progress_at, title: fullTime(execution.last_progress_at) }, ago(execution.last_progress_at))),
        execution.resume_count ? fact("Resumes", h("span", { class: "num" }, String(execution.resume_count))) : null));
    replace(reason, execution.failure_reason
      ? h("div", { class: ["notice", execution.status === "compensated" || execution.status === "compensating" ? "notice-reverse" : "notice-stop"] },
        h("strong", {}, execution.status === "compensated" || execution.status === "compensating" ? "Compensation reason" : "Failure reason"),
        h("span", {}, execution.failure_reason))
      : null);
  }

  function drawActions() {
    if (submitting) return;
    const execution = data.execution;
    const known = data.definition.known;
    const canRetry = known && me.actions.retry && RETRYABLE.includes(execution.status);
    const canCompensate = known && me.actions.compensate && !TERMINAL.includes(execution.status);
    if ((confirming === "retry" && !canRetry) || (confirming === "compensate" && !canCompensate)) confirming = null;
    const key = JSON.stringify([canRetry, canCompensate, confirming, execution.id, execution.current_step, execution.epoch]);
    if (key === actionsKey) return;
    actionsKey = key;
    if (confirming) {
      replace(actions, confirmPanel(confirming, execution));
      return;
    }
    keepFocus(actions, () => replace(actions,
      canRetry ? h("button", { type: "button", class: "button button-primary", dataset: { key: "retry" }, onclick: () => confirm("retry") }, `Retry${fromStep(execution)}`) : null,
      canCompensate ? h("button", { type: "button", class: "button button-reverse", dataset: { key: "compensate" }, onclick: () => confirm("compensate") }, "Compensate") : null));
  }

  function confirm(kind) {
    confirming = kind;
    drawActions();
    actions.querySelector("input, button.button-confirm")?.focus();
  }

  function cancel() {
    confirming = null;
    drawActions();
    actions.querySelector("button")?.focus();
  }

  function confirmPanel(kind, execution) {
    const reasonInput = h("input", { type: "text", class: "input", placeholder: "Reason (optional)", "aria-label": "Compensation reason", maxlength: 500 });
    const run = async (button) => {
      submitting = true;
      button.disabled = true;
      try {
        if (kind === "retry") await api.retry(execution.id);
        else await api.compensate(execution.id, reasonInput.value);
      } catch (error) {
        submitting = false;
        button.disabled = false;
        toast(error.message, "stop");
        return;
      }
      submitting = false;
      confirming = null;
      snapshot = null;
      toast(kind === "retry" ? `Retrying${fromStep(execution)}` : "Compensation started");
      refresh().catch(() => null);
    };
    const text = kind === "retry"
      ? `Retry${fromStep(execution)}? This moves the execution to epoch ${execution.epoch + 1} and publishes the step again; messages from earlier epochs are ignored.`
      : `Compensate this execution? Completed steps are undone in reverse order, starting from the nearest step that declares a compensation.`;
    return h("div", { class: ["confirm", kind === "retry" ? "confirm-proceed" : "confirm-reverse"], role: "group", "aria-label": "Confirm action" },
      h("p", {}, text),
      kind === "compensate" ? reasonInput : null,
      h("div", { class: "confirm-buttons" },
        h("button", { type: "button", class: ["button", "button-confirm", kind === "retry" ? "button-primary" : "button-reverse"], onclick: (event) => run(event.currentTarget) }, kind === "retry" ? "Confirm retry" : "Confirm compensation"),
        h("button", { type: "button", class: "button button-quiet", onclick: cancel }, "Cancel")));
  }

  function drawDetails() {
    const related = data.related;
    replace(details,
      h("section", { class: "section" },
        sectionHead("Context"),
        h("pre", { class: "code panel" }, json(data.execution.context))),
      h("section", { class: "section" },
        sectionHead("Other runs for this resource"),
        related.length
          ? h("table", { class: "table compact" },
            h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "Status"), h("th", { scope: "col" }, "Saga"), h("th", { scope: "col" }, "Started"), h("th", { scope: "col", class: "num" }, "Duration"))),
            h("tbody", {}, related.map((run) => h("tr", {},
              h("td", {}, signal(run.status)),
              h("td", {}, h("a", { href: href(`/executions/${encodeURIComponent(run.id)}`), dataset: { key: `run:${run.id}` } }, run.saga_name)),
              h("td", {}, shortTime(run.started_at)),
              h("td", { class: "num" }, liveDuration(run))))))
          : h("p", { class: "muted" }, "None.")));
  }

  async function refresh() {
    try {
      data = await api.execution(id);
    } catch (error) {
      snapshot = null;
      replace(head, failure(error));
      throw error;
    }
    const next = JSON.stringify(data);
    if (next === snapshot) {
      drawGantt();
      return;
    }
    snapshot = next;
    keepFocus(head, drawHead);
    drawActions();
    drawTrack();
    drawGantt();
    keepFocus(details, drawDetails);
    if (selected) {
      const attempt = data.attempts.find((item) => item.id === selected);
      if (attempt) drawer.update(attemptDetail(attempt));
    }
  }

  return {
    refresh,
    destroy() {
      stopTrack();
      stopGantt();
      drawer.close();
    }
  };
}

function fromStep(execution) {
  return execution.current_step ? ` from ${execution.current_step}` : "";
}

function fact(label, value) {
  return h("div", { class: "fact" }, h("dt", {}, label), h("dd", {}, value));
}

function attemptDetail(attempt) {
  const reverse = attempt.direction === "compensate";
  return h("div", { class: "attempt" },
    h("p", {}, signal(attempt.status === "succeeded" && reverse ? "compensated" : attempt.status, statusLabel(attempt.status))),
    h("dl", { class: "facts facts-stacked" },
      fact("Direction", reverse ? "Compensation" : "Execute"),
      fact("Epoch", h("span", { class: "num" }, String(attempt.epoch))),
      fact("Started", h("time", { datetime: attempt.started_at }, fullTime(attempt.started_at))),
      fact("Duration", attempt.finished_at ? duration(attempt.duration_ms) : "Still running"),
      fact("Attempt id", h("span", { class: "id" }, shortId(attempt.id), copyButton(attempt.id, "Copy attempt id")))),
    attempt.error_class ? h("section", { class: "attempt-error" },
      h("h3", {}, attempt.error_class),
      h("p", { class: "error-message" }, attempt.error_message || ""),
      attempt.error_backtrace ? h("details", { open: true }, h("summary", {}, "Backtrace"), h("pre", { class: "code" }, attempt.error_backtrace)) : null) : null,
    h("section", {},
      h("h3", {}, "Context after"),
      h("pre", { class: "code" }, json(attempt.context_after))));
}

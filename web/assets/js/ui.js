import { h, s } from "./dom.js";
import { statusLabel, tone, duration, elapsed } from "./format.js";

const SHAPES = {
  running: "ring",
  compensating: "ring",
  completed: "dot",
  compensated: "dot",
  succeeded: "dot",
  failed: "square",
  compensation_failed: "square-ring",
  skipped: "dash",
  stalled: "triangle"
};

function lampGlyph(status) {
  const shape = SHAPES[status] || "dot";
  const svg = s("svg", { viewBox: "0 0 12 12", width: 12, height: 12, class: ["signal-lamp", `tone-${tone(status)}`, `shape-${shape}`], "aria-hidden": "true" });
  if (shape === "square" || shape === "square-ring") svg.append(s("rect", { x: 1.5, y: 1.5, width: 9, height: 9, rx: 1.5 }));
  else if (shape === "triangle") svg.append(s("path", { d: "M6 1.5 L11 10.5 H1 Z" }));
  else if (shape === "dash") svg.append(s("rect", { x: 1, y: 4.5, width: 10, height: 3, rx: 1.5 }));
  else svg.append(s("circle", { cx: 6, cy: 6, r: shape === "ring" ? 4 : 4.75 }));
  return svg;
}

export function signal(status, text = statusLabel(status)) {
  return h("span", { class: ["signal", `tone-${tone(status)}`] }, lampGlyph(status), h("span", {}, text));
}

export function segmented({ label, options, value, onChange, compact = false }) {
  const group = h("div", { class: ["segmented", compact ? "segmented-compact" : null], role: "radiogroup", "aria-label": label });
  const buttons = options.map((option) => {
    const button = h("button", {
      type: "button",
      role: "radio",
      "aria-checked": String(option.value === value),
      "aria-label": option.ariaLabel || null,
      title: option.ariaLabel || null,
      dataset: { value: option.value }
    }, option.icon || null, h("span", { class: option.icon ? "segmented-text" : null }, option.label));
    button.addEventListener("click", () => select(option.value, true));
    return button;
  });
  function select(next, notify) {
    buttons.forEach((button) => button.setAttribute("aria-checked", String(button.dataset.value === String(next))));
    if (notify) onChange(next);
  }
  group.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
    const index = buttons.indexOf(document.activeElement);
    if (index < 0) return;
    const next = buttons[(index + (event.key === "ArrowRight" ? 1 : buttons.length - 1)) % buttons.length];
    next.focus();
    next.click();
  });
  group.append(...buttons);
  group.select = (next) => select(next, false);
  return group;
}

export function select({ label, options, value, onChange, className }) {
  const node = h("select", { class: className || null, "aria-label": label },
    options.map((option) => h("option", { value: option.value, selected: String(option.value) === String(value ?? "") ? true : null }, option.label)));
  node.addEventListener("change", () => onChange(node.value));
  return node;
}

export function dataTable({ caption, columns, rows }) {
  return h("details", { class: "data-table" },
    h("summary", {}, "Show as table"),
    h("table", { class: "table compact" },
      h("caption", { class: "visually-hidden" }, caption),
      h("thead", {}, h("tr", {}, columns.map((column) => h("th", { scope: "col", class: column.num ? "num" : null }, column.label)))),
      h("tbody", {}, rows.map((row) => h("tr", {}, row.map((cell, index) => h("td", { class: columns[index].num ? "num" : null }, cell)))))));
}

export function empty(text, hint) {
  return h("div", { class: "empty" }, h("p", {}, text), hint ? h("p", { class: "muted" }, hint) : null);
}

export function failure(error) {
  return h("div", { class: "notice notice-stop", role: "alert" },
    h("strong", {}, error.status === 403 ? "Not allowed" : error.status === 501 ? "Not supported by this store" : "Could not load"),
    h("span", {}, error.message));
}

export function heading(title, ...controls) {
  return h("div", { class: "view-head" }, h("h1", {}, title), h("div", { class: "view-controls" }, controls));
}

export function sectionHead(title, ...extra) {
  return h("div", { class: "section-head" }, h("h2", {}, title), extra);
}

export function liveDuration(execution) {
  if (execution.finished_at || !["running", "compensating"].includes(execution.status)) {
    return h("span", { class: "num" }, duration(elapsed(execution.started_at || execution.created_at, execution.finished_at)));
  }
  return h("span", { class: "num", dataset: { since: execution.started_at || execution.created_at } }, duration(elapsed(execution.started_at || execution.created_at)));
}

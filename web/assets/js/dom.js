const SVG_NS = "http://www.w3.org/2000/svg";

function apply(el, attrs) {
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "text") el.textContent = value;
    else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value);
    else el.setAttribute(key, value === true ? "" : String(value));
  }
}

export function append(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  apply(el, attrs);
  return append(el, children);
}

export function s(tag, attrs, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  apply(el, attrs);
  return append(el, children);
}

export function clear(el) {
  while (el.firstChild) el.firstChild.remove();
  return el;
}

const FOCUSABLE = "a[href], button, input, select, summary, [tabindex]";
const focusKey = (el) => el.getAttribute("href") || `${el.tagName}|${el.textContent}`;

// Replaces el's children for a poll without disturbing assistive technology:
// unchanged content is left alone, and focus inside el moves to the matching
// control of the new content (the same link target, or tag and text).
export function refill(el, ...children) {
  const next = append(document.createDocumentFragment(), children);
  const same = next.childNodes.length === el.childNodes.length &&
    [...next.childNodes].every((node, index) => node.isEqualNode(el.childNodes[index]));
  if (same) return el;
  const active = document.activeElement;
  const key = active && active !== el && el.contains(active) ? focusKey(active) : null;
  clear(el).append(next);
  if (key) [...el.querySelectorAll(FOCUSABLE)].find((node) => focusKey(node) === key)?.focus({ preventScroll: true });
  return el;
}

let toastTimer;
export function toast(message, { error = false } = {}) {
  const el = document.getElementById("toast");
  el.textContent = message;
  el.classList.toggle("is-error", error);
  el.classList.add("is-shown");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("is-shown"), 3600);
}

export const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

export function copyButton(value, label) {
  return h("button", {
    type: "button",
    class: "copy",
    "aria-label": `Copy ${label}`,
    title: `Copy ${label}`,
    onclick: async () => {
      try {
        await navigator.clipboard.writeText(value);
        toast(`Copied ${label}`);
      } catch {
        toast("The browser blocked the clipboard", { error: true });
      }
    }
  }, s("svg", { viewBox: "0 0 16 16", width: 14, height: 14, "aria-hidden": "true" },
    s("rect", { x: 5.5, y: 5.5, width: 8, height: 8, rx: 1.5 }),
    s("path", { d: "M10.5 3.5v-.5a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h.5" })));
}

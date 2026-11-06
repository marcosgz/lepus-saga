const SVG_NS = "http://www.w3.org/2000/svg";

function apply(el, attrs) {
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "text") el.textContent = value;
    else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value);
    else el.setAttribute(key, value === true ? "" : String(value));
  }
}

function append(el, children) {
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

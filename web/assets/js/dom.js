const SVG_NS = "http://www.w3.org/2000/svg";

function assign(node, attrs) {
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "class") node.setAttribute("class", Array.isArray(value) ? value.filter(Boolean).join(" ") : value);
    else if (key === "dataset") Object.assign(node.dataset, value);
    else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2), value);
    else if (key === "text") node.textContent = value;
    else node.setAttribute(key, value === true ? "" : String(value));
  }
}

function append(node, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export function h(tag, attrs, ...children) {
  const node = document.createElement(tag);
  assign(node, attrs);
  return append(node, children);
}

export function s(tag, attrs, ...children) {
  const node = document.createElementNS(SVG_NS, tag);
  assign(node, attrs);
  return append(node, children);
}

export function clear(node) {
  while (node.firstChild) node.firstChild.remove();
  return node;
}

export function replace(node, ...children) {
  return append(clear(node), children);
}

export function focusKey(node) {
  return node?.dataset?.key || null;
}

export function findKey(root, key) {
  return key ? root.querySelector(`[data-key="${CSS.escape(key)}"]`) : null;
}

export function keepFocus(root, draw) {
  const active = document.activeElement;
  const key = root.contains(active) ? focusKey(active) : null;
  draw();
  if (key && !active.isConnected) findKey(root, key)?.focus({ preventScroll: true });
}

export function svgSize(width, height, attrs = {}) {
  return s("svg", { viewBox: `0 0 ${width} ${height}`, width, height, ...attrs });
}

function contentWidth(node) {
  const style = getComputedStyle(node);
  return Math.floor(node.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight));
}

export function observeWidth(node, callback) {
  let width = node.isConnected ? contentWidth(node) : 0;
  let timer = 0;
  if (width > 0) callback(width);
  const observer = new ResizeObserver((entries) => {
    const next = Math.floor(entries[0].contentRect.width);
    if (next <= 0 || Math.abs(next - width) < 4) return;
    width = next;
    clearTimeout(timer);
    timer = setTimeout(() => callback(width));
  });
  observer.observe(node);
  return () => {
    clearTimeout(timer);
    observer.disconnect();
  };
}

let tip;

export function showTip(event, lines) {
  if (!tip) {
    tip = h("div", { class: "tip", role: "tooltip" });
    document.body.append(tip);
  }
  replace(tip, lines.map(([label, value, tone]) =>
    h("div", { class: "tip-row" },
      tone ? h("span", { class: ["tip-key", `tone-${tone}`] }) : null,
      h("span", { class: "tip-label" }, label),
      value === undefined ? null : h("span", { class: "tip-value" }, value))));
  tip.hidden = false;
  const box = tip.getBoundingClientRect();
  const x = Math.min(event.clientX + 14, window.innerWidth - box.width - 8);
  const y = event.clientY + 16 + box.height > window.innerHeight ? event.clientY - box.height - 12 : event.clientY + 16;
  tip.style.left = `${Math.max(8, x)}px`;
  tip.style.top = `${Math.max(8, y)}px`;
}

export function hideTip() {
  if (tip) tip.hidden = true;
}

export function copyButton(value, label = "Copy") {
  const button = h("button", { type: "button", class: "copy", title: `${label}: ${value}`, "aria-label": `${label} ${value}`, dataset: { key: `copy:${label}` } }, copyIcon());
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(value);
      button.classList.add("copied");
      setTimeout(() => button.classList.remove("copied"), 1200);
    } catch {
      window.prompt("Copy", value);
    }
  });
  return button;
}

function copyIcon() {
  return s("svg", { viewBox: "0 0 16 16", width: 14, height: 14, "aria-hidden": "true", class: "icon" },
    s("rect", { x: 5, y: 5, width: 8, height: 9, rx: 1.5 }),
    s("path", { d: "M3 10.5V3.5A1.5 1.5 0 0 1 4.5 2H10" }));
}

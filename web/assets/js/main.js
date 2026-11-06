import { h, s, replace, focusKey, findKey } from "./dom.js";
import { api } from "./api.js";
import { parse, onChange } from "./router.js";
import { Poller } from "./poller.js";
import { clock, duration, elapsed } from "./format.js";
import { segmented, select, failure, empty } from "./ui.js";
import { overview } from "./views/overview.js";
import { executions } from "./views/executions.js";
import { execution } from "./views/execution.js";
import { insights } from "./views/insights.js";

const VIEWS = { overview, executions, execution, insights };
const NAV_FOR = { overview: "overview", executions: "executions", execution: "executions", insights: "insights" };
const THEME_KEY = "lepus-saga:theme";

const main = document.getElementById("view");
const live = document.getElementById("live");
const header = document.querySelector(".topbar");
let current = null;
let booted = false;
let me = null;
let poller = null;

function readTheme() {
  try {
    return window.localStorage.getItem(THEME_KEY) || "auto";
  } catch {
    return "auto";
  }
}

function saveTheme(theme) {
  try {
    if (theme === "auto") window.localStorage.removeItem(THEME_KEY);
    else window.localStorage.setItem(THEME_KEY, theme);
    return true;
  } catch {
    return false;
  }
}

function applyTheme(theme) {
  if (theme === "auto") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", theme);
  saveTheme(theme);
}

function icon(paths) {
  return s("svg", { viewBox: "0 0 16 16", width: 16, height: 16, class: "icon", "aria-hidden": "true" }, paths);
}

function themeControl() {
  return segmented({
    label: "Theme",
    compact: true,
    value: readTheme(),
    onChange: applyTheme,
    options: [
      { value: "auto", label: "Auto", ariaLabel: "Auto theme, follows the system", icon: icon([s("circle", { cx: 8, cy: 8, r: 5.5 }), s("path", { d: "M8 2.5 A5.5 5.5 0 0 1 8 13.5 Z", class: "icon-fill" })]) },
      { value: "light", label: "Light", ariaLabel: "Light theme", icon: icon([s("circle", { cx: 8, cy: 8, r: 3 }), s("path", { d: "M8 1v2M8 13v2M1 8h2M13 8h2M3 3l1.4 1.4M11.6 11.6L13 13M3 13l1.4-1.4M11.6 4.4L13 3" })]) },
      { value: "dark", label: "Dark", ariaLabel: "Dark theme", icon: icon(s("path", { d: "M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5Z" })) }
    ]
  });
}

function pollControl() {
  return select({
    label: "Refresh interval",
    className: "poll-select",
    value: String(poller.interval),
    options: me.poll_intervals.map((seconds) => ({ value: String(seconds), label: seconds ? `Every ${seconds} s` : "Refresh off" })),
    onChange: (value) => poller.setInterval(Number(value))
  });
}

const POLL_LABELS = { live: "Live", paused: "Paused", off: "Off", error: "Retrying" };

function pollState(state, lastRun) {
  live.title = lastRun ? `Updated ${clock(lastRun)}` : POLL_LABELS[state];
  if (live.dataset.state === state) return;
  live.dataset.state = state;
  replace(live, h("span", { class: "live-dot", "aria-hidden": "true" }), h("span", { class: "live-text" }, POLL_LABELS[state]));
}

const drawer = (() => {
  const panel = document.getElementById("drawer");
  const title = document.getElementById("drawer-title");
  const body = document.getElementById("drawer-body");
  const sheet = window.matchMedia("(max-width: 1099px)");
  let onClose = null;
  let opener = null;
  let openerKey = null;

  function syncModal() {
    const modal = sheet.matches && !panel.hidden;
    if (modal) {
      panel.setAttribute("role", "dialog");
      panel.setAttribute("aria-modal", "true");
    } else {
      panel.removeAttribute("role");
      panel.removeAttribute("aria-modal");
    }
    main.inert = modal;
    header.inert = modal;
  }

  function close() {
    if (panel.hidden) return;
    panel.hidden = true;
    document.body.classList.remove("drawer-open");
    syncModal();
    const callback = onClose;
    onClose = null;
    callback?.();
    (opener?.isConnected ? opener : findKey(main, openerKey))?.focus?.();
  }

  document.getElementById("drawer-close").addEventListener("click", close);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !panel.hidden) close();
  });
  sheet.addEventListener("change", syncModal);

  return {
    open(text, content, callback) {
      if (panel.hidden) {
        opener = document.activeElement;
        openerKey = focusKey(opener);
      }
      onClose = callback;
      title.textContent = text;
      replace(body, content);
      panel.hidden = false;
      document.body.classList.add("drawer-open");
      syncModal();
      panel.focus();
    },
    update(content) {
      if (!panel.hidden) replace(body, content);
    },
    close
  };
})();

function toast(message, tone = "proceed") {
  const region = document.getElementById("toast");
  const item = h("div", { class: ["toast-item", `toast-${tone}`] }, message);
  region.append(item);
  setTimeout(() => item.remove(), 5000);
}

function navigate(link) {
  if (window.location.hash === link) render(parse(link));
  else window.location.hash = link;
}

function render(route) {
  current?.destroy?.();
  current = null;
  document.querySelectorAll("[data-nav]").forEach((link) => {
    if (link.dataset.nav === NAV_FOR[route.name]) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
  const view = VIEWS[route.name];
  if (!view) {
    replace(main, empty("There is nothing at this address.", "Pick a view from the top bar."));
    poller.watch(null);
    return;
  }
  current = view(main, { route, me, drawer, toast, navigate });
  if (booted) main.focus();
  booted = true;
  poller.watch(current.refresh);
  poller.runNow();
}

function tick() {
  for (const node of document.querySelectorAll("[data-since]")) {
    node.textContent = duration(elapsed(node.dataset.since));
  }
}

async function boot() {
  try {
    me = await api.me();
  } catch (error) {
    replace(main, failure(error));
    return;
  }
  document.title = me.title;
  document.getElementById("brand-title").textContent = me.title;
  if (!me.queries) {
    replace(main, failure({ status: 501, message: "This saga store does not implement the query methods the console reads through." }));
    return;
  }
  poller = new Poller({ intervals: me.poll_intervals, fallback: me.poll_interval, onState: pollState });
  replace(document.getElementById("controls"), live, pollControl(), themeControl());
  pollState(poller.state(), null);
  onChange(render);
  render(parse());
  setInterval(tick, 1000);
}

boot();

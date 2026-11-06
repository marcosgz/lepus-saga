const ROUTES = [
  { name: "overview", pattern: /^\/?$/ },
  { name: "executions", pattern: /^\/executions\/?$/ },
  { name: "execution", pattern: /^\/executions\/([^/]+)$/ },
  { name: "insights", pattern: /^\/insights\/?$/ }
];

export function parse(hash = window.location.hash) {
  const raw = hash.replace(/^#/, "") || "/";
  const [path, search = ""] = raw.split("?");
  const query = Object.fromEntries(new URLSearchParams(search));
  for (const route of ROUTES) {
    const match = path.match(route.pattern);
    if (match) return { name: route.name, id: match[1] ? decodeURIComponent(match[1]) : null, query };
  }
  return { name: "missing", query };
}

export function href(path, query = {}) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === null || value === undefined || value === "" || (Array.isArray(value) && !value.length)) continue;
    params.set(key, Array.isArray(value) ? value.join(",") : value);
  }
  const search = params.toString();
  return `#${path}${search ? `?${search}` : ""}`;
}

export function replaceQuery(path, query) {
  const next = href(path, query);
  if (next !== window.location.hash) history.replaceState(null, "", next);
}

export function onChange(callback) {
  window.addEventListener("hashchange", () => callback(parse()));
}

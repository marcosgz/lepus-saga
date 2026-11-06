export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function url(path, params = {}) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === null || value === undefined || value === "") continue;
    query.set(key, Array.isArray(value) ? value.join(",") : value);
  }
  const search = query.toString();
  return `api/${path}${search ? `?${search}` : ""}`;
}

async function request(path, options = {}) {
  let response;
  try {
    response = await fetch(path, { credentials: "same-origin", headers: { Accept: "application/json" }, ...options });
  } catch {
    throw new ApiError(0, "The console could not reach the server");
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new ApiError(response.status, data.error || `Request failed (${response.status})`);
  return data;
}

function post(path, body = {}) {
  return request(url(path), {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json", "X-Lepus-Saga": "1" },
    body: JSON.stringify(body)
  });
}

export const api = {
  me: () => request(url("me")),
  sagas: (params) => request(url("sagas", params)),
  executions: (params) => request(url("executions", params)),
  execution: (id) => request(url(`executions/${encodeURIComponent(id)}`)),
  series: (params) => request(url("series", params)),
  failures: (params) => request(url("insights/failures", params)),
  latency: (params) => request(url("insights/latency", params)),
  stalled: (params) => request(url("stalled", params)),
  retry: (id) => post(`executions/${encodeURIComponent(id)}/retry`),
  compensate: (id, reason) => post(`executions/${encodeURIComponent(id)}/compensate`, { reason })
};

import { api } from "./api.js";

let cache = null;
let fetchedAt = 0;

// Saga definitions change only on deploy; the list keeps them for a minute.
export async function sagaDefinitions() {
  if (cache && Date.now() - fetchedAt < 60_000) return cache;
  const data = await api.sagas();
  cache = new Map(data.sagas.map((saga) => [saga.name, saga]));
  fetchedAt = Date.now();
  return cache;
}

export function rememberSagas(sagas) {
  cache = new Map(sagas.map((saga) => [saga.name, saga]));
  fetchedAt = Date.now();
}

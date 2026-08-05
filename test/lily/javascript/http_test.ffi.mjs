export function eventSourceReadyState(es) {
  if (es === null || es === undefined) return -1;
  return es.readyState;
}

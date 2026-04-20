export function eventSourceReadyState(es) {
  if (es === null || es === undefined) return -1;
  return es.readyState;
}

export function getFlushBatchSize(config) {
  return config.flush_batch_size;
}

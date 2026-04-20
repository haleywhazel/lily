export function isNull(value) {
  return value === null || value === undefined;
}

export function getJitterRatio(config) {
  return config.reconnect_jitter_ratio;
}

export function getMultiplier(config) {
  return config.reconnect_multiplier;
}

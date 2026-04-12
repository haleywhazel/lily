export function writeLocalStorage(key, value) {
  localStorage.setItem(key, value);
}

export function readLocalStorage(key) {
  return localStorage.getItem(key) ?? "";
}

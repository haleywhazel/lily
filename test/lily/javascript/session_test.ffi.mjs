export function writeLocalStorage(key, value) {
  localStorage.setItem(key, value);
}

export function readLocalStorage(key) {
  return localStorage.getItem(key) ?? "";
}

export function writeSessionStorage(key, value) {
  sessionStorage.setItem(key, value);
}

export function readSessionStorage(key) {
  return sessionStorage.getItem(key) ?? "";
}

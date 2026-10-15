// mirrors docs/recipes/sse-transport.md, keep identical

export function open_source(url, received, opened, closed) {
  const source = new EventSource(url);
  source.client_id = "";
  source.onmessage = (event) => {
    if (source.client_id === "" && event.lastEventId) {
      source.client_id = event.lastEventId;
      opened();
    }
    received(event.data);
  };
  source.onerror = () => {
    if (source.client_id !== "") {
      source.client_id = "";
      closed();
    }
  };
  return source;
}

export function source_client_id(source) {
  return source.client_id;
}

export function close_source(source) {
  source.close();
}

export function post_text(url, body) {
  fetch(url, {
    method: "POST",
    headers: { "content-type": "text/plain" },
    body,
  }).catch(() => {});
}

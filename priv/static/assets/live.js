// Connects the LiveViews of the admin console and of /me. Each has its own socket, under its
// own path (so it gets that area's session cookie), named in the page's live-socket-path meta
// tag. phoenix.min.js and phoenix_live_view.min.js are served from the dependencies and define
// the `Phoenix` and `LiveView` globals.
(function () {
  const meta = (name) => document.querySelector(`meta[name='${name}']`).getAttribute("content");
  const liveSocket = new LiveView.LiveSocket(meta("live-socket-path"), Phoenix.Socket, {
    params: { _csrf_token: meta("csrf-token") },
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();

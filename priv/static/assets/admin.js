// Connects the admin console's LiveViews. phoenix.min.js and phoenix_live_view.min.js are
// served from the dependencies and define the `Phoenix` and `LiveView` globals.
(function () {
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  const liveSocket = new LiveView.LiveSocket("/admin/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();

// Connects the LiveViews of the admin console and of /me. Each has its own socket, under its
// own path (so it gets that area's session cookie), named in the page's live-socket-path meta
// tag. phoenix.min.js and phoenix_live_view.min.js are served from the dependencies and define
// the `Phoenix` and `LiveView` globals.
(function () {
  const meta = (name) => document.querySelector(`meta[name='${name}']`).getAttribute("content");

  const hooks = {
    // The extension script editor (a textarea): Tab indents, Ctrl/Cmd+S saves. Escape, then
    // Tab, moves on to the next field as usual, so the editor isn't a keyboard trap.
    CodeEditor: {
      mounted() {
        let escaped = false;

        this.el.addEventListener("keydown", (event) => {
          if ((event.ctrlKey || event.metaKey) && event.key === "s") {
            event.preventDefault();
            this.el.form.requestSubmit();
          } else if (event.key === "Escape") {
            escaped = true;
          } else if (event.key === "Tab" && !escaped && !event.shiftKey) {
            event.preventDefault();
            const { selectionStart: start, selectionEnd: end, value } = this.el;
            this.el.value = value.slice(0, start) + "  " + value.slice(end);
            this.el.selectionStart = this.el.selectionEnd = start + 2;
            this.el.dispatchEvent(new Event("input", { bubbles: true }));
          } else {
            escaped = false;
          }
        });
      },
    },
  };

  const liveSocket = new LiveView.LiveSocket(meta("live-socket-path"), Phoenix.Socket, {
    params: { _csrf_token: meta("csrf-token") },
    hooks,
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();

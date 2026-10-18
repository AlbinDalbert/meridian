// Connects the LiveViews of the admin console and of /me. Each has its own socket, under its
// own path (so it gets that area's session cookie), named in the page's live-socket-path meta
// tag. phoenix.min.js and phoenix_live_view.min.js are served from the dependencies and define
// the `Phoenix` and `LiveView` globals.
(function () {
  const meta = (name) => document.querySelector(`meta[name='${name}']`).getAttribute("content");

  // Lua syntax highlighting, from lua.js (also used by the docs pages).
  const highlight = window.highlightLua;

  const hooks = {
    // The extension script editor (a textarea over a highlighted copy of its text): Tab
    // indents, Ctrl/Cmd+S saves. Escape, then Tab, moves on to the next field as usual, so the
    // editor isn't a keyboard trap.
    CodeEditor: {
      mounted() {
        let escaped = false;
        this.highlight = document.getElementById(this.el.dataset.highlight);
        this.render();
        this.el.addEventListener("input", () => this.render());
        this.el.addEventListener("scroll", () => this.sync());

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
      // The server changed the text (e.g. an imported script).
      updated() {
        this.render();
      },
      render() {
        // A trailing newline keeps the copy as tall as the text when it ends in an empty line.
        this.highlight.innerHTML = highlight(this.el.value) + "\n";
        this.sync();
      },
      sync() {
        this.highlight.scrollTop = this.el.scrollTop;
        this.highlight.scrollLeft = this.el.scrollLeft;
      },
    },

    // A read-only script.
    CodeView: {
      mounted() {
        this.el.innerHTML = highlight(this.el.textContent);
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

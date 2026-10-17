// Connects the LiveViews of the admin console and of /me. Each has its own socket, under its
// own path (so it gets that area's session cookie), named in the page's live-socket-path meta
// tag. phoenix.min.js and phoenix_live_view.min.js are served from the dependencies and define
// the `Phoenix` and `LiveView` globals.
(function () {
  const meta = (name) => document.querySelector(`meta[name='${name}']`).getAttribute("content");

  // Lua syntax highlighting: the text as HTML, with tokens in spans (`hl-keyword`, ...).
  const KEYWORDS = new Set(("and break do else elseif end for function goto if in local not or " +
    "repeat return then until while").split(" "));
  const LITERALS = new Set(["true", "false", "nil"]);
  const BUILTINS = new Set(("meridian assert error ipairs next pairs pcall print rawequal rawget " +
    "rawlen rawset select setmetatable getmetatable tonumber tostring type xpcall math string " +
    "table utf8 coroutine").split(" "));
  // Long comments, line comments, long strings, quoted strings, numbers, names. Unterminated
  // ones run to the end, as Lua would read them.
  const TOKEN = new RegExp([
    /(--\[(=*)\[[\s\S]*?(?:\]\2\]|$))/.source,
    /(--[^\n]*)/.source,
    /(\[(=*)\[[\s\S]*?(?:\]\5\]|$))/.source,
    /("(?:[^"\\\n]|\\[\s\S])*"?|'(?:[^'\\\n]|\\[\s\S])*'?)/.source,
    /(\b0[xX][0-9a-fA-F.]+(?:[pP][+-]?\d+)?|(?:\b\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/.source,
    /([A-Za-z_][A-Za-z0-9_]*)/.source,
  ].join("|"), "g");

  const escape = (text) =>
    text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  const span = (kind, text) => `<span class="hl-${kind}">${escape(text)}</span>`;

  const highlight = (source) => {
    let html = "";
    let last = 0;
    TOKEN.lastIndex = 0;

    for (let m; (m = TOKEN.exec(source)); ) {
      html += escape(source.slice(last, m.index));
      const [text] = m;

      if (m[1] || m[3]) html += span("comment", text);
      else if (m[4] || m[6]) html += span("string", text);
      else if (m[7]) html += span("number", text);
      else if (KEYWORDS.has(text)) html += span("keyword", text);
      else if (LITERALS.has(text)) html += span("literal", text);
      else if (BUILTINS.has(text)) html += span("builtin", text);
      else html += escape(text);

      last = TOKEN.lastIndex;
    }

    return html + escape(source.slice(last));
  };

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

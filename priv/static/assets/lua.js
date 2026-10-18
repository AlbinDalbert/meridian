// Lua syntax highlighting, for the extension editor (live.js) and the docs pages (docs.js):
// `highlightLua(source)` returns the text as HTML, with tokens in spans (`hl-keyword`, ...).
(function () {
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

  window.highlightLua = highlight;
})();

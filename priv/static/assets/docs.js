// The docs pages: highlights their Lua code blocks (see lua.js).
document.querySelectorAll("pre code.language-lua").forEach((code) => {
  code.innerHTML = window.highlightLua(code.textContent);
});

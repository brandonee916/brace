# Release Notes

## 1.0.0 — 2026-09-02

The first release. Claude Desktop lists your MCP servers but won't let you change
them, so this is the editor for `claude_desktop_config.json`.

### Managing servers

- A sidebar of every server with a status dot — green is fine, amber is worth
  checking, red is broken, grey is switched off. Select one and the reason is the
  first thing on screen, with a button to fix it.
- Edit name, command, arguments and environment variables in ordinary form fields.
  Arguments are numbered boxes you can reorder; values that look like secrets stay
  masked until you click the eye.
- Remote HTTP and SSE servers are supported alongside local ones.
- **Test Connection** launches the server the way Claude Desktop would and checks
  that it answers, reporting what it found rather than a bare pass or fail.
- Switching a server off moves it aside instead of deleting it, so its settings —
  API keys included — are still there when you switch it back on.

### Adding servers

- **Add from Registry** searches the official MCP registry and lays out the fields
  for you, with each setting's description and whether it's required or secret.
  Entries are published by hand and go stale, so the app checks what PyPI or npm
  actually ships and warns you when they disagree.
- **Paste JSON** takes what people really copy — `//` comments, code fences, curly
  quotes, trailing commas, unquoted keys — and cleans it up, telling you what it
  changed. **Tidy Up** rewrites the box as formatted JSON.

### Not breaking your config

- Only the `mcpServers` key is ever rewritten. Everything else in the file, and the
  order of it, comes back byte for byte.
- Keys the app doesn't recognise are preserved, so a field a future Claude Desktop
  adds is never dropped.
- A timestamped backup before every save, with a manager to browse, restore, delete
  and set how many to keep.
- Writes are atomic, and a config that's already broken is reported with the line
  and column rather than overwritten.

### Getting the details right

- Warns when a command has no folder in front of it. Claude Desktop is launched by
  Finder and never sees your Terminal's `PATH`, which is why a bare `uvx` can work
  when you test it and fail in Claude. One click puts the full path in.
- If a command exists in several places, **Find…** lists them all with their
  version and where each came from, so you choose rather than guess.
- Flags a leading `~`, a command that isn't executable, duplicate server names,
  empty required variables, and malformed URLs.

### Elsewhere

- Built-in help, rendered from the project's README so there's one source of truth.
- Builds with the Xcode Command Line Tools alone — no Xcode, no Node, no package
  manager, no network.

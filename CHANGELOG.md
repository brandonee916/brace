# Release Notes

## 1.0.1 — 2026-09-03

Fixes a bug that made **Test Connection** fail against servers that were working
perfectly well.

- The reader that waited for a server's reply polled the pipe on a background
  thread with a short timeout. When that timed out the thread was still blocked on
  the read, and the next poll started another one — so whichever thread eventually
  woke up swallowed the handshake reply and discarded it. Any server that took a
  moment longer to start would time out for no reason. It now reads through a
  proper handler, so nothing is lost.
- `tools/list` was being re-sent every second until answered, reusing the same
  request id. It's sent once now, after the handshake is acknowledged.
- The test window shows live progress: what it's doing, how long it's been going,
  and the most recent line the server printed — so a slow first run that's
  downloading a package no longer looks frozen.
- The default timeout is longer, since a first run on a new machine has to
  download the package before anything can start.
- Saving no longer alphabetises the servers in your config file. The sidebar still
  sorts them for browsing, but the file keeps the order you had, with new servers
  added at the end.

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

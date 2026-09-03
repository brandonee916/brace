# Release Notes

## 1.2.2 — 2026-09-03

- Screenshots in the README, so the project page shows what the app looks like.
  They're taken against an invented sample configuration, never a real one.
- `CLAUDE_MCP_MANAGER_CONFIG_DIR` points the app at a different configuration
  directory. It exists so the documentation screenshots and the test suite can run
  against sample data; it changes nothing else.

## 1.2.1 — 2026-09-03

A review pass over every screen, and the fixes it turned up.

- The app icon now appears in the built-in guide. It never did: the guide is
  rendered from `README.md`, and the Markdown reader had no support for images, so
  it printed the raw `<img>` tag as text. Links were the same story — the Licence
  section read `[LICENSE](LICENSE)`, brackets and all.
- In the paste box, the command line each server would run was the dimmest text on
  screen, which is backwards for the one thing you're meant to read before adding
  something. It's now full-contrast, in a card with a real border, and the empty
  gap below it is gone.
- Testing a server left its process behind. Only one of the two output handlers was
  released, standard input was never closed, and a terminated child was never
  reaped — so every test leaked a handler and left a zombie, and a server ignoring
  SIGTERM was never cleaned up at all. Servers are now closed gently first, then
  signalled, then reaped, with a hard kill as the last resort. Measured: zero
  processes left behind after a run.
- Package identifiers from the registry are somebody else's data, and were being
  dropped straight into a URL and force-unwrapped. Now percent-encoded and checked.
- The guide's contents list was keyed on the first 60 characters of each block, so
  two similar paragraphs would have sent it scrolling to the wrong place. Keyed on
  position now.
- The licence carries the full name, Brandon McGowen.

## 1.2.0 — 2026-09-03

- The paste box now **shows the exact command each server would run** before you
  add it. A config file names the program Claude launches, so a snippet copied from
  somewhere untrustworthy can name an interpreter and hand it a script — and a
  friendly server name tells you nothing about that. Now you see the command line.
- It also flags the two shapes that mean "run arbitrary code": an interpreter such
  as `sh`, `python` or `node` handed inline code with `-c` or `-e`, and anything
  that downloads from the internet and pipes it to a shell. Ordinary servers don't
  look like that, so the warning stays rare enough to be worth reading. The same
  warnings appear in a server's Checks panel.
- The project is now MIT licensed.

Worth stating plainly: the app has never passed a command through a shell.
Arguments go to the operating system as a list, so a pasted `ls; rm -rf ~` is
treated as a filename and fails. Nothing runs when you paste or type — only when
you press Test Connection, or after you save and Claude Desktop launches it.

## 1.1.0 — 2026-09-03

- **About Claude MCP Manager**, under the app menu: the version, who made it, and
  links to the source and to Brandon's GitHub.
- **Update checking.** Once a day at launch the app asks GitHub whether there's a
  newer release. If there is, the status bar says so, and *See What's New* shows
  that release's notes — the same changelog entry, pulled from the release itself.
  It never installs anything; it points you at the download page.
  A failed check says nothing at all, so being offline never nags you. Checking by
  hand, from the About window, does report what went wrong.

## 1.0.2 — 2026-09-03

- An app icon, so the Dock, Finder and the Applications folder stop showing a
  blank placeholder. It's a pair of braces around three servers, with the middle
  one selected — the config file this app edits, and the list inside it.
- The artwork was re-centred: the braces had been positioned by their layout box,
  which carries the font's ascender and descender, leaving them 55px low.

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

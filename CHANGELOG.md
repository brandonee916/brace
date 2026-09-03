# Release Notes

## 2.2.0 — 2026-09-03

An external audit found several ways to lose a configuration or crash the app.
All of them are fixed, and every one now has a test.

### Could destroy a config

- **Saving on top of a config that failed to load wiped it.** A parse error left
  the app holding an empty document, and Save wrote that out — every existing
  server and all of Claude Desktop's own settings, gone. Saving now refuses
  whenever the file on disk can't be read and parsed.
- **A config with Windows line endings wouldn't parse at all**, which fed
  straight into the above. Swift reads a carriage return and line feed as one
  character, so the parser matched neither. The same bug swallowed a pasted
  snippet whole when it had a `//` header and CRLF endings.
- **Turning a server off could lose it entirely.** The config was written before
  the list of switched-off servers, so a failure on the second write left the
  server in neither file. They're written the other way round now: a failure
  duplicates rather than deletes.
- **A symlinked config was replaced by a regular file.** People keep this file in
  a dotfiles repository and link to it; saving broke the link and left the real
  file untouched, and "backups" were symlinks to the file they were meant to
  protect.
- **A server with no name was dropped silently**, secrets included, while the app
  reported success. It refuses to save now.
- The switched-off list had no conflict check and no backup of its own. Both
  fixed; backups now cover it too.
- **Restore replaced the whole file**, rolling back Claude Desktop's preferences
  along with the servers, which is not what the button offered to do. It now puts
  back only the servers.
- Closing the window discarded unsaved edits without a word, because the editor's
  state lived in the window. It belongs to the app now and survives.
- Backup filenames used your locale's calendar, so after a language change the
  app could no longer read its own names and pruning could delete the newest.

### Could crash the app

- **A server that answered and then exited killed Brace outright**, taking any
  unsaved edits with it: writing to a closed pipe raises a signal whose default
  action is termination.
- **Deeply nested JSON crashed the app.** Around five thousand levels overflowed
  the stack, and registry and update replies are parsed on threads with much less
  stack than the main one. Input that deep is now rejected.

### Testing a server

- **Stop didn't stop it.** It let go of the result but left the server running to
  the full timeout, and testing again started a second one alongside. It now
  shuts the server down, including anything that server started.
- Once a server closed its output the app spun a core reading nothing.

### Safety warnings

The check for snippets that run arbitrary code missed most real shapes. It now
catches versioned interpreters like `python3.12`, combined flags like `-ec`,
`--eval=`, wrappers such as `env` and `arch`, and shells like `pwsh` and `awk`.
It also flags environment variables that change what gets loaded or downloaded —
`DYLD_INSERT_LIBRARIES`, `NODE_OPTIONS`, `PYTHONPATH`, `UV_INDEX_URL` and
similar — and arguments that repoint a package manager at another source.

Registry entries no longer choose the launcher: a published entry could name any
program, including an absolute path. Only the known runtimes are accepted, the
same safety warnings now appear before you add from the registry, and repository
links are followed only over http and https.

### Smaller things

- A `"args"` entry containing a number lost it on every save. Remote servers
  declared with `transport` were rewritten as `type`. Both are preserved.
- A config with two `mcpServers` blocks is now refused rather than edited, since
  Brace and Claude Desktop would disagree about which one counts.
- Working out your shell's PATH no longer runs on the main thread at first paint.

## 2.1.2 — 2026-09-03

A pass over the remaining windows, checking each one when it is empty and when
it is full.

- **A failed test now tells you why.** It reported the exit code and nothing else
  whenever the server's output didn't happen to contain the word error, warning
  or fail — which is most of the time. A Python server saying "No module named
  mcp_server_filesystem" produced a completely silent failure. It now falls back
  to the last few lines of what the server actually printed.
- The test window sized itself the same whatever it held, so a two-line result
  sat above a large empty area. It follows its content now.
- The **Find…** picker showed one result followed by half a dozen empty rows. It
  is sized to the number of results.
- Checked and left alone: the backups, registry, help and about windows all fill
  their space deliberately, with centred placeholders when they are empty.

## 2.1.1 — 2026-09-03

Fixes the Paste JSON window, which was laid out badly in every state.

- Empty, it left a large gap between the box and the buttons. With several
  servers, the list overflowed and slid underneath them. The status area now
  sizes itself to its content and only scrolls once it genuinely overruns, and
  the text box takes whatever room is left over.
- Safety warnings moved above the server list. With four servers pasted at once
  the risky one can be last, and a warning you have to scroll to find is a
  warning nobody reads.

## 2.1.0 — 2026-09-03

Two ways your work could have been lost, both now closed.

- **Claude Desktop rewrites this file on its own** — it keeps its own preferences
  there and changes them while you're working. Brace held its copy from the moment
  you opened it, so saving quietly reverted anything Claude had changed in the
  meantime. It now re-reads the file first and builds on what's actually on disk,
  so Claude's settings survive. If the MCP servers themselves changed underneath
  you, it refuses to save and tells you to reload rather than guessing which
  version you meant.
- **Quitting with unsaved edits** discarded them without a word. It now asks
  whether to save, discard, or stay — and if saving fails, it stays put rather
  than quitting on top of the work.

## 2.0.0 — 2026-09-03

**The app is now called Brace** — MCP Manager for Claude Desktop.

The old name led with someone else's trademark, which made a third-party tool
read as an official one. Brace says what the icon already showed: the braces you
no longer have to count.

- Nothing about how it works has changed.
- macOS treats this as a new application, because the bundle identifier changed
  with the name. If you installed the old one, delete `Claude MCP Manager.app`
  from Applications — otherwise you'll have both. Your Claude Desktop
  configuration and your backups are untouched either way; they never lived
  inside the app.
- Two settings reset to their defaults, since they were stored against the old
  identifier: how many backups to keep, and when updates were last checked.
- The environment variable for pointing at a different configuration directory is
  now `BRACE_CONFIG_DIR`.

## 1.3.0 — 2026-09-03

- **What's new** now shows every release you skipped, not just the newest one. On
  1.0.0 you get all six releases since; on 1.2.0 you get only the two after it.
  Each version is its own section, newest first, with its date.
- The duplicated version heading in those notes is gone. Release notes come from
  the changelog, where each entry already starts with its own version heading, and
  the sheet prints the version above it.

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

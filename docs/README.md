# Screenshots

Taken against the sample configuration in `sample-config.json`, never a real one —
the servers and credentials shown here are invented.

To reproduce, point the app at a directory holding that file:

```bash
CLAUDE_MCP_MANAGER_CONFIG_DIR=/tmp/demo open -n "build/Claude MCP Manager.app"
```

`CLAUDE_MCP_MANAGER_CONFIG_DIR` only changes which directory the app reads and
writes; everything else behaves normally.

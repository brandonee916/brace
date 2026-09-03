# Screenshots

Taken against the sample configuration in `sample-config.json`, never a real one —
the servers and credentials shown here are invented.

To reproduce, point the app at a directory holding that file:

```bash
BRACE_CONFIG_DIR=/tmp/demo open -n "build/Brace.app"
```

`BRACE_CONFIG_DIR` only changes which directory the app reads and
writes; everything else behaves normally.

## Social preview

`../Resources/SocialPreview.png` is the image GitHub shows when a link to the
repository is shared — 1280x640, the size GitHub recommends, and under the 1 MB
limit. Regenerate it with `../Resources/make-icon.sh`.

Uploading it needs **Settings → General → Social preview → Edit → Upload an
image**. That control only appears on a public repository: GitHub allows uploads
to a private repository only if an image was already uploaded while it was public.

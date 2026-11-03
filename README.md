# Sito

A lightweight static development server. One executable, one command, a working local website. No configuration, no Node.js, no build step.

```bash
cd my-website
sito
```

Then open <http://localhost:3000>.

## Install

From a checkout, with the Dart SDK:

```bash
make install               # installs to ~/.local/bin/sito
make install PREFIX=/usr/local
make uninstall
```

Or download a binary from the GitHub releases page, place it on your `PATH`, and rename it to `sito`. Binaries do not need Dart installed.

## Usage

```text
sito [directory] [options]
```

| Command | Description |
|---|---|
| `sito` | Serve the current directory |
| `sito ./public` | Serve a specific directory |
| `sito -p 8080` | Use another port (default 3000) |
| `sito --host 0.0.0.0` | Bind to an interface (default 127.0.0.1) |
| `sito --reload` | Reload the browser when files change |
| `sito --open` | Open the site in the default browser |
| `sito --help` | Show usage |
| `sito --version` | Show the version |

Exit codes: `0` after a clean stop, `64` for invalid usage, `1` when the server cannot start.

## Behavior

- `/` and `/docs/` serve the directory's `index.html`. `/docs` redirects to `/docs/`.
- Directories are never listed. Directories without an index return 404.
- Only `GET` and `HEAD` are allowed. Single-range requests are supported so video can play and seek.
- Every response sends `Cache-Control: no-store`.

## Security

Sito is for local development, not production.

- It binds to loopback by default. `--host 0.0.0.0` exposes the site to your network, and the banner says so.
- Paths starting with a dot (`.env`, `.git/`) return 404, except `/.well-known/`.
- Symbolic links work when they stay inside the root. Links leading outside it, or to a hidden path, return 404.
- On loopback, requests with an unexpected `Host` header return 403, which blocks DNS rebinding.

Sito binds IPv4 only. If another program holds `[::1]` on the same port, your browser may reach that program at `localhost`; use `http://127.0.0.1:<port>` instead.

## Live reload

`--reload` watches the served directory and reloads connected browsers after a change, using a small script added to HTML responses. Files on disk are never modified.

- Changes in hidden paths and `node_modules/`, and editor temporary files (`*~`, `*.swp`, `*.swx`, `*.tmp`, `4913`), are ignored.
- `/__sito/reload` is reserved while `--reload` is active. If your project has a `__sito/` directory, Sito warns at startup and the endpoint takes priority.
- HTML is read into memory for injection and ignores `Range` requests under `--reload`.

`Directory.watch` cannot watch recursively on Linux, so Sito falls back to one watch per directory there. If a project exceeds the inotify limit, Sito warns and keeps serving; raise `fs.inotify.max_user_watches` to fix it.

## Development

```bash
dart run bin/sito.dart
make test
make build                 # writes build/sito
```

Pushing a `v*` tag builds macOS, Linux and Windows binaries and attaches them to a GitHub release.

## License

MIT

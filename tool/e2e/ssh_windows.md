# SSH project on a Windows host, end to end

`ssh_windows_app.dart` runs the real app (its `main`, on a copy of a data
folder) against a real SSH host whose project is a Git repository there, and
drives it through hit-tested pointer events and keys (the desktop perf input
driver). Each step saves a screenshot of the window and adds its result to
`result-<phase>.json` in the output folder. The process exits 0 only if
every step passes and Flutter reported no errors.

Build:

```sh
flutter build macos --debug --target tool/e2e/ssh_windows_app.dart
# or, on Windows:
flutter build windows --debug --target tool/e2e/ssh_windows_app.dart
```

Environment:

| Variable | |
|---|---|
| `PI_DESKTOP_DATA_DIR` | the data folder copy (`User/settings.json` with a model provider) |
| `PI_DESKTOP_REMOTE_SERVER_DIR` | `VERSION` and `pi-desktop-server-windows-x64` |
| `PI_DESKTOP_E2E_OUT` | where screenshots and results go |
| `PI_DESKTOP_E2E_HOST` | the host, as a project names it (`user@host`, or a saved server's name) |
| `PI_DESKTOP_E2E_ROOT` | the repository there (`C:\…`) |
| `PI_DESKTOP_E2E_PHASE` | `main`, `restart` (after `main`, same data folder), `windows` or `lsp` |
| `PI_DESKTOP_E2E_MODEL` | the agent's model, e.g. `@provider-3/glm-5.3` (an OpenCode one) |
| `PI_DESKTOP_E2E_CHROME`, `PI_DESKTOP_E2E_EXTENSION` | a Chrome wrapper loading the unpacked extension (see the browser live tests), and `browser_extension/` |
| `PI_DESKTOP_E2E_SSH_HOST`, `PI_DESKTOP_E2E_SSH_USER`, `PI_DESKTOP_E2E_KEY` | `windows`: the saved server's address, user and key |

The repository needs `src/a.txt` (with `hello world` in it) and an untracked
file holding `needle`.

Phases:

- `main` (macOS): files listed, a file edited and saved, a PowerShell
  terminal, Git changes and a diff, search, an agent's turn (read, edit, run),
  the ssh under the session killed and the session resumed, the tools for this
  machine (absent while the host's switch is off; `local_run`'s card, then
  push and pull), a server there forwarded here as the terminal prints its
  address, the ports page, the browser tool opening it in a Chrome of the
  run's own, and a server here forwarded there by hand and reached by `curl`.
- `restart`: the forwards made again as the app connects; one stopped on the
  ports page; `ADB_SERVER_SOCKET` reaching this machine's adb from there.
- `windows` (the app on Windows, the host this machine over its own sshd):
  the `main` steps without the agent and the browser; the tools for this
  machine called as an agent calls them (`local_run` in PowerShell).
- `lsp`: the status bar's entry naming the host's system (`Windows x64`) on
  hover; TypeScript's server (npm) and ty (PyPI) installed there, then a
  file's errors, hover, and Go to Definition opening the other file once.
  The host needs Node.js and Python.

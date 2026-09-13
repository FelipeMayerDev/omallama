# Omallama

Ollama in the Omarchy bar.

- Talks to Ollama on this machine or on another one, and keeps both: the gear in the panel takes the address of a remote server, and a switch moves between it and the local one without retyping anything. The same two values (`host`, `remote`) are in the widget's bar settings.
- Pointed at the remote, the panel drops the start/stop switch — systemd does not reach across the network — and says whether the host answers instead. Clearing the address in the gear forgets the remote and leaves you on local.
- Detects whether `ollama` is installed — if it isn't, the panel says so and stops.
- A switch starts and stops Ollama. It drives a **user** unit (`~/.config/systemd/user/ollama.service`, written on first use) so the server sees the models in your `~/.ollama`. Arch's packaged `ollama.service` runs as the `ollama` user with `OLLAMA_MODELS=/var/lib/ollama` and would list none of them; if that one is already running the switch leaves it alone and only stops it (polkit asks for the password).
- Lists the models you have pulled, largest first, with their size on disk.
- Shows the loaded model and how much of its maximum context window it was given.
- Hovering a model swaps its size for a bin: deleting asks first, then removes it from whichever server is selected.
- A text field pulls a new model. With the CLI here that is `ollama pull <name>` in a floating terminal (with `OLLAMA_HOST` set for a remote host), so you watch the download; with no local binary it goes over the API and the panel says "Pulling …" until the model appears.

## Install

```sh
omarchy plugin add https://github.com/FelipeMayerDev/omallama.git --enable
```

Or from a clone:

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.felipemayerdev.omallama
```

Then add the widget to the bar from Omarchy's bar settings.

## Note on the context percentage

Ollama reports the context window it *loaded* (`/api/ps` `context_length`), not
tokens consumed. The bar therefore shows how much of the model's maximum window
is available to the running instance — raise it with `OLLAMA_CONTEXT_LENGTH` or
a per-request `num_ctx`.

## Tests

```sh
python tests/test_plugin.py
```

## Credits

The llama mark is the Ollama icon from [Simple Icons](https://simpleicons.org) (CC0), redrawn as
QML vector geometry in `OllamaIcon.qml` so it takes the theme colour.

## Development

The shell runs with `QS_DISABLE_FILE_WATCHER=1`, so editing a plugin file does
not reload it — the bar keeps the copy it compiled at start. Run
`omarchy-restart-shell` to see a change.

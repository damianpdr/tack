# Voice

A small native macOS app that turns speech plus screenshots and clipboard copies into one prompt for AI agents (Claude Code, Codex, terminals) or any other app. A simplified take on [Field Theory](https://github.com/afar1/fieldtheory) without the librarian, bookmarks or wiki. No code was copied from it.

1. Press the record hotkey. A black pill with a live waveform appears at the bottom of the screen.
2. Talk. Take screenshots with Voice's hotkeys, or copy things (text, images, files). Each capture adds a `|` tick to the pill.
3. Press the record hotkey again. Voice transcribes the audio, puts `[figure N]` / `[clip N]` / `[file N]` markers where the captures happened, and pastes the result into the frontmost app. The same text also stays on the clipboard.

`Esc` or the pill's `×` cancels the recording and discards it.

## Output format

This is the text agents and terminals get. It is also what is left on the clipboard and in `prompt.md`:

````
Here is the settings page. [figure 1] Please make the header smaller. [clip 1] That's the error.

[figure 1]: /Users/me/.voice/sessions/2026-09-24_17-27-02/figure-1.png

[clip 1]:
```
TypeError: cannot read properties of undefined
```
````

- Figure and file paths are absolute. A path that contains spaces is wrapped in `<…>`.
- If the only thing captured is one image and nothing was said, the bare image path is pasted.

How the paste depends on the frontmost app:

| Frontmost app | What is pasted |
| --- | --- |
| Terminals (Terminal, iTerm, Warp, Ghostty, kitty, WezTerm, Alacritty, Hyper, Tabby), editors and agents (Cursor, VS Code, Zed, MacVim, Claude, Codex, Orca, T3 Code) | The markdown above |
| Any other app | Each image as a picture, then the text with `[figure N]` markers but no path lines |
| Any app, with *Paste mode → Text only* | The markdown above |

Voice always leaves the markdown on the clipboard afterwards. Agents can also read the latest prompt directly:

```sh
cat ~/.voice/latest/prompt.md
```

## Requirements and install

- macOS 14 or later.
- Swift 6 toolchain. The Command Line Tools are enough; Xcode is not required.

```sh
scripts/build-app.sh            # builds build/Voice.app
scripts/build-app.sh --install  # also replaces /Applications/Voice.app
scripts/test.sh                 # unit tests
swift scripts/make-icon.swift   # regenerates Resources/AppIcon.icns
```

macOS ties permissions to the app's signature. An ad-hoc signature changes on every build, so every rebuild loses its permissions. `build-app.sh` signs with the `Voice Local Signing` identity whenever it exists in the keychain. That identity is a self-signed code-signing certificate, created once like this:

```sh
cd "$(mktemp -d)"
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Voice Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cfg
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cfg
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:voice -name "Voice Local Signing"
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P voice -T /usr/bin/codesign
```

You can also sign with any other identity:

```sh
VOICE_SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh --install
```

Permissions. If any are missing, Voice opens *Settings → Permissions* on launch; click *Grant…* next to each one:

- **Microphone**: recording.
- **Accessibility**: pasting with ⌘V into other apps. Without it, the prompt is only copied.
- **Screen Recording**: Voice's screenshot hotkeys.

Voice uses the same default hotkeys as Field Theory. Quit Field Theory, or change the hotkeys in one of the two apps, because only one app can register each shortcut.

## Hotkeys

| Default | Action |
| --- | --- |
| `` ` `` | Start / stop recording |
| `⌥4` | Region screenshot |
| `⌥3` | Full-screen screenshot |
| `⌥Space` | Clipboard history window |
| `Esc` | Cancel the current recording |

All of them can be changed in *Settings → General*. A bare `` ` `` hotkey means you can no longer type a backtick in other apps; choose a hotkey with a modifier if you need backticks.

Screenshots taken outside a recording go to the history. macOS's own screenshots (⌘⇧3/4/5) are picked up only if *Capture macOS screenshots saved to disk* is on. That option watches the system screenshot folder, which can trigger a Desktop access prompt.

## Transcription

### OpenRouter (cloud, default)

- Add an API key in *Settings → Transcription*. For `voicectl` or a terminal-launched app you can instead export `OPENROUTER_API_KEY`.
- Pick any of OpenRouter's transcription models. The default is `openai/gpt-4o-transcribe`.
- Audio is split at the capture points, and each part is sent separately. This is how the markers land between sentences.

### Parakeet (local)

- In *Settings → Transcription*, choose *Parakeet (local)* and click *Download* (about 470 MB, saved to `~/.voice/models/parakeet-tdt-0.6b-v3/`).
- Runs NVIDIA Parakeet TDT 0.6b v3 on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). A minute of speech takes about a second. The first transcription after a launch can take a few seconds more while CoreML loads the model.
- Detects the language on its own across 25 European languages, including Polish. Choosing a language only keeps it from writing in another alphabet.
- Like whisper.cpp, it transcribes the whole recording in one pass and places markers using word timestamps.
- Vocabulary hints are not used.
- The model is licensed CC-BY-4.0 by NVIDIA.

### whisper.cpp (local)

```sh
brew install whisper-cpp
```

- In *Settings → Transcription*, choose *whisper.cpp (local)*.
- Then either download `large-v3-turbo` (q5_0, about 550 MB, saved to `~/.voice/models/`) or choose any existing `ggml-*.bin` model.
- If `whisper-cli` is not on the default Homebrew path, you can point Voice at it.
- whisper.cpp transcribes the whole recording in one pass, so language detection sees all of it.
- Markers are placed using word timestamps. These are only accurate when the model file keeps its standard name (`ggml-large-v3-turbo…`, `ggml-medium…`, and so on); Voice uses the name to enable DTW timing. With a renamed or custom model, a marker can land inside a sentence.

### Vocabulary

In *Settings → Transcription → Vocabulary*, list project names, components and jargon, one per line or separated by commas, e.g. `TrollboxPanel`, `useOrderbookStream`, `Tailwind`. The list is sent as a hint:

- whisper.cpp: `--prompt`.
- OpenRouter: `provider.options`. Microsoft MAI gets a `phraseList`; OpenAI and Groq get a `prompt`. Other providers get no hint.

Tested with the same phrases: MAI-Transcribe 2 wrote all of them correctly, where without the hint it wrote "Hawk Use Order Box Trim".

### Figure size

*Settings → General → Screenshots in prompts* limits the longest edge of figures attached to a prompt. The default is 2048 px. A Retina full-screen capture (e.g. 6016×3384) is downscaled before it lands in `sessions/…/figure-N.png`. The original stays in `clips/` and in History.

## Clipboard history

Open it with `⌥Space` or from the menu bar icon. It lists voice prompts, screenshots, copied text, images and files, newest first.

| Key | Action |
| --- | --- |
| `↑` / `↓`, `k` / `j` | Move |
| `Return` | Paste into the previously active app |
| `⌘C` | Copy |
| `x` / `Space`, `⌘`/`⇧`-click | Select multiple items |
| `s` | Stack the selected items into one prompt (figures renumbered) |
| `Delete` | Delete |
| `/` | Search |
| `Esc` | Clear the search or selection, or close the window |

*Re-transcribe*, in the detail pane or the context menu, runs a voice item again with the engine currently selected in the toolbar picker. Use it after switching engines or when a transcription failed.

Voice skips clipboard items that password managers mark as concealed or transient.

## Data

Everything is stored in `~/.voice`. Set `VOICE_HOME` to use a different folder.

```
settings.json
history.sqlite
clips/                               screenshots and images copied outside recordings
sessions/<yyyy-MM-dd_HH-mm-ss>/      audio.wav, figure-N.png, prompt.md, transcript.txt, session.json
latest -> sessions/…                 the most recent prompt
models/                              downloaded whisper models
```

## CLI

`voicectl` runs the same transcription pipeline on an existing audio file:

```sh
swift run voicectl transcribe note.wav --engine parakeet --language pl --image 4.2:shot.png --clip 9.0:"some text"
swift run voicectl models   # OpenRouter transcription models
```

## Known limitations

- A macOS screenshot whose floating thumbnail is still on screen when you stop recording is not included. Stop after the thumbnail disappears, or turn the thumbnail off in ⌘⇧5 → Options.
- Changing the input device in the middle of a recording ends the recording.
- The pill ignores clicks while a recording is being transcribed.

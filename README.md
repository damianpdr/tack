# Tack

**Talk. Tack screenshots in. Paste into your agent.**

A small native macOS app that turns what you say, plus the screenshots and copies you make while saying it, into one prompt for AI agents (Claude Code, Codex, Cursor, terminals) or any other app. Transcription runs on your Mac by default.

1. Press `⌃⌥R`. A black pill with a live waveform appears at the bottom of the screen.
2. Talk. Take screenshots with `⌃⌥4` (region) or `⌃⌥3` (screen), or copy text, images and files. Each capture flies from where you took it into the pill, and its `figure N` marker appears in the live transcript where you said it.
3. Press `⌃⌥R` again. Tack transcribes the audio, puts `[figure N]` / `[clip N]` / `[file N]` markers where the captures happened, and pastes the result into the frontmost app. The same text also stays on the clipboard.

Or hold `⌃⌥R` while you talk and let go to finish; the pill gets a warm rim while you hold. `Esc` or the pill's `×` cancels the recording and discards it.

Short sounds mark the start, each capture and the delivery; turn them off with *Settings → General → Play sounds*. If the pill is too much, pick *Minimal* under *Settings → General → Pill*: white bars, no glow, nothing flying, and no sounds unless you turn them back on. With *Reduce motion* on in macOS, captures and prompts don't fly.

## Output format

This is the text agents and terminals get. It is also what is left on the clipboard and in `prompt.md`:

````
Here is the settings page. [figure 1] Please make the header smaller. [clip 1] That's the error.

[figure 1]: /Users/me/.tack/sessions/2026-09-24_17-27-02/figure-1.png

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

Tack always leaves the markdown on the clipboard afterwards. Agents can also read the latest prompt directly:

```sh
cat ~/.tack/latest/prompt.md
```

## Requirements and install

- macOS 14 or later.

Download `Tack-<version>.dmg` from the [latest release](https://github.com/damianpdr/tack/releases/latest), open it and drag Tack to Applications.

Tack is not notarized by Apple yet, so the first open takes one extra step: macOS says it "cannot be opened because the developer cannot be verified". Click *Done*, then open *System Settings → Privacy & Security*, scroll to the message about Tack and click *Open Anyway*. Every later launch is normal. Tack also checks GitHub Releases for a new version once a day, and on demand from *Check for Updates…* in its menu.

### Building from source

- Swift 6.2 or newer. The Command Line Tools are enough; Xcode is not required.

```sh
scripts/build-app.sh            # builds build/Tack.app
scripts/build-app.sh --install  # also replaces /Applications/Tack.app
scripts/test.sh                 # unit tests
swift scripts/make-icon.swift   # regenerates Resources/AppIcon.icns
```

macOS ties permissions to the app's signature. An ad-hoc signature changes on every build, so every rebuild loses its permissions. `build-app.sh` signs with the `Tack Local Signing` identity whenever it exists in the keychain. That identity is a self-signed code-signing certificate, created once like this:

```sh
cd "$(mktemp -d)"
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Tack Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cfg
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cfg
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:voice -name "Tack Local Signing"
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P voice -T /usr/bin/codesign
```

You can also sign with any other identity:

```sh
TACK_SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh --install
```

### Permissions

If any are missing, Tack opens *Settings → Permissions* on launch; click *Grant…* next to each one:

- **Microphone**: recording.
- **Accessibility**: pasting with ⌘V into other apps. Without it, the prompt is only copied.
- **Screen Recording**: Tack's screenshot hotkeys.

## Hotkeys

| Default | Action |
| --- | --- |
| `⌃⌥R` | Tap to start / stop recording, or hold to talk and release to stop |
| `⌃⌥4` | Region screenshot |
| `⌃⌥3` | Full-screen screenshot |
| `⌃⌥V` | History window |
| `Esc` | Cancel the current recording |

All of them can be changed in *Settings → General*. The defaults all use `⌃⌥`, which types no characters and is free in window managers like Rectangle and Magnet. Only one app can register each shortcut; if another app already uses one, Settings marks it.

Screenshots taken outside a recording go to the history. macOS's own screenshots (⌘⇧3/4/5) are picked up only if *Capture macOS screenshots saved to disk* is on (off by default). That option watches the system screenshot folder, which can trigger a Desktop access prompt.

## Transcription

### Parakeet (local, default)

- On first launch Tack opens *Settings → Transcription*; click *Download* (about 470 MB, saved to `~/.tack/models/parakeet-tdt-0.6b-v3/`). After that nothing leaves your Mac.
- Runs NVIDIA Parakeet TDT 0.6b v3 on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). A minute of speech takes about a second. The first transcription after a launch can take a few seconds more while CoreML loads the model.
- Detects the language on its own across 25 European languages, including Polish. Choosing a language only keeps it from writing in another alphabet.
- Transcribes the whole recording in one pass and places markers using word timestamps.
- *Show live transcript in the pill* (on by default) shows the last words you said while recording.
- Vocabulary hints are not used.
- The model is licensed CC-BY-4.0 by NVIDIA.

### OpenRouter (cloud)

- Add an API key in *Settings → Transcription*. Tack keeps it in the macOS keychain. For `tackctl` or a terminal-launched app you can instead export `OPENROUTER_API_KEY`.
- Pick MAI-Transcribe 2 (default), GPT-4o Transcribe or GPT-4o mini Transcribe, or *Custom…* for any other OpenRouter transcription model.
- Audio is split at the capture points, and each part is sent separately. This is how the markers land between sentences.

### Vocabulary

In *Settings → Transcription → Vocabulary*, add project names, components and jargon, e.g. `Supabase`, `Kubernetes`, `useEffect`. Type a term and press Return, or paste a comma-separated list to add many at once. The list is sent as a hint:

- OpenRouter: `provider.options`. Microsoft MAI gets a `phraseList`; OpenAI and Groq get a `prompt`. Other providers get no hint.

In our tests, MAI-Transcribe 2 spelled every listed term correctly with the hint, and mangled camelCase identifiers into separate words without it. Parakeet does not use the list yet.

### Figure size

*Settings → General → Screenshots in prompts* limits the longest edge of figures attached to a prompt. The default is 2048 px. A Retina full-screen capture (e.g. 6016×3384) is downscaled before it lands in `sessions/…/figure-N.png`. The original stays in the session's `captures/` folder.

## History

Open it with `⌃⌥V` or from the menu bar icon. It lists voice prompts and screenshots, newest first. Screenshots and copies made during a recording are part of that recording's entry, not separate items. Copies made outside a recording are never recorded.

The header shows how much typing your voice notes replaced, at 40 words per minute; each voice note shows its word count and how much faster than typing it was.

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

While recording, Tack skips clipboard items that password managers mark as concealed or transient.

## Data

Everything is stored in `~/.tack`. Set `TACK_HOME` to use a different folder.

```
settings.json                        everything except the OpenRouter key, which is in the keychain
history.sqlite
clips/                               screenshots taken outside recordings
sessions/<yyyy-MM-dd_HH-mm-ss>/      audio.wav, figure-N.png, prompt.md, transcript.txt, session.json,
                                     captures/ (full-size originals of the figures)
latest -> sessions/…                 the most recent prompt
models/                              the downloaded Parakeet model
```

## CLI

`tackctl` runs the same transcription pipeline on an existing audio file:

```sh
swift run tackctl transcribe note.wav --engine parakeet --language pl --image 4.2:shot.png --clip 9.0:"some text"
swift run tackctl models   # OpenRouter transcription models
```

## Releasing

A release is a DMG attached to a GitHub release. `VERSION` at the repo root is the only place the version lives; `CFBundleVersion` is the commit count. Bumping `VERSION` is the whole version bump.

```sh
scripts/make-dmg.sh           # builds build/Tack-<version>.dmg (Tack.app + /Applications symlink)
scripts/release.sh            # builds the DMG, then prints the gh command
scripts/release.sh --publish  # also runs `gh release create v<version> …`
```

`--publish` refuses to run when the working tree is dirty or the `v<version>` tag already exists.

Notarization stays off until there is an Apple Developer ID. With one, it is two environment variables:

```sh
xcrun notarytool store-credentials tack-notary --apple-id … --team-id … --password <app-specific-password>
TACK_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" TACK_NOTARY_PROFILE=tack-notary scripts/release.sh
```

`TACK_NOTARY_PROFILE` makes `make-dmg.sh` submit the DMG with `notarytool submit --wait` and staple the ticket to it, and makes `build-app.sh` sign with `--timestamp` (notarization rejects signatures without a secure timestamp) instead of the faster, offline `--timestamp=none`. Set without a Developer ID identity it stops before building, rather than producing a DMG Apple would reject. Once releases are notarized, the *Open Anyway* step above disappears.

## Known limitations

- A macOS screenshot whose floating thumbnail is still on screen when you stop recording is not included. Stop after the thumbnail disappears, or turn the thumbnail off in ⌘⇧5 → Options.
- Changing the input device in the middle of a recording ends the recording.
- The pill ignores clicks while a recording is being transcribed.

## Credits

- Speech recognition: NVIDIA Parakeet TDT 0.6b v3 (CC-BY-4.0), run through FluidAudio (Apache 2.0).

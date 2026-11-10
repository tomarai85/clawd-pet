# Clawd — a tiny desktop pet for macOS

A pixel Clawd that lives at the bottom of your screen. It idles, walks, blinks, changes its look now and then (15 looks and 66 motions in the catalog) and reacts when you click it. It takes the keyboard only in the windows you open (the chat and Settings), has no Dock icon, and makes no network connections.

If you dictate with [Aqua Voice](https://aquavoice.com/mac), Clawd also reacts while you speak: a small bubble shows that it is listening, thinking, and done. Aqua Voice is optional; without it Clawd is simply a desktop pet.

> **Fan project.** Clawd is Anthropic's Claude Code mascot. This project is not made, endorsed or supported by Anthropic. The sprites are derived from Anthropic's Clawd (see [Art](#art)); they will be removed on request.

## Requirements

- A Mac with Apple silicon, macOS 13 or later
- Xcode or the Command Line Tools (`xcode-select --install`), for Swift 5.9+

## Install

```sh
git clone https://github.com/tomarai85/clawd-pet.git
cd clawd-pet
swift build -c release
mkdir -p ~/bin          # the command-line tool goes here; add ~/bin to your PATH if it is not already
scripts/install         # copies the pet into ~/Library/Application Support/clawd-pet and writes a LaunchAgent; starts nothing
~/bin/clawd-pet start
```

macOS shows a one-time "background item added" notice for the LaunchAgent. Clawd then starts at login.

To update after `git pull`: `swift build -c release && scripts/update`.

## Use

```sh
clawd-pet status              # is it running, which look, which settings
clawd-pet size 2              # 0.5, 0.75, 1, 1.5, 2, 3 or 4 (1 = 48 pt)
clawd-pet motion lively       # off, quiet (default), normal, lively
clawd-pet walk off            # stop the short walks along the bottom of the screen
clawd-pet look wizard         # wear one look; `look random` lets it change again
clawd-pet look-every 2h       # how often the look changes: 2h, 3h, 4h
clawd-pet hide 30             # hide for 30 minutes; `show` brings it back
clawd-pet stop                # remove it from the screen
clawd-pet help                # everything else
```

Right-click Clawd for the same settings in a small menu.

### Chat with Claude Code

Double-click Clawd (or right-click and pick "Chat with Claude Code") to open a floating window that runs Claude Code itself. It needs
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and signed in. Clawd uses the path you set with
`clawd-pet chat claude PATH`; without one it looks in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, in that order. It starts in your home folder, or in the working folder you choose in Settings > Claude Code. Close the window with Cmd+W, its close button or a click anywhere else; Claude Code is stopped 10
minutes after the window closes.

By default Claude Code runs in its normal permission mode with no prompts, so tools that need your approval are refused. To let it act
without asking, choose Bypass under Permissions in Settings > Claude Code, or run `clawd-pet chat permissions bypass` (at your own risk).

macOS may ask once whether "clawd-pet-agent" may access a folder: that is Claude Code, started by Clawd, reading files there.

### Aqua Voice

```sh
clawd-pet aqua auto           # default: follow Aqua Voice only if it is installed
clawd-pet aqua follow         # show Clawd only while Aqua Voice runs
clawd-pet aqua ignore         # never hide Clawd because of Aqua Voice
clawd-pet aqua react off      # do not react to dictation at all (reads no Aqua log); `aqua react on` is the default
clawd-pet bubble side above   # bubble below (default), above, left or right of Clawd
clawd-pet bubble exclude 1    # never use bubble style 1 of 15 (`bubble list` shows them)
```

Clawd only reads Aqua Voice's own log file and whether the app is running; it never sends input to Aqua Voice or any other app.

### Exams

While Respondus LockDown Browser runs, Clawd hides, and it stays hidden until two minutes after the browser quits. If it is restarted while the browser runs, it starts hidden.

## Uninstall

```sh
~/bin/clawd-pet uninstall     # removes everything install created; its log file is kept and its path printed
```

## Art

The sprites in `art/` are derived from Anthropic's Clawd character: some are Clawd's pixel art as it appears in Claude Code, others are pixel redraws of the official Clawd plush outfits. They are not covered by the code license below and remain Anthropic's. If you are Anthropic and want them removed, open an issue and they will be taken down.

The source files the sprites were ported from are not included in this repository, so `scripts/port-*.py`, `scripts/check-art-contract.py` and the checks under `Tests/art/` do not run here. Building, installing and running the pet do not need them.

## License

The code (everything outside `art/` and `Tests/Goldens/`) is MIT licensed; see [LICENSE](LICENSE).

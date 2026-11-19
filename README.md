# Tote

A tiny drag-and-drop shelf for macOS, built for people who live in tiling window managers like [AeroSpace](https://github.com/nikitabobko/AeroSpace).

**The problem:** with virtual workspaces, switching workspace mid-drag drops whatever you were holding. You can't carry a file from workspace 2 to workspace 1.

**Tote fixes that.** Start dragging something and a small shelf appears. Drop it there, switch workspace, and drag it back out. Even better, drop it on a workspace button and Tote switches you there in the same motion.

<!-- TODO: add a demo GIF here, for example docs/demo.gif -->
<!-- ![Tote demo](docs/demo.gif) -->

## Features

- **Appears when you drag, hides when it's empty.** No windows to manage.
- **Holds files, links, text and images.** Dragged-out web images are saved as PNG files so they behave like any other file.
- **AeroSpace workspace buttons.** Drop something on a button to switch workspace with it in hand. Shown automatically when AeroSpace is installed.
- **Drag out, and it's gone.** Items leave the shelf after a successful drop (or keep them with one setting).
- **Drag all.** Grab a whole stack in one drag.
- **Quick Look.** Click a file to preview it; arrow keys move between files.
- **Global shortcut** to show or hide the shelf (default `⌃⌥S`, changeable).
- **Lite mode.** Tote never opens your files, so macOS never asks for folder access.
- **Settings in the menu bar:** corner, gap from the screen edge, launch at login and more.

## Install

Requires macOS 14 (Sonoma) or later.

### Homebrew

```sh
brew install --cask TanayJoshi-XR/tap/tote
```

### Manual

1. Download `Tote-<version>.zip` from the [latest release](https://github.com/TanayJoshi-XR/Tote/releases/latest).
2. Unzip it and move `Tote.app` to `/Applications`.
3. Open it. macOS will say it can't verify the app (see below).

### First launch: "Tote can't be opened"

Tote is signed ad hoc but **not notarized yet** (that needs a paid Apple developer account). macOS therefore blocks the first launch. Either:

- Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Tote, or
- Run `xattr -dr com.apple.quarantine /Applications/Tote.app` in Terminal.

The Homebrew cask does the second step for you and says so when it installs.

## Usage

| Action | How |
| --- | --- |
| Show the shelf | Start dragging a file, link, text or image, or press `⌃⌥S` |
| Hold something | Drop it on the shelf |
| Move it to another workspace | Drop it on a workspace button (AeroSpace), or drop, switch, then drag it out |
| Use it | Drag it out of the shelf into any app |
| Preview a file | Click it |
| Open settings | Click the bag icon in the menu bar |

## Privacy

- No network access, no analytics, no accounts.
- The shelf only lives in memory. Quitting Tote empties it.
- Files are held as references to the originals, never copied (except web images, which are saved to a temporary folder that is cleared when Tote starts and quits).
- **Lite mode** goes further: Tote never reads your files at all, only their names.

## AeroSpace integration

If `aerospace` is installed at `/opt/homebrew/bin/aerospace` or `/usr/local/bin/aerospace`, Tote shows one button per workspace. It only runs `aerospace list-workspaces` and `aerospace workspace <name>`. You can turn the buttons off in settings.

## Build from source

```sh
git clone https://github.com/TanayJoshi-XR/Tote.git
cd Tote
open Tote.xcodeproj
```

Press Run in Xcode. To make a release zip, run `./release.sh 1.0.0`.

## Status

Early release. It works on the setups I've tested, so bug reports are very welcome. Known gaps: some browsers hand over images as "file promises", which Tote doesn't support yet.

## License

[MIT](LICENSE)

# screener

A tiny, offline macOS screenshot tool that replaces the built-in one, inspired by CleanShot X.

Capture → a thumbnail appears in the corner → click it to annotate, drag it into any app, copy, save, or pin it on top of everything. Nothing touches disk unless you save it.

- **~340 KB** app, **~10 MB** RAM idle, 0% CPU
- No network calls, no accounts, no analytics
- Native Swift/AppKit, no dependencies

## Features

- **Capture** an area, a window, or the full screen. Space toggles area ↔ window, like the macOS tool.
- **Quick-access thumbnail** stays in the corner until you dismiss it. Hover for Copy / Save / Annotate / Pin. Drag it into Slack, Mail, Figma, Finder…
- **Annotate**: arrow, rectangle, filled rectangle, ellipse, line, pencil, highlighter, text, pixelate, crop. Drag to move anything you've drawn, double-click text to edit, full undo/redo.
- **Pin** a screenshot as an always-on-top floating window. Scroll to change opacity, lock it to click through, arrow keys to nudge.
- **Freeze screen** to capture hover states, tooltips and open menus.
- **OCR**: drag over any text (or a QR code) and it's copied to your clipboard, fully on-device.

## Shortcuts

| Action | Shortcut |
|---|---|
| Capture area | ⇧⌘4 |
| Capture window | ⇧⌘5 |
| Capture fullscreen | ⇧⌘3 |
| Copy area to clipboard | ⇧⌃⌘4 |
| Copy fullscreen to clipboard | ⇧⌃⌘3 |
| Capture text (OCR) | ⇧⌘2 |
| Freeze screen & capture | ⌃⌥⌘F |
| Capture previous area | ⌃⌥⌘R |
| Show / hide pins | ⌃⌥⌘P |
| Close all pins | ⌃⌥⌘W |

Everything is also in the menu bar icon.

## Install

Requires macOS 12 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/zachglabman/screener.git
cd screener
./build.sh            # or ./build.sh --universal for Apple Silicon + Intel
```

This builds the app and installs it to `/Applications/ScreenshotTool.app`, then you can open it from there.

On first launch:

1. **Allow Screen Recording** when asked (System Settings → Privacy & Security → Screen Recording), then quit and reopen the app from the menu bar icon. Without this, captures show only your wallpaper.
2. **Click "Turn Off macOS Shortcuts"** so ⇧⌘3/4/5 open screener instead of the built-in tool. You can restore them from the menu bar at any time.

It's set to launch at login automatically; toggle that from the menu bar.

## Notes

- The app is ad-hoc signed (no Apple Developer ID), which is why it's built from source rather than downloaded.
- Screenshots save to `~/Pictures/Screenshots` by default. Change it from the menu bar.

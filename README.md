# screener

A tiny, free screenshot tool for Mac that replaces the built-in one, inspired by CleanShot X.

Take a screenshot and a little preview appears in the corner of your screen. Click it to draw arrows, add text or blur things out. Drag it straight into Slack, email or any other app, or pin it so it floats on top while you work. Nothing is saved to your Mac unless you choose to save it.

- **Tiny:** under 1 MB, uses almost no memory
- **Private:** works completely offline, no account, no tracking
- **Free**

---

## Get started (no coding needed)

### 1. Download

👉 **[Download screener](https://github.com/zachglabman/screener/releases/latest/download/ScreenshotTool.zip)**

### 2. Install

1. Open your **Downloads** folder and double-click **ScreenshotTool.zip** to unzip it.
2. Drag **ScreenshotTool** into your **Applications** folder.

### 3. Open it the first time

Because screener is free and not sold through Apple, your Mac will be cautious the first time you open it:

1. Open your **Applications** folder, **right-click** (or Control-click) **ScreenshotTool** and choose **Open**.
2. If you see a warning, click **Open**.
   - If there's no Open button: go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the message about ScreenshotTool. Then open it again.

You only have to do this once.

### 4. Allow screen recording

Your Mac will ask whether ScreenshotTool can record your screen. This is how it takes screenshots. It never sends anything anywhere.

1. Click **Open System Settings** when asked (or go to **System Settings → Privacy & Security → Screen Recording**).
2. Turn on **ScreenshotTool**.
3. Quit it (click the 📷 icon in your menu bar at the top of the screen → **Quit**) and open it again from Applications.

> If your screenshots come out as just your desktop wallpaper, this step didn't finish. Do it again and reopen the app.

### 5. Let it take over your screenshot shortcuts

A box will ask **"Replace the macOS screenshot shortcuts?"** Click **Turn Off macOS Shortcuts**.

Now the shortcuts you already know (⇧⌘3, ⇧⌘4, ⇧⌘5) open screener instead of the Mac's built-in tool. You can switch back at any time from the 📷 menu.

**That's it!** screener starts automatically when you log in, so it's always ready.

---

## How to use it

Press **Shift + Command + 4** (⇧⌘4), then drag a box around what you want.

A preview pops up in the bottom-right corner. Move your mouse over it to see your options:

- **Copy**: copies it so you can paste it anywhere
- **Save**: saves it to your **Pictures → Screenshots** folder
- ✏️ **Annotate**: draw arrows, boxes and text, highlight or blur things, crop
- 📌 **Pin**: keeps it floating on top of everything while you work
- ✕ **Close**: throws it away

You can also **drag the preview** straight into an email, a Slack message, a document, or anywhere else.

### All the shortcuts

| What it does | Shortcut |
|---|---|
| Screenshot an area | ⇧⌘4 (press **Space** to switch to picking a window) |
| Screenshot a window | ⇧⌘5 |
| Screenshot the whole screen | ⇧⌘3 |
| Copy an area (no preview) | ⇧⌃⌘4 |
| Copy the whole screen (no preview) | ⇧⌃⌘3 |
| Copy text from the screen | ⇧⌘2 |
| Freeze the screen, then screenshot | ⌃⌥⌘F |
| Screenshot the same area as last time | ⌃⌥⌘R |
| Show / hide pinned screenshots | ⌃⌥⌘P |
| Close all pinned screenshots | ⌃⌥⌘W |

⇧ = Shift, ⌘ = Command, ⌃ = Control, ⌥ = Option

Everything is also in the **📷 menu** at the top of your screen.

### Handy extras

- **Copy text from anything:** press ⇧⌘2 and drag over text, even in images or videos. It's copied so you can paste it. Works on QR codes too.
- **Freeze the screen:** press ⌃⌥⌘F to capture menus or pop-ups that disappear when you click.
- **Pinned screenshots:** scroll on one to make it see-through. Right-click it for more options. Press Esc to close it.
- **In the editor:** drag anything you've drawn to move it. Double-click text to change it. ⌘Z undoes.

---

## Questions

**My screenshots are just my wallpaper.**
Screen recording permission isn't on. See [step 4](#4-allow-screen-recording).

**The Mac's own screenshot tool still opens too.**
Click the 📷 menu → **Turn Off macOS Screenshot Shortcuts**.

**How do I go back to the Mac's built-in screenshots?**
Click the 📷 menu → **Restore macOS Screenshot Shortcuts**, then **Quit**. To remove screener completely, drag **ScreenshotTool** from Applications to the Trash.

**Where do my saved screenshots go?**
**Pictures → Screenshots**. To change it, click the 📷 menu → **Change Save Location…**

**Does it work on my Mac?**
Any Mac running macOS 12 (Monterey) or newer, Apple Silicon or Intel.

---

## For developers

Native Swift/AppKit, no dependencies. Build from source with the Xcode Command Line Tools (`xcode-select --install`):

```sh
git clone https://github.com/zachglabman/screener.git
cd screener
./build.sh              # native architecture, installs to /Applications
./build.sh --universal  # Apple Silicon + Intel
```

The app is ad-hoc signed with a bundle-ID-based designated requirement, so the Screen Recording permission survives rebuilds.

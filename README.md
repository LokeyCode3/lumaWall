# LumaWall

**LumaWall** is a lightweight, native macOS live video wallpaper studio with an **Obsidian Aurora** translucent glass interface. Turn any local `.mp4`, `.mov`, or `.m4v` video into a seamless, looping desktop wallpaper—complete with automatic border removal, persistent local storage, dual-screen configuration (Main Screen + Lock Screen / Screen Saver), and a companion macOS Screen Saver (`LumaWallSaver.saver`).

---

## Quick Install (Terminal One-Liner)

Run this command in **Terminal** on your Mac to automatically download, compile, install to `/Applications/LumaWall.app`, and launch LumaWall:

```bash
curl -fsSL https://raw.githubusercontent.com/LokeyCode3/lumaWall/main/install.sh | bash
```

Or clone and install manually:

```bash
git clone https://github.com/LokeyCode3/lumaWall.git && cd lumaWall && chmod +x install.sh && ./install.sh
```

> **Requirements:** macOS 13.0+ and Xcode Command Line Tools (`xcode-select --install` if `swiftc` is not already installed). No full Xcode installation is required.

---

## Features

### 1. Dual-Column Wallpaper Studio (Main Screen + Lock Screen & Saver)
- **Main Screen Column:** Drop or pick a video to run as your live, seamless-looping desktop wallpaper (`AVQueuePlayer` + `AVPlayerLooper`) behind your desktop icons and app windows across all Spaces.
- **Lock Screen & Saver Column:** Assign a separate (or the same) video for your **Lock Screen & Screen Saver**. LumaWall extracts a cropped high-resolution frame for the macOS Lock Screen (`NSWorkspace.shared.setDesktopImageURL`) and syncs it to `LumaWallSaver.saver`.
- **Local Library Strip:** Hover any saved video in the bottom strip to assign it directly to **Main** or **Lock** in one click, or remove it from your library.

### 2. Self-Contained Local Storage
- Imported videos are copied into `~/Library/Application Support/LumaWall/Videos/` and indexed in `library.json`.
- Even if you **delete, move, or rename the original video file** from Downloads or Desktop, LumaWall continues playing your wallpaper without interruption.

### 3. Automatic Black & White Border Removal (`Auto-Crop`)
- `BorderCropDetector` samples imported videos to detect baked-in black or white letterbox/pillarbox bars on all four edges.
- GPU-accelerated layer cropping & masking removes those borders in real time across the Studio preview, live desktop wallpaper, Lock Screen poster, and `LumaWallSaver.saver` (toggleable via **Auto-Crop**).

### 4. Native macOS Screen Saver (`LumaWallSaver.saver`)
- Click **Install Screen Saver** in the LumaWall header to install `LumaWallSaver.saver` into `~/Library/Screen Savers/` and open **System Settings**.
- To enable it in **System Settings → Wallpaper → Screen Saver...**:
  1. Set **Use Screen Saver** to **Custom**.
  2. Scroll to **Other → Show All** and select **LumaWallSaver**.
  3. Ensure **Start Screen Saver...** is shorter than your display sleep timer, then click **Done**.
- Trigger it anytime from the LumaWall menu bar icon (**Start Screen Saver Now**) or a macOS Hot Corner.

> **Note on the macOS Lock Screen:** macOS's `loginwindow` security shield blocks all third-party apps and screen savers from animating behind the password prompt itself. When your Mac is idle and the Screen Saver is active, `LumaWallSaver` plays your video live; when on the `loginwindow` password screen, macOS displays the synced high-resolution frame from your Lock Screen video, and LumaWall automatically resumes live desktop playback upon unlock or wake.

### 5. Playback & Display Controls
- **Play / Pause**, **Mute / Unmute** with volume slider, and **Playback Speed** (`0.5×`, `1×`, `1.5×`).
- **Scale Mode:** `Fill` or `Fit`.
- **All Displays:** Apply across all connected monitors or just the main display, with automatic screen-change handling.
- **Menu Bar App:** Closing the Studio window keeps your live wallpaper running; control playback, mute, screen saver, or reopen the Studio from the menu bar icon (`sparkles.tv`).

---

## Project Structure

```text
.
├── Sources/
│   ├── LumaWallApp.swift        # App lifecycle & Menu Bar status item
│   ├── ContentView.swift        # Obsidian Aurora dual-column SwiftUI interface
│   └── WallpaperEngine.swift    # Video engine, local storage, border detector, saver sync
├── ScreenSaver/
│   ├── LumaWallSaverView.swift  # Native ScreenSaverView bundle implementation
│   └── Info.plist
├── Info.plist                   # LumaWall.app bundle metadata
├── build.sh                     # Compiles LumaWall.app and LumaWallSaver.saver
└── install.sh                   # One-command build & /Applications installer
```

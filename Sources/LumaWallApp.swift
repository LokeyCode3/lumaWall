import AppKit
import SwiftUI
import Combine

@main
struct LumaWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "studio") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 600)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenuBarItem()
        _ = WallpaperEngine.shared

        // Style the main window for a sleek frameless glass feel
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                window.backgroundColor = .clear
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the live wallpaper running even when the Studio window is closed
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openStudioWindow()
        }
        return true
    }

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "LumaWall")
        }
        self.statusItem = item
        rebuildMenu()

        WallpaperEngine.shared.$activeWallpaper
            .combineLatest(WallpaperEngine.shared.$isPlaying, WallpaperEngine.shared.$isMuted)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        let engine = WallpaperEngine.shared
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open LumaWall Studio", action: #selector(openStudioWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        if let active = engine.activeWallpaper {
            let titleItem = NSMenuItem(title: "Playing: \(active.name)", action: nil, keyEquivalent: "")
            titleItem.isEnabled = false
            menu.addItem(titleItem)

            let playPauseTitle = engine.isPlaying ? "Pause Wallpaper" : "Resume Wallpaper"
            let playPauseItem = NSMenuItem(title: playPauseTitle, action: #selector(togglePlayPause), keyEquivalent: "p")
            playPauseItem.target = self
            menu.addItem(playPauseItem)

            let muteTitle = engine.isMuted ? "Unmute Audio" : "Mute Audio"
            let muteItem = NSMenuItem(title: muteTitle, action: #selector(toggleMute), keyEquivalent: "m")
            muteItem.target = self
            menu.addItem(muteItem)

            let clearItem = NSMenuItem(title: "Stop Wallpaper", action: #selector(clearWallpaper), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)

            menu.addItem(.separator())

            let startSaverItem = NSMenuItem(title: "Start Screen Saver Now", action: #selector(startScreenSaver), keyEquivalent: "")
            startSaverItem.target = self
            menu.addItem(startSaverItem)
        } else {
            let idleItem = NSMenuItem(title: "No Active Wallpaper", action: nil, keyEquivalent: "")
            idleItem.isEnabled = false
            menu.addItem(idleItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LumaWall", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func openStudioWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func togglePlayPause() {
        WallpaperEngine.shared.togglePlayPause()
    }

    @objc private func toggleMute() {
        WallpaperEngine.shared.toggleMute()
    }

    @objc private func clearWallpaper() {
        WallpaperEngine.shared.clearWallpaper()
    }

    @objc private func startScreenSaver() {
        WallpaperEngine.shared.startScreenSaverNow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

import AppKit
import AVFoundation
import Combine

enum WallpaperTarget {
    case main
    case lock
}

enum WallpaperScaleMode: String, CaseIterable, Identifiable, Codable {
    case fill = "Fill"
    case fit = "Fit"

    var id: String { rawValue }
}

struct CropInsets: Equatable, Codable {
    var top: CGFloat
    var bottom: CGFloat
    var left: CGFloat
    var right: CGFloat

    static let zero = CropInsets(top: 0, bottom: 0, left: 0, right: 0)

    var isZero: Bool {
        top < 0.005 && bottom < 0.005 && left < 0.005 && right < 0.005
    }
}

struct VideoEntry: Identifiable, Equatable, Codable {
    let id: String
    let storedFileName: String
    let displayName: String
    let fileExtension: String
    let posterFileName: String?
    var cropInsets: CropInsets?
    var isImage: Bool?

    var name: String { displayName }

    var mediaIsImage: Bool {
        if let isImage { return isImage }
        return ["jpg", "jpeg", "png", "heic", "webp", "tiff", "tif"].contains(fileExtension.lowercased())
    }

    var storedURL: URL {
        WallpaperEngine.videosDirectory.appendingPathComponent(storedFileName)
    }

    var posterURL: URL? {
        guard let posterFileName else { return nil }
        return WallpaperEngine.postersDirectory.appendingPathComponent(posterFileName)
    }
}

enum BorderCropDetector {
    /// Detects uniform black or white borders (letterbox/pillarbox) by sampling a CGImage.
    nonisolated static func detectInsets(in cgImage: CGImage) -> CropInsets {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 32, height >= 32 else { return .zero }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .zero
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func isBorderPixel(x: Int, y: Int) -> Bool {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            // Near-black or near-white with low saturation
            let isBlack = maxC <= 22
            let isWhite = minC >= 232 && (maxC - minC) <= 18
            return isBlack || isWhite
        }

        func isBorderRow(_ y: Int) -> Bool {
            let step = max(1, width / 64)
            var total = 0
            var borderCount = 0
            var x = 0
            while x < width {
                total += 1
                if isBorderPixel(x: x, y: y) { borderCount += 1 }
                x += step
            }
            return total > 0 && Double(borderCount) / Double(total) >= 0.96
        }

        func isBorderCol(_ x: Int) -> Bool {
            let step = max(1, height / 64)
            var total = 0
            var borderCount = 0
            var y = 0
            while y < height {
                total += 1
                if isBorderPixel(x: x, y: y) { borderCount += 1 }
                y += step
            }
            return total > 0 && Double(borderCount) / Double(total) >= 0.96
        }

        let maxVerticalCrop = Int(Double(height) * 0.40)
        let maxHorizontalCrop = Int(Double(width) * 0.40)

        var topPx = 0
        while topPx < maxVerticalCrop && isBorderRow(topPx) {
            topPx += 1
        }

        var bottomPx = 0
        while bottomPx < maxVerticalCrop && isBorderRow(height - 1 - bottomPx) {
            bottomPx += 1
        }

        var leftPx = 0
        while leftPx < maxHorizontalCrop && isBorderCol(leftPx) {
            leftPx += 1
        }

        var rightPx = 0
        while rightPx < maxHorizontalCrop && isBorderCol(width - 1 - rightPx) {
            rightPx += 1
        }

        let top = topPx > 2 ? CGFloat(topPx) / CGFloat(height) : 0
        let bottom = bottomPx > 2 ? CGFloat(bottomPx) / CGFloat(height) : 0
        let left = leftPx > 2 ? CGFloat(leftPx) / CGFloat(width) : 0
        let right = rightPx > 2 ? CGFloat(rightPx) / CGFloat(width) : 0

        // Guard against over-cropping an all-black or all-white frame
        if (top + bottom) >= 0.80 || (left + right) >= 0.80 {
            return .zero
        }

        return CropInsets(top: top, bottom: bottom, left: left, right: right)
    }

    nonisolated static func cropCGImage(_ cgImage: CGImage, insets: CropInsets) -> CGImage {
        guard !insets.isZero else { return cgImage }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let rect = CGRect(
            x: floor(insets.left * w),
            y: floor(insets.top * h),
            width: max(1, floor((1 - insets.left - insets.right) * w)),
            height: max(1, floor((1 - insets.top - insets.bottom) * h))
        )
        return cgImage.cropping(to: rect) ?? cgImage
    }
}

@MainActor
final class WallpaperEngine: ObservableObject {
    static let shared = WallpaperEngine()

    nonisolated static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LumaWall", isDirectory: true)
    }

    nonisolated static var videosDirectory: URL {
        appSupportDirectory.appendingPathComponent("Videos", isDirectory: true)
    }

    nonisolated static var postersDirectory: URL {
        appSupportDirectory.appendingPathComponent("Posters", isDirectory: true)
    }

    nonisolated private static var manifestURL: URL {
        appSupportDirectory.appendingPathComponent("library.json")
    }

    @Published var selectedVideo: VideoEntry?
    @Published var activeWallpaper: VideoEntry?
    @Published var selectedLockVideo: VideoEntry?
    @Published var lockScreenWallpaper: VideoEntry?
    @Published var recentVideos: [VideoEntry] = []
    @Published var thumbnails: [String: NSImage] = [:]

    @Published var isPlaying: Bool = true {
        didSet { syncPlaybackState() }
    }
    @Published var screenSaverStatus: String?
    @Published var isMuted: Bool = true {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Keys.isMuted)
            syncAudioState()
        }
    }
    @Published var volume: Float = 0.6 {
        didSet {
            UserDefaults.standard.set(volume, forKey: Keys.volume)
            syncAudioState()
        }
    }
    @Published var playbackRate: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: Keys.playbackRate)
            syncPlaybackState()
        }
    }
    @Published var scaleMode: WallpaperScaleMode = .fill {
        didSet {
            UserDefaults.standard.set(scaleMode.rawValue, forKey: Keys.scaleMode)
            layoutPlayerLayers()
            if let lockEntry = lockScreenWallpaper, isScreenSaverInstalled {
                syncScreenSaverBundle(with: lockEntry)
            }
        }
    }
    @Published var autoCropBorders: Bool = true {
        didSet {
            UserDefaults.standard.set(autoCropBorders, forKey: Keys.autoCropBorders)
            layoutPlayerLayers()
            if let lockEntry = lockScreenWallpaper, isScreenSaverInstalled {
                syncScreenSaverBundle(with: lockEntry)
            }
        }
    }
    @Published var applyToAllDisplays: Bool = true {
        didSet {
            UserDefaults.standard.set(applyToAllDisplays, forKey: Keys.allDisplays)
            if activeWallpaper != nil {
                rebuildWallpaperWindows()
            }
        }
    }
    @Published var syncLockScreen: Bool = true {
        didSet {
            UserDefaults.standard.set(syncLockScreen, forKey: Keys.syncLockScreen)
            if syncLockScreen, let active = activeWallpaper {
                syncSystemDesktopAndLockScreen(for: active)
            }
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLaunchAgent(enabled: launchAtLogin)
        }
    }

    private enum Keys {
        static let activeID = "lumawall.activeID"
        static let lockScreenID = "lumawall.lockScreenID"
        static let isMuted = "lumawall.isMuted"
        static let volume = "lumawall.volume"
        static let playbackRate = "lumawall.playbackRate"
        static let scaleMode = "lumawall.scaleMode"
        static let autoCropBorders = "lumawall.autoCropBorders"
        static let allDisplays = "lumawall.allDisplays"
        static let syncLockScreen = "lumawall.syncLockScreen"
        static let launchAtLogin = "lumawall.launchAtLogin"
    }

    private var wallpaperWindows: [NSWindow] = []
    private var playerLayers: [AVPlayerLayer] = []
    private var activeVideoNaturalSize: CGSize = CGSize(width: 1920, height: 1080)
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var observers: [NSObjectProtocol] = []

    private init() {
        ensureStorageDirectories()
        loadPreferences()
        registerSystemObservers()
    }

    private var isScreenLockedOrSaverActive = false

    private func registerSystemObservers() {
        let screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeWallpaper != nil else { return }
                self.rebuildWallpaperWindows()
            }
        }
        observers.append(screenObs)

        let willSleepObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pauseForLockOrSaver()
            }
        }
        observers.append(willSleepObs)

        let screensDidSleepObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pauseForLockOrSaver()
            }
        }
        observers.append(screensDidSleepObs)

        let wakeObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumeAfterUnlockOrWake()
            }
        }
        observers.append(wakeObs)

        let sessionObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLockedOrSaverActive = false
                self?.resumeAfterUnlockOrWake()
            }
        }
        observers.append(sessionObs)

        let lockObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLockedOrSaverActive = true
                self?.pauseForLockOrSaver()
            }
        }
        observers.append(lockObs)

        let unlockObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLockedOrSaverActive = false
                self?.resumeAfterUnlockOrWake()
            }
        }
        observers.append(unlockObs)

        let saverStartObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLockedOrSaverActive = true
                self?.pauseForLockOrSaver()
            }
        }
        observers.append(saverStartObs)

        let saverStopObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLockedOrSaverActive = false
                self?.resumeAfterUnlockOrWake()
            }
        }
        observers.append(saverStopObs)
    }

    private func pauseForLockOrSaver() {
        queuePlayer?.isMuted = true
        queuePlayer?.pause()
    }

    private func resumeAfterUnlockOrWake() {
        guard activeWallpaper != nil, !isScreenLockedOrSaverActive else { return }
        for window in wallpaperWindows {
            window.orderFrontRegardless()
        }
        syncAudioState()
        syncPlaybackState()
    }

    private func ensureStorageDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.appSupportDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.videosDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.postersDirectory, withIntermediateDirectories: true)
    }

    nonisolated static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    nonisolated static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tiff", "tif"]

    func addVideo(url: URL, target: WallpaperTarget = .main, setImmediately: Bool = false) {
        let sourceURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        ensureStorageDirectories()

        let id = UUID().uuidString
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension.lowercased()
        let isImageFile = Self.supportedImageExtensions.contains(ext)
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let storedFileName = "\(id).\(ext)"
        let destinationURL = Self.videosDirectory.appendingPathComponent(storedFileName)
        let posterFileName = "\(id).jpg"

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            return
        }

        let entry = VideoEntry(
            id: id,
            storedFileName: storedFileName,
            displayName: displayName,
            fileExtension: ext.uppercased(),
            posterFileName: posterFileName,
            cropInsets: nil,
            isImage: isImageFile
        )

        switch target {
        case .main:
            selectedVideo = entry
        case .lock:
            selectedLockVideo = entry
        }

        recentVideos.insert(entry, at: 0)
        if recentVideos.count > 20 {
            let removed = Array(recentVideos.dropFirst(20))
            recentVideos = Array(recentVideos.prefix(20))
            for old in removed where old.id != activeWallpaper?.id && old.id != lockScreenWallpaper?.id {
                deleteStoredFiles(for: old)
            }
        }
        saveLibrary()
        generateAssets(for: entry, applyPosterIfActive: setImmediately)

        if setImmediately {
            switch target {
            case .main:
                applyWallpaper(entry)
            case .lock:
                applyLockScreenWallpaper(entry)
            }
        }
    }

    func removeRecentVideo(_ entry: VideoEntry) {
        if activeWallpaper?.id == entry.id {
            clearWallpaper()
        }
        if lockScreenWallpaper?.id == entry.id {
            clearLockScreenWallpaper()
        }
        recentVideos.removeAll { $0.id == entry.id }
        deleteStoredFiles(for: entry)
        thumbnails.removeValue(forKey: entry.id)
        saveLibrary()

        if selectedVideo?.id == entry.id {
            selectedVideo = recentVideos.first
        }
        if selectedLockVideo?.id == entry.id {
            selectedLockVideo = recentVideos.first
        }
    }

    func applyWallpaper(_ entry: VideoEntry) {
        guard !entry.mediaIsImage else {
            // Images belong to Lock Screen; if applied directly, route to Lock Screen
            applyLockScreenWallpaper(entry)
            return
        }
        guard FileManager.default.fileExists(atPath: entry.storedURL.path) else { return }
        activeWallpaper = entry
        selectedVideo = entry
        isPlaying = true
        UserDefaults.standard.set(entry.id, forKey: Keys.activeID)

        setupPlayer(for: entry.storedURL)
        rebuildWallpaperWindows()
        loadNaturalSize(for: entry.storedURL)

        if entry.cropInsets == nil {
            generateAssets(for: entry, applyPosterIfActive: false)
        }
    }

    func applyLockScreenWallpaper(_ entry: VideoEntry) {
        guard FileManager.default.fileExists(atPath: entry.storedURL.path) else { return }
        lockScreenWallpaper = entry
        selectedLockVideo = entry
        UserDefaults.standard.set(entry.id, forKey: Keys.lockScreenID)

        if entry.cropInsets == nil {
            generateAssets(for: entry, applyPosterIfActive: true)
        } else {
            syncSystemDesktopAndLockScreen(for: entry)
            if isScreenSaverInstalled {
                syncScreenSaverBundle(with: entry)
            }
        }
    }

    func clearLockScreenWallpaper() {
        lockScreenWallpaper = nil
        UserDefaults.standard.removeObject(forKey: Keys.lockScreenID)
    }

    var isScreenSaverInstalled: Bool {
        FileManager.default.fileExists(atPath: installedScreenSaverURL.path)
    }

    private var installedScreenSaverURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library
            .appendingPathComponent("Screen Savers", isDirectory: true)
            .appendingPathComponent("LumaWallSaver.saver", isDirectory: true)
    }

    func installAndOpenScreenSaver() {
        let targetEntry = lockScreenWallpaper ?? selectedLockVideo ?? activeWallpaper ?? selectedVideo
        guard let entry = targetEntry else {
            screenSaverStatus = "Select a Lock Screen video first"
            return
        }

        syncScreenSaverBundle(with: entry)
        screenSaverStatus = "Installed! Select LumaWallSaver in System Settings"

        // Open System Settings -> Screen Saver so the user can pick LumaWallSaver once
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    func startScreenSaverNow() {
        if let entry = lockScreenWallpaper ?? selectedLockVideo ?? activeWallpaper ?? selectedVideo {
            syncScreenSaverBundle(with: entry)
        }
        let saverEngine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: saverEngine, configuration: NSWorkspace.OpenConfiguration())
    }

    private func syncScreenSaverBundle(with entry: VideoEntry) {
        let fm = FileManager.default

        // Install LumaWallSaver.saver ONLY if it doesn't exist yet (never modify/re-sign in place,
        // because changing its code signature causes macOS to reset Custom Screen Saver to Monterey/Automatic).
        let destURL = installedScreenSaverURL
        if !fm.fileExists(atPath: destURL.path),
           let templateURL = Bundle.main.url(forResource: "LumaWallSaver", withExtension: "saver") {
            let parentDir = destURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: templateURL, to: destURL)
        }

        struct SaverConfigPayload: Codable {
            var videoFileName: String
            var isImage: Bool
            var scaleMode: String
            var autoCropBorders: Bool
            var top: CGFloat
            var bottom: CGFloat
            var left: CGFloat
            var right: CGFloat
            var isMuted: Bool
            var playbackRate: Float
        }

        let ext = entry.storedURL.pathExtension.isEmpty ? "mp4" : entry.storedURL.pathExtension.lowercased()
        let activeVideoName = "active_video.\(ext)"
        let insets = entry.cropInsets ?? .zero
        let payload = SaverConfigPayload(
            videoFileName: activeVideoName,
            isImage: entry.mediaIsImage,
            scaleMode: scaleMode.rawValue,
            autoCropBorders: autoCropBorders,
            top: insets.top,
            bottom: insets.bottom,
            left: insets.left,
            right: insets.right,
            isMuted: isMuted,
            playbackRate: playbackRate
        )

        guard let configData = try? JSONEncoder().encode(payload) else { return }

        // Write media + config into Application Support AND legacyScreenSaver's sandbox container
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let targetDirs: [URL] = [
            Self.appSupportDirectory.appendingPathComponent("Saver", isDirectory: true),
            library.appendingPathComponent("Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/LumaWall/Saver", isDirectory: true)
        ]

        for dir in targetDirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items where item.lastPathComponent.hasPrefix("active_video.") {
                    try? fm.removeItem(at: item)
                }
            }

            let destMediaURL = dir.appendingPathComponent(activeVideoName)
            // Hardlink first (instant, 0 extra disk space), fallback to copy
            if (try? fm.linkItem(at: entry.storedURL, to: destMediaURL)) == nil {
                try? fm.copyItem(at: entry.storedURL, to: destMediaURL)
            }

            let configURL = dir.appendingPathComponent("saver_config.json")
            try? configData.write(to: configURL, options: .atomic)
        }
    }

    func clearWallpaper() {
        activeWallpaper = nil
        UserDefaults.standard.removeObject(forKey: Keys.activeID)
        teardownWindows()
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer = nil
    }

    func togglePlayPause() {
        guard activeWallpaper != nil else { return }
        isPlaying.toggle()
    }

    func toggleMute() {
        isMuted.toggle()
    }

    private func deleteStoredFiles(for entry: VideoEntry) {
        try? FileManager.default.removeItem(at: entry.storedURL)
        if let posterURL = entry.posterURL {
            try? FileManager.default.removeItem(at: posterURL)
        }
    }

    private func syncSystemDesktopAndLockScreen(for entry: VideoEntry) {
        guard let posterURL = entry.posterURL else { return }
        if FileManager.default.fileExists(atPath: posterURL.path) {
            setSystemWallpaperImage(at: posterURL)
        } else {
            generateAssets(for: entry, applyPosterIfActive: true)
        }
    }

    private func setSystemWallpaperImage(at imageURL: URL) {
        let screens = applyToAllDisplays ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens.first].compactMap { $0 }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: scaleMode == .fill
        ]
        for screen in screens {
            try? NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
        }
    }

    private func loadNaturalSize(for url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let size = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let transformed = size.applying(transform)
            let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            guard displaySize.width > 0, displaySize.height > 0 else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeVideoNaturalSize = displaySize
                self.layoutPlayerLayers()
            }
        }
    }

    private func setupPlayer(for url: URL) {
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer?.pause()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false

        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.queuePlayer = player
        self.playerLooper = looper

        syncAudioState()
        syncPlaybackState()
    }

    private func rebuildWallpaperWindows() {
        teardownWindows()
        guard let player = queuePlayer else { return }

        let targetScreens: [NSScreen]
        if applyToAllDisplays {
            targetScreens = NSScreen.screens
        } else if let main = NSScreen.main ?? NSScreen.screens.first {
            targetScreens = [main]
        } else {
            targetScreens = []
        }

        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

        for screen in targetScreens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = desktopLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false

            let hostView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = NSColor.black.cgColor
            hostView.layer?.masksToBounds = true

            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resize

            hostView.layer?.addSublayer(playerLayer)
            window.contentView = hostView
            window.orderFrontRegardless()

            wallpaperWindows.append(window)
            playerLayers.append(playerLayer)
        }

        layoutPlayerLayers()
    }

    static func layout(
        playerLayer: AVPlayerLayer,
        in containerBounds: CGRect,
        naturalSize: CGSize,
        insets: CropInsets,
        scaleMode: WallpaperScaleMode
    ) {
        guard containerBounds.width > 0, containerBounds.height > 0,
              naturalSize.width > 0, naturalSize.height > 0 else { return }

        let cropW = max(1, naturalSize.width * (1 - insets.left - insets.right))
        let cropH = max(1, naturalSize.height * (1 - insets.top - insets.bottom))

        let scale: CGFloat
        switch scaleMode {
        case .fill:
            scale = max(containerBounds.width / cropW, containerBounds.height / cropH)
        case .fit:
            scale = min(containerBounds.width / cropW, containerBounds.height / cropH)
        }

        let fullW = naturalSize.width * scale
        let fullH = naturalSize.height * scale

        let cropCenterX = naturalSize.width * (insets.left + (1 - insets.left - insets.right) / 2)
        let cropCenterY = naturalSize.height * (insets.bottom + (1 - insets.top - insets.bottom) / 2)

        let originX = containerBounds.width / 2 - cropCenterX * scale
        let originY = containerBounds.height / 2 - cropCenterY * scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = .resize
        playerLayer.frame = CGRect(x: originX, y: originY, width: fullW, height: fullH)

        if !insets.isZero {
            let maskLayer = CAShapeLayer()
            maskLayer.path = CGPath(
                rect: CGRect(
                    x: insets.left * fullW,
                    y: insets.bottom * fullH,
                    width: cropW * scale,
                    height: cropH * scale
                ),
                transform: nil
            )
            playerLayer.mask = maskLayer
        } else {
            playerLayer.mask = nil
        }
        CATransaction.commit()
    }

    private func layoutPlayerLayers() {
        let insets = autoCropBorders ? (activeWallpaper?.cropInsets ?? .zero) : .zero
        for (index, layer) in playerLayers.enumerated() {
            guard index < wallpaperWindows.count,
                  let bounds = wallpaperWindows[index].contentView?.bounds else { continue }
            Self.layout(
                playerLayer: layer,
                in: bounds,
                naturalSize: activeVideoNaturalSize,
                insets: insets,
                scaleMode: scaleMode
            )
        }
    }

    private func teardownWindows() {
        for window in wallpaperWindows {
            window.orderOut(nil)
            window.close()
        }
        wallpaperWindows.removeAll()
        playerLayers.removeAll()
    }

    private func syncPlaybackState() {
        guard let player = queuePlayer else { return }
        if isPlaying {
            player.play()
            player.rate = playbackRate
        } else {
            player.pause()
        }
    }

    private func syncAudioState() {
        guard let player = queuePlayer else { return }
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : volume
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.isMuted) != nil {
            isMuted = defaults.bool(forKey: Keys.isMuted)
        }
        if defaults.object(forKey: Keys.volume) != nil {
            volume = defaults.float(forKey: Keys.volume)
        }
        if defaults.object(forKey: Keys.playbackRate) != nil {
            let savedRate = defaults.float(forKey: Keys.playbackRate)
            playbackRate = savedRate > 0 ? savedRate : 1.0
        }
        if let modeRaw = defaults.string(forKey: Keys.scaleMode),
           let mode = WallpaperScaleMode(rawValue: modeRaw) {
            scaleMode = mode
        }
        if defaults.object(forKey: Keys.autoCropBorders) != nil {
            autoCropBorders = defaults.bool(forKey: Keys.autoCropBorders)
        }
        if defaults.object(forKey: Keys.allDisplays) != nil {
            applyToAllDisplays = defaults.bool(forKey: Keys.allDisplays)
        }
        if defaults.object(forKey: Keys.syncLockScreen) != nil {
            syncLockScreen = defaults.bool(forKey: Keys.syncLockScreen)
        }
        launchAtLogin = FileManager.default.fileExists(atPath: Self.launchAgentURL.path)

        if let data = try? Data(contentsOf: Self.manifestURL),
           let decoded = try? JSONDecoder().decode([VideoEntry].self, from: data) {
            recentVideos = decoded.filter { FileManager.default.fileExists(atPath: $0.storedURL.path) }
        }

        for entry in recentVideos {
            generateAssets(for: entry, applyPosterIfActive: false)
        }

        selectedVideo = recentVideos.first
        selectedLockVideo = recentVideos.first

        if let activeID = defaults.string(forKey: Keys.activeID),
           let activeEntry = recentVideos.first(where: { $0.id == activeID }) {
            applyWallpaper(activeEntry)
        }

        if let lockID = defaults.string(forKey: Keys.lockScreenID),
           let lockEntry = recentVideos.first(where: { $0.id == lockID }) {
            // Restore Lock Screen state without re-invoking setDesktopImageURL on every launch
            // (calling setDesktopImageURL resets macOS's Custom Screen Saver back to Automatic).
            lockScreenWallpaper = lockEntry
            selectedLockVideo = lockEntry
        }
    }

    private static var launchAgentURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.local.LumaWall.plist")
    }

    private func updateLaunchAgent(enabled: Bool) {
        let url = Self.launchAgentURL
        let fm = FileManager.default
        if !enabled {
            try? fm.removeItem(at: url)
            return
        }

        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let appsExec = "/Applications/LumaWall.app/Contents/MacOS/LumaWall"
        let execPath = fm.fileExists(atPath: appsExec)
            ? appsExec
            : (Bundle.main.executablePath ?? appsExec)

        let plist: [String: Any] = [
            "Label": "com.local.LumaWall",
            "ProgramArguments": [execPath, "--background"],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(recentVideos) {
            try? data.write(to: Self.manifestURL, options: .atomic)
        }
    }

    private func generateAssets(for entry: VideoEntry, applyPosterIfActive: Bool) {
        let videoURL = entry.storedURL
        let posterURL = entry.posterURL
        let entryID = entry.id
        let isImageFile = entry.mediaIsImage

        if entry.cropInsets != nil,
           let posterURL, FileManager.default.fileExists(atPath: posterURL.path),
           let existing = NSImage(contentsOf: posterURL) {
            thumbnails[entryID] = existing
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let rawCGImage: CGImage?
            if isImageFile {
                if let nsImg = NSImage(contentsOf: videoURL) {
                    var rect = NSRect(origin: .zero, size: nsImg.size)
                    rawCGImage = nsImg.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                } else {
                    rawCGImage = nil
                }
            } else {
                let asset = AVURLAsset(url: videoURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceAfter = .zero
                generator.requestedTimeToleranceBefore = .zero

                let time = CMTime(seconds: 1.0, preferredTimescale: 600)
                let fallbackTime = CMTime(seconds: 0.0, preferredTimescale: 600)

                if let img = try? await generator.image(at: time).image {
                    rawCGImage = img
                } else {
                    rawCGImage = try? await generator.image(at: fallbackTime).image
                }
            }

            guard let rawCGImage else { return }

            let detectedInsets = BorderCropDetector.detectInsets(in: rawCGImage)
            let croppedCGImage = BorderCropDetector.cropCGImage(rawCGImage, insets: detectedInsets)

            if let posterURL {
                let rep = NSBitmapImageRep(cgImage: croppedCGImage)
                if let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                    try? jpegData.write(to: posterURL, options: .atomic)
                }
            }

            let nsImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height))
            await MainActor.run { [weak self] in
                guard let engine = self else { return }
                engine.thumbnails[entryID] = nsImage

                if let idx = engine.recentVideos.firstIndex(where: { $0.id == entryID }) {
                    engine.recentVideos[idx].cropInsets = detectedInsets
                    engine.saveLibrary()
                }
                if engine.selectedVideo?.id == entryID {
                    engine.selectedVideo?.cropInsets = detectedInsets
                }
                if engine.selectedLockVideo?.id == entryID {
                    engine.selectedLockVideo?.cropInsets = detectedInsets
                }
                if engine.activeWallpaper?.id == entryID {
                    engine.activeWallpaper?.cropInsets = detectedInsets
                    engine.layoutPlayerLayers()
                }
                if engine.lockScreenWallpaper?.id == entryID {
                    engine.lockScreenWallpaper?.cropInsets = detectedInsets
                    if applyPosterIfActive, let posterURL {
                        engine.setSystemWallpaperImage(at: posterURL)
                    }
                    if engine.isScreenSaverInstalled, let lockEntry = engine.lockScreenWallpaper {
                        engine.syncScreenSaverBundle(with: lockEntry)
                    }
                }
            }
        }
    }
}

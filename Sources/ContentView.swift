import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct VisualEffectGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct LoopPreviewPlayerView: NSViewRepresentable {
    let url: URL
    let scaleMode: WallpaperScaleMode
    let cropInsets: CropInsets

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = PreviewContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true

        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resize
        container.layer?.addSublayer(playerLayer)

        context.coordinator.container = container
        context.coordinator.playerLayer = playerLayer
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.applyLayout()
        }
        context.coordinator.load(url: url, scaleMode: scaleMode, cropInsets: cropInsets)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scaleMode = scaleMode
        context.coordinator.cropInsets = cropInsets
        if context.coordinator.currentURL != url {
            context.coordinator.load(url: url, scaleMode: scaleMode, cropInsets: cropInsets)
        } else {
            context.coordinator.applyLayout()
        }
    }

    final class PreviewContainerView: NSView {
        var onLayout: (() -> Void)?
        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    final class Coordinator {
        weak var container: NSView?
        var playerLayer: AVPlayerLayer?
        var queuePlayer: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var currentURL: URL?
        var naturalSize: CGSize = CGSize(width: 16, height: 9)
        var scaleMode: WallpaperScaleMode = .fill
        var cropInsets: CropInsets = .zero

        func load(url: URL, scaleMode: WallpaperScaleMode, cropInsets: CropInsets) {
            currentURL = url
            self.scaleMode = scaleMode
            self.cropInsets = cropInsets

            looper?.disableLooping()
            looper = nil
            queuePlayer?.pause()

            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.actionAtItemEnd = .none
            let looper = AVPlayerLooper(player: player, templateItem: item)

            self.queuePlayer = player
            self.looper = looper
            self.playerLayer?.player = player
            player.play()

            Task {
                guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
                let size = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let transformed = size.applying(transform)
                let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                guard displaySize.width > 0, displaySize.height > 0 else { return }
                await MainActor.run {
                    self.naturalSize = displaySize
                    self.applyLayout()
                }
            }
        }

        @MainActor
        func applyLayout() {
            guard let container, let playerLayer else { return }
            WallpaperEngine.layout(
                playerLayer: playerLayer,
                in: container.bounds,
                naturalSize: naturalSize,
                insets: cropInsets,
                scaleMode: scaleMode
            )
        }

        deinit {
            looper?.disableLooping()
            queuePlayer?.pause()
        }
    }
}

@MainActor
final class StudioUIState: ObservableObject {
    @Published var isMainDropTargeted = false
    @Published var isLockDropTargeted = false
    @Published var hoveredRecentID: String?
}

struct ContentView: View {
    @ObservedObject var engine = WallpaperEngine.shared
    @ObservedObject private var uiState = StudioUIState()

    private let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    var body: some View {
        ZStack {
            VisualEffectGlass(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Subtle Obsidian Aurora ambient glow
            ZStack {
                Circle()
                    .fill(Color(red: 0.13, green: 0.83, blue: 0.93).opacity(0.14))
                    .frame(width: 340, height: 340)
                    .blur(radius: 80)
                    .offset(x: -220, y: -150)

                Circle()
                    .fill(Color(red: 0.55, green: 0.36, blue: 0.96).opacity(0.16))
                    .frame(width: 360, height: 360)
                    .blur(radius: 90)
                    .offset(x: 220, y: 120)
            }
            .allowsHitTesting(false)

            VStack(spacing: 16) {
                headerBar
                twoColumnStage
                controlsDock
                if !engine.recentVideos.isEmpty {
                    recentStrip
                }
            }
            .padding(20)
        }
        .frame(minWidth: 800, minHeight: 580)
        .preferredColorScheme(.dark)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let logoURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
               let logoImage = NSImage(contentsOf: logoURL) {
                Image(nsImage: logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: Color(red: 0.66, green: 0.33, blue: 0.97).opacity(0.45), radius: 8, y: 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.13, green: 0.83, blue: 0.93),
                                    Color(red: 0.55, green: 0.36, blue: 0.96)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "sparkles.tv.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("LumaWall")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Dual-Screen Video Wallpaper Studio")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            Button(action: { engine.installAndOpenScreenSaver() }) {
                Label(engine.isScreenSaverInstalled ? "Sync Screen Saver" : "Install Screen Saver", systemImage: "moon.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Install & sync LumaWallSaver in ~/Library/Screen Savers")
        }
    }

    private var twoColumnStage: some View {
        HStack(spacing: 16) {
            wallpaperColumn(
                target: .main,
                title: "Main Screen",
                subtitle: "Live Desktop Wallpaper",
                icon: "desktopcomputer",
                accentStart: Color(red: 0.13, green: 0.83, blue: 0.93),
                accentEnd: Color(red: 0.39, green: 0.40, blue: 0.95),
                selectedEntry: engine.selectedVideo ?? engine.activeWallpaper,
                activeEntry: engine.activeWallpaper,
                statusText: engine.activeWallpaper != nil ? (engine.isPlaying ? "LIVE" : "PAUSED") : "IDLE",
                statusColor: engine.activeWallpaper != nil ? (engine.isPlaying ? Color(red: 0.2, green: 0.9, blue: 0.6) : .orange) : .white.opacity(0.3),
                isDropTargeted: $uiState.isMainDropTargeted
            )

            wallpaperColumn(
                target: .lock,
                title: "Lock Screen & Saver",
                subtitle: "Screen Saver Video + Lock Frame",
                icon: "lock.desktopcomputer",
                accentStart: Color(red: 0.66, green: 0.33, blue: 0.97),
                accentEnd: Color(red: 0.93, green: 0.28, blue: 0.60),
                selectedEntry: engine.selectedLockVideo ?? engine.lockScreenWallpaper,
                activeEntry: engine.lockScreenWallpaper,
                statusText: engine.lockScreenWallpaper != nil ? "SYNCED" : "IDLE",
                statusColor: engine.lockScreenWallpaper != nil ? Color(red: 0.75, green: 0.52, blue: 0.99) : .white.opacity(0.3),
                isDropTargeted: $uiState.isLockDropTargeted
            )
        }
        .frame(maxWidth: .infinity, minHeight: 270, maxHeight: .infinity)
    }

    private func wallpaperColumn(
        target: WallpaperTarget,
        title: String,
        subtitle: String,
        icon: String,
        accentStart: Color,
        accentEnd: Color,
        selectedEntry: VideoEntry?,
        activeEntry: VideoEntry?,
        statusText: String,
        statusColor: Color,
        isDropTargeted: Binding<Bool>
    ) -> some View {
        VStack(spacing: 10) {
            // Column Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accentStart)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())

                Button(action: { pickVideoFile(for: target) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Choose a video for \(title)")
            }

            // Stage Preview / Drop Zone
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                isDropTargeted.wrappedValue
                                    ? AnyShapeStyle(accentStart)
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    ),
                                lineWidth: isDropTargeted.wrappedValue ? 2 : 1
                            )
                    )

                if let video = selectedEntry {
                    ZStack(alignment: .bottom) {
                        if video.mediaIsImage,
                           let img = engine.thumbnails[video.id] ?? NSImage(contentsOf: video.storedURL) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: engine.scaleMode == .fill ? .fill : .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .padding(1)
                        } else {
                            LoopPreviewPlayerView(
                                url: video.storedURL,
                                scaleMode: engine.scaleMode,
                                cropInsets: engine.autoCropBorders ? (video.cropInsets ?? .zero) : .zero
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .padding(1)
                        }

                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.84)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.name)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                    .lineLimit(1)

                                Text("Stored locally • \(video.fileExtension)")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.white.opacity(0.55))
                            }

                            Spacer()

                            if activeEntry != nil {
                                Button(action: {
                                    if target == .main {
                                        engine.clearWallpaper()
                                    } else {
                                        engine.clearLockScreenWallpaper()
                                    }
                                }) {
                                    Text("Stop")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.85))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.14))
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            let isCurrentActive = activeEntry?.id == video.id
                            Button(action: {
                                if target == .main {
                                    engine.applyWallpaper(video)
                                } else {
                                    engine.applyLockScreenWallpaper(video)
                                }
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: isCurrentActive ? "checkmark.circle.fill" : "sparkles")
                                    Text(isCurrentActive ? "Active" : (target == .main ? "Set Main" : "Set Lock"))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(
                                    LinearGradient(
                                        colors: isCurrentActive
                                            ? [Color(red: 0.16, green: 0.72, blue: 0.52), Color(red: 0.10, green: 0.58, blue: 0.45)]
                                            : [accentStart, accentEnd],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                    }
                } else {
                    Button(action: { pickVideoFile(for: target) }) {
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.07))
                                    .frame(width: 52, height: 52)
                                Image(systemName: icon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [accentStart, accentEnd],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }

                            VStack(spacing: 3) {
                                Text(target == .main ? "Drop \(title) video" : "Drop Lock Screen video or image")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(target == .main ? "or click to browse (MP4, MOV, M4V)" : "or click to browse (MP4, MOV, JPG, PNG, HEIC)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: isDropTargeted) { providers in
                handleDrop(providers: providers, target: target)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.24))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var controlsDock: some View {
        HStack(spacing: 12) {
            Button(action: { engine.togglePlayPause() }) {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(engine.activeWallpaper == nil ? 0.05 : 0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(engine.activeWallpaper == nil)
            .opacity(engine.activeWallpaper == nil ? 0.45 : 1)
            .help("Play / Pause Main Screen Wallpaper")

            HStack(spacing: 6) {
                Button(action: { engine.toggleMute() }) {
                    Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(engine.isMuted ? "Unmute Audio" : "Mute Audio")

                if !engine.isMuted {
                    Slider(value: $engine.volume, in: 0...1)
                        .frame(width: 68)
                        .tint(Color(red: 0.13, green: 0.83, blue: 0.93))
                }
            }

            Divider().frame(height: 18).opacity(0.25)

            HStack(spacing: 3) {
                ForEach([Float(0.5), Float(1.0), Float(1.5)], id: \.self) { rate in
                    let label = rate == 1.0 ? "1×" : (rate == 0.5 ? "0.5×" : "1.5×")
                    Button(action: { engine.playbackRate = rate }) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(engine.playbackRate == rate ? Color.white.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 18).opacity(0.25)

            HStack(spacing: 3) {
                ForEach(WallpaperScaleMode.allCases) { mode in
                    Button(action: { engine.scaleMode = mode }) {
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(engine.scaleMode == mode ? Color.white.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Toggle(isOn: $engine.autoCropBorders) {
                Text("Auto-Crop")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Automatically remove black or white borders from videos")

            Toggle(isOn: $engine.applyToAllDisplays) {
                Text("All Displays")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $engine.launchAtLogin) {
                Text("Login")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Start LumaWall automatically in the background when you log in")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.32))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOCAL LIBRARY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text("Hover a video to assign to Main or Lock Screen")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.38))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(engine.recentVideos) { entry in
                        recentCard(for: entry)
                    }
                }
            }
        }
    }

    private func recentCard(for entry: VideoEntry) -> some View {
        let isMainActive = engine.activeWallpaper?.id == entry.id
        let isLockActive = engine.lockScreenWallpaper?.id == entry.id
        let isHovered = uiState.hoveredRecentID == entry.id

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomLeading) {
                    if let thumb = engine.thumbnails[entry.id] {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Image(systemName: "film")
                                    .foregroundColor(.white.opacity(0.4))
                            )
                    }

                    if isHovered {
                        HStack(spacing: 4) {
                            if !entry.mediaIsImage {
                                Button(action: { engine.applyWallpaper(entry) }) {
                                    Text("Main")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(red: 0.13, green: 0.75, blue: 0.90))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            Button(action: { engine.applyLockScreenWallpaper(entry) }) {
                                Text("Lock")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color(red: 0.66, green: 0.33, blue: 0.97))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(5)
                    }
                }
                .frame(width: 124, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            isMainActive
                                ? Color(red: 0.13, green: 0.83, blue: 0.93)
                                : (isLockActive ? Color(red: 0.66, green: 0.33, blue: 0.97) : Color.white.opacity(0.12)),
                            lineWidth: (isMainActive || isLockActive) ? 2 : 1
                        )
                )

                Text(entry.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity((isMainActive || isLockActive) ? 0.95 : 0.7))
                    .lineLimit(1)
                    .frame(width: 124, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                engine.selectedVideo = entry
            }

            if isHovered {
                Button(action: { engine.removeRecentVideo(entry) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.85))
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .offset(x: -4, y: 4)
            }
        }
        .onHover { hovering in
            uiState.hoveredRecentID = hovering ? entry.id : nil
        }
    }

    private func pickVideoFile(for target: WallpaperTarget) {
        let panel = NSOpenPanel()
        panel.title = target == .main ? "Choose Main Screen Video" : "Choose Lock Screen Video or Image"
        panel.allowedContentTypes = target == .main
            ? [.mpeg4Movie, .quickTimeMovie, .movie]
            : [.mpeg4Movie, .quickTimeMovie, .movie, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            engine.addVideo(url: url, target: target, setImmediately: true)
        }
    }

    private func handleDrop(providers: [NSItemProvider], target: WallpaperTarget) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let ext = url.pathExtension.lowercased()
            let allowed = target == .main
                ? WallpaperEngine.supportedVideoExtensions
                : WallpaperEngine.supportedVideoExtensions.union(WallpaperEngine.supportedImageExtensions)
            guard allowed.contains(ext) else { return }

            Task { @MainActor in
                engine.addVideo(url: url, target: target, setImmediately: true)
            }
        }
        return true
    }
}

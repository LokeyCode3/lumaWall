import ScreenSaver
import AVFoundation
import AppKit

private struct SaverConfig: Codable {
    var videoFileName: String
    var isImage: Bool?
    var scaleMode: String
    var autoCropBorders: Bool
    var top: CGFloat
    var bottom: CGFloat
    var left: CGFloat
    var right: CGFloat
    var isMuted: Bool
    var playbackRate: Float
}

@objc(LumaWallSaverView)
final class LumaWallSaverView: ScreenSaverView {
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?
    private var naturalSize: CGSize = CGSize(width: 1920, height: 1080)
    private var config: SaverConfig?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        loadVideo()
    }

    private func resolveSaverDirectory() -> URL? {
        let fm = FileManager.default
        // Inside legacyScreenSaver's sandbox, FileManager.homeDirectoryForCurrentUser points to the container;
        // getpwuid(getuid()) gives the real user home directory (/Users/<name>).
        if let pw = getpwuid(getuid()), let homePtr = pw.pointee.pw_dir {
            let realHome = URL(fileURLWithPath: String(cString: homePtr), isDirectory: true)
            let realSaver = realHome.appendingPathComponent("Library/Application Support/LumaWall/Saver", isDirectory: true)
            if fm.fileExists(atPath: realSaver.appendingPathComponent("saver_config.json").path) {
                return realSaver
            }
        }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let saverDir = appSupport.appendingPathComponent("LumaWall/Saver", isDirectory: true)
            if fm.fileExists(atPath: saverDir.appendingPathComponent("saver_config.json").path) {
                return saverDir
            }
        }
        return Bundle(for: LumaWallSaverView.self).resourceURL
    }

    private func loadVideo() {
        guard let resourcesURL = resolveSaverDirectory() else { return }
        let configURL = resourcesURL.appendingPathComponent("saver_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(SaverConfig.self, from: data) else {
            return
        }

        let videoURL = resourcesURL.appendingPathComponent(decoded.videoFileName)
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return }

        self.config = decoded

        if decoded.isImage == true, let nsImage = NSImage(contentsOf: videoURL) {
            var rect = NSRect(origin: .zero, size: nsImage.size)
            if let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                let imgLayer = CALayer()
                imgLayer.contents = cgImage
                imgLayer.frame = bounds
                imgLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                imgLayer.contentsGravity = decoded.scaleMode == "Fill" ? .resizeAspectFill : .resizeAspect
                layer?.addSublayer(imgLayer)
                self.imageLayer = imgLayer
            }
            return
        }

        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer()
        player.isMuted = decoded.isMuted || isPreview
        player.actionAtItemEnd = .none

        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.queuePlayer = player
        self.playerLooper = looper

        let pLayer = AVPlayerLayer(player: player)
        pLayer.videoGravity = .resize
        layer?.addSublayer(pLayer)
        self.playerLayer = pLayer

        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let size = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let transformed = size.applying(transform)
            let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            guard displaySize.width > 0, displaySize.height > 0 else { return }
            await MainActor.run {
                self.naturalSize = displaySize
                self.layoutVideoLayer()
            }
        }
    }

    override func layout() {
        super.layout()
        imageLayer?.frame = bounds
        layoutVideoLayer()
    }

    private func layoutVideoLayer() {
        guard let pLayer = playerLayer,
              bounds.width > 0, bounds.height > 0,
              naturalSize.width > 0, naturalSize.height > 0 else { return }

        let useCrop = config?.autoCropBorders ?? true
        let left = useCrop ? (config?.left ?? 0) : 0
        let right = useCrop ? (config?.right ?? 0) : 0
        let top = useCrop ? (config?.top ?? 0) : 0
        let bottom = useCrop ? (config?.bottom ?? 0) : 0
        let isFill = (config?.scaleMode ?? "Fill") == "Fill"

        let cropW = max(1, naturalSize.width * (1 - left - right))
        let cropH = max(1, naturalSize.height * (1 - top - bottom))
        let scale = isFill
            ? max(bounds.width / cropW, bounds.height / cropH)
            : min(bounds.width / cropW, bounds.height / cropH)

        let fullW = naturalSize.width * scale
        let fullH = naturalSize.height * scale
        let cropCenterX = naturalSize.width * (left + (1 - left - right) / 2)
        let cropCenterY = naturalSize.height * (bottom + (1 - top - bottom) / 2)

        let originX = bounds.width / 2 - cropCenterX * scale
        let originY = bounds.height / 2 - cropCenterY * scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pLayer.videoGravity = .resize
        pLayer.frame = CGRect(x: originX, y: originY, width: fullW, height: fullH)
        if left > 0.005 || right > 0.005 || top > 0.005 || bottom > 0.005 {
            let maskLayer = CAShapeLayer()
            maskLayer.path = CGPath(
                rect: CGRect(x: left * fullW, y: bottom * fullH, width: cropW * scale, height: cropH * scale),
                transform: nil
            )
            pLayer.mask = maskLayer
        } else {
            pLayer.mask = nil
        }
        CATransaction.commit()
    }

    override func startAnimation() {
        super.startAnimation()
        queuePlayer?.isMuted = (config?.isMuted ?? true) || isPreview
        queuePlayer?.play()
        if let rate = config?.playbackRate, rate > 0 {
            queuePlayer?.rate = rate
        }
    }

    override func stopAnimation() {
        queuePlayer?.isMuted = true
        queuePlayer?.pause()
        super.stopAnimation()
    }
}

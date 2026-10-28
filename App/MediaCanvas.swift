import SwiftUI
import UIKit
import ImageIO

struct ImageCanvasPresentation: Equatable {
    let file: URL
    let canvasIdentity: String
    let loadCount: Int
}

struct MediaCanvas: UIViewRepresentable {
    var file: URL
    var animated = true
    var onZoomChanged: ((Bool) -> Void)? = nil
    var onImageSizeChanged: ((CGSize) -> Void)? = nil
    var onSingleTap: ((CGPoint) -> Void)? = nil
    var onPresentation: ((ImageCanvasPresentation) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChanged: onZoomChanged, onImageSizeChanged: onImageSizeChanged, onSingleTap: onSingleTap, onPresentation: onPresentation) }
    func makeUIView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.onZoomChanged = { [weak coordinator = context.coordinator] zoomed in coordinator?.report(zoomed) }
        view.onImageSizeChanged = { [weak coordinator = context.coordinator] size in coordinator?.report(size) }
        view.onSingleTap = onSingleTap == nil ? nil : { [weak coordinator = context.coordinator] point in coordinator?.reportTap(point) }
        view.onPresentation = { [weak coordinator = context.coordinator] value in coordinator?.reportPresentation(value) }
        view.load(file, animate: animated)
        return view
    }
    func updateUIView(_ view: ImageCanvasView, context: Context) {
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.onImageSizeChanged = onImageSizeChanged
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onPresentation = onPresentation
        view.onZoomChanged = { [weak coordinator = context.coordinator] zoomed in coordinator?.report(zoomed) }
        view.onImageSizeChanged = { [weak coordinator = context.coordinator] size in coordinator?.report(size) }
        view.onSingleTap = onSingleTap == nil ? nil : { [weak coordinator = context.coordinator] point in coordinator?.reportTap(point) }
        view.onPresentation = { [weak coordinator = context.coordinator] value in coordinator?.reportPresentation(value) }
        if view.file != file {
            context.coordinator.invalidatePendingReports()
            view.load(file, animate: animated)
        } else { view.setAnimated(animated) }
    }
    static func dismantleUIView(_ view: ImageCanvasView, coordinator: Coordinator) {
        coordinator.invalidatePendingReports()
        view.dispose()
        view.resetZoom()
    }

    final class Coordinator {
        var onZoomChanged: ((Bool) -> Void)?
        var onImageSizeChanged: ((CGSize) -> Void)?
        var onSingleTap: ((CGPoint) -> Void)?
        var onPresentation: ((ImageCanvasPresentation) -> Void)?
        private var revision = UUID()
        init(onZoomChanged: ((Bool) -> Void)?, onImageSizeChanged: ((CGSize) -> Void)?, onSingleTap: ((CGPoint) -> Void)?, onPresentation: ((ImageCanvasPresentation) -> Void)?) { self.onZoomChanged = onZoomChanged; self.onImageSizeChanged = onImageSizeChanged; self.onSingleTap = onSingleTap; self.onPresentation = onPresentation }
        func invalidatePendingReports() { revision = UUID() }
        func report(_ zoomed: Bool) {
            let expectedRevision = revision
            let callback = onZoomChanged
            DispatchQueue.main.async { [weak self] in
                guard self?.revision == expectedRevision else { return }
                callback?(zoomed)
            }
        }
        func report(_ size: CGSize) {
            let expectedRevision = revision
            let callback = onImageSizeChanged
            DispatchQueue.main.async { [weak self] in
                guard self?.revision == expectedRevision else { return }
                callback?(size)
            }
        }
        func reportTap(_ point: CGPoint) {
            let expected = revision, callback = onSingleTap
            DispatchQueue.main.async { [weak self] in
                guard self?.revision == expected else { return }; callback?(point)
            }
        }
        func reportPresentation(_ value: ImageCanvasPresentation) {
            let expected = revision, callback = onPresentation
            DispatchQueue.main.async { [weak self] in
                guard self?.revision == expected else { return }
                callback?(value)
            }
        }
    }
}

final class ImageCanvasView: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let singleTap = UITapGestureRecognizer()
    private var asset: ReaderImageAsset?
    private var loadTask: Task<Void, Never>?
    private var frameTasks: [Int: Task<Void, Never>] = [:]
    private var preparedFrames: [Int: ReaderDecodedFrame] = [:]
    private var loadRevision = UUID()
    private var frameRevision = UUID()
    private var decodeDemand = MediaRequestDemand(priority: .prefetch)
    private var frameDuration: TimeInterval = 0.1
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var clock: CADisplayLink?
    private var elapsed: TimeInterval = 0
    private var index = 0
    private var frameCount = 0
    private var animate = true
    private var lastReportedZoomed = false
    private var lastReportedImageSize: CGSize?
    private let canvasIdentity = UUID().uuidString
    private var loadCount = 0
    private var presentedFile: URL?
    var onZoomChanged: ((Bool) -> Void)?
    var onImageSizeChanged: ((CGSize) -> Void)?
    var onSingleTap: ((CGPoint) -> Void)? { didSet { singleTap.isEnabled = onSingleTap != nil } }
    var onPresentation: ((ImageCanvasPresentation) -> Void)?
    private(set) var file: URL?
    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.panGestureRecognizer.isEnabled = false
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        addSubview(scroll); scroll.addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:))); tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        singleTap.addTarget(self, action: #selector(tapped(_:)))
        singleTap.require(toFail: tap); singleTap.isEnabled = false
        singleTap.cancelsTouchesInView = false; scroll.addGestureRecognizer(singleTap)
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .white
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .white.withAlphaComponent(0.65)
        statusLabel.textAlignment = .center; statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "reader.decode.status"
        retryButton.setTitle("重试显示", for: .normal)
        retryButton.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        retryButton.accessibilityIdentifier = "reader.decode.retry"
        retryButton.isHidden = true; statusLabel.isHidden = true
        addSubview(loadingIndicator); addSubview(statusLabel); addSubview(retryButton)
        isAccessibilityElement = true; accessibilityLabel = "画廊图片"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        loadingIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY - 16)
        statusLabel.frame = CGRect(x: 24, y: bounds.midY + 4, width: max(0, bounds.width - 48), height: 44)
        retryButton.frame = CGRect(x: bounds.midX - 64, y: bounds.midY + 52, width: 128, height: 44)
        if scroll.zoomScale == 1 { imageView.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stop() } else { start() } }
    func load(_ file: URL, animate: Bool) {
        loadCount += 1
        loadRevision = UUID(); let revision = loadRevision
        loadTask?.cancel(); loadTask = nil
        stop(); resetZoom()
        self.file = file; self.animate = animate
        asset = nil; imageView.image = nil; frameCount = 0; index = 0; elapsed = 0
        lastReportedImageSize = nil; presentedFile = nil
        decodeDemand = MediaRequestDemand(priority: animate ? .foreground : .prefetch)
        let demand = decodeDemand
        isAccessibilityElement = false; accessibilityIdentifier = "media.loading"
        retryButton.isHidden = true; statusLabel.text = "正在显示图片…"; statusLabel.isHidden = false
        loadingIndicator.startAnimating(); updateAccessibilityValue()
        loadTask = Task { @MainActor [weak self] in
            do {
                let asset = try await ReaderImagePipeline.shared.open(file: file, demand: demand)
                guard !Task.isCancelled, let self, self.loadRevision == revision, self.file == file else { return }
                self.asset = asset; self.frameCount = asset.frameCount
                if asset.pixelSize.width > 0, asset.pixelSize.height > 0,
                   self.lastReportedImageSize != asset.pixelSize {
                    self.lastReportedImageSize = asset.pixelSize
                    self.onImageSizeChanged?(asset.pixelSize)
                }
                let frame = try await ReaderImagePipeline.shared.frame(asset: asset, index: 0, demand: demand)
                guard !Task.isCancelled, self.loadRevision == revision, self.file == file else { return }
                self.loadTask = nil
                self.present(frame)
                self.start()
            } catch is CancellationError { }
            catch {
                guard let self, self.loadRevision == revision, self.file == file else { return }
                self.loadTask = nil
                self.showDecodeError()
            }
        }
    }

    private func present(_ frame: ReaderDecodedFrame) {
        index = frame.index; frameDuration = frame.duration
        imageView.image = UIImage(cgImage: frame.image)
        loadingIndicator.stopAnimating(); statusLabel.isHidden = true; retryButton.isHidden = true
        isAccessibilityElement = true
        accessibilityIdentifier = frameCount > 1 ? "media.animated" : "media.static"
        let headerSize = asset?.pixelSize ?? .zero
        let size = headerSize.width > 0 && headerSize.height > 0 ? headerSize : CGSize(width: frame.image.width, height: frame.image.height)
        if lastReportedImageSize != size { lastReportedImageSize = size; onImageSizeChanged?(size) }
        if let file, presentedFile != file {
            presentedFile = file
            onPresentation?(.init(file: file, canvasIdentity: canvasIdentity, loadCount: loadCount))
        }
        updateAccessibilityValue()
    }

    private func prepareUpcomingFrames() {
        guard animate, window != nil, let asset, frameCount > 1 else { return }
        let upcoming = Set((1...min(2, frameCount - 1)).map { (index + $0) % frameCount })
        for old in Array(frameTasks.keys) where !upcoming.contains(old) {
            frameTasks.removeValue(forKey: old)?.cancel()
        }
        preparedFrames = preparedFrames.filter { upcoming.contains($0.key) }
        let revision = loadRevision, animationRevision = frameRevision, demand = decodeDemand
        for next in upcoming where preparedFrames[next] == nil && frameTasks[next] == nil {
            if let cached = ReaderImagePipeline.shared.cachedFrame(asset: asset, index: next) {
                preparedFrames[next] = cached
                continue
            }
            frameTasks[next] = Task { @MainActor [weak self] in
                do {
                    let frame = try await ReaderImagePipeline.shared.frame(asset: asset, index: next, demand: demand)
                    guard !Task.isCancelled, let self, self.loadRevision == revision,
                          self.frameRevision == animationRevision, self.asset === asset else { return }
                    self.frameTasks[next] = nil
                    self.preparedFrames[next] = frame
                } catch is CancellationError { }
                catch {
                    guard let self, self.loadRevision == revision,
                          self.frameRevision == animationRevision, self.asset === asset else { return }
                    self.stop()
                    self.showDecodeError()
                }
            }
        }
    }

    private func start() {
        guard animate, frameCount > 1, asset != nil, imageView.image != nil,
              presentedFile == file, window != nil, clock == nil else { return }
        prepareUpcomingFrames()
        let clock = CADisplayLink(target: self, selector: #selector(tick(_:)))
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        clock.add(to: .main, forMode: .common); self.clock = clock
    }

    func stop() {
        clock?.invalidate(); clock = nil
        frameRevision = UUID()
        for task in frameTasks.values { task.cancel() }
        frameTasks.removeAll(); preparedFrames.removeAll()
    }

    func dispose() {
        loadRevision = UUID(); loadTask?.cancel(); loadTask = nil
        stop(); asset = nil; imageView.image = nil
        loadingIndicator.stopAnimating()
    }

    func setAnimated(_ enabled: Bool) {
        decodeDemand.setPriority(enabled ? .foreground : .prefetch)
        guard animate != enabled else { return }
        animate = enabled
        if enabled { start() } else { stop() }
    }

    private func showDecodeError() {
        loadingIndicator.stopAnimating()
        statusLabel.text = "这张图暂时无法显示。"; statusLabel.isHidden = false
        retryButton.isHidden = false; isAccessibilityElement = false
    }

    @objc private func retryImage() { if let file { load(file, animate: animate) } }

    @objc private func tick(_ link: CADisplayLink) {
        guard UIApplication.shared.applicationState == .active, frameCount > 1 else { return }
        elapsed += max(0, link.targetTimestamp - link.timestamp)
        guard elapsed >= frameDuration else { return }
        let next = (index + 1) % frameCount
        guard let prepared = preparedFrames.removeValue(forKey: next) else {
            elapsed = min(elapsed, frameDuration)
            prepareUpcomingFrames()
            return
        }
        elapsed = min(max(0, elapsed - frameDuration), prepared.duration)
        present(prepared)
        prepareUpcomingFrames()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        scroll.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.001
        reportZoom(scrollView.zoomScale > 1.001)
        updateAccessibilityValue()
    }
    func resetZoom() {
        if scroll.zoomScale != 1 { scroll.setZoomScale(1, animated: false) }
        scroll.panGestureRecognizer.isEnabled = false
        reportZoom(false)
        updateAccessibilityValue()
    }
    private func reportZoom(_ zoomed: Bool) {
        guard lastReportedZoomed != zoomed else { return }
        lastReportedZoomed = zoomed
        onZoomChanged?(zoomed)
    }
    private func updateAccessibilityValue() {
        guard AppMode.qa else { return }
        let frame = frameCount > 0 ? "frame \(index + 1) / \(frameCount)" : "frame 0 / 0"
        accessibilityValue = "\(frame); \(scroll.zoomScale > 1.001 ? "zoomed" : "fit"); \(file?.lastPathComponent ?? "none"); canvas=\(canvasIdentity); loads=\(loadCount); rendered=\(imageView.image != nil)"
    }
    @objc private func zoom(_ tap: UITapGestureRecognizer) { scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2.5, animated: true) }
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard scroll.zoomScale <= 1.001 else { return }
        onSingleTap?(convert(tap.location(in: self), to: window))
    }
}

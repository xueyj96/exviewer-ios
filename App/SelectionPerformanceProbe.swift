import Foundation
import OSLog
import QuartzCore
import SwiftUI
import UIKit

/// Passive, opt-in simulator instrumentation for measuring real selection
/// interactions. A display-link callback records frame scheduling only; it is
/// not evidence that Core Animation presented a frame or that pixels changed.
@MainActor
final class SelectionPerformanceProbe: NSObject {
    static let shared = SelectionPerformanceProbe()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ExViewer",
                                       category: "SelectionPerformance")

    private var displayLink: CADisplayLink?
    private var pendingID = ""
    private var recognizer: PassiveTouchEndRecognizer?

    private override init() { super.init() }

    private static var enabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-perf")
        #else
        false
        #endif
    }

    /// Call from a visible app root after its scene has a key window.
    static func installIfRequested(in window: UIWindow) {
        guard enabled else { return }
        shared.install(in: window)
    }

    /// Call immediately before invoking a selected-tile action.
    static func markAction(id: String) {
        guard enabled else { return }
        shared.buttonAction(id: id)
    }

    /// Call immediately after assigning the authoritative selected-ID set.
    static func markStateSet(id: String, count: Int) {
        guard enabled else { return }
        shared.stateSet(id: id, count: count)
    }

    /// Call from the visible selection cell's onChange after SwiftUI observes
    /// its selected state. This marks a view update, not a presented frame.
    static func markSelectionViewUpdate(id: String, selected: Bool) {
        guard enabled, selected else { return }
        emit("swiftui-check-update t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) id=\(id)")
    }

    private func buttonAction(id: String) {
        Self.emit("button-action t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) id=\(id)")
    }

    private func install(in window: UIWindow) {
        guard recognizer == nil else { return }
        let observer = PassiveTouchEndRecognizer { [weak self] point, timestamp in
            guard let self else { return }
            let time = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            Self.emit("touch-ended t=\(time) event=\(String(format: "%.6f", timestamp)) x=\(Int(point.x)) y=\(Int(point.y))")
        }
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        window.addGestureRecognizer(observer)
        recognizer = observer
        Self.emit("probe-installed t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime))")
    }

    private func stateSet(id: String, count: Int) {
        Self.emit("state-set t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) id=\(id) count=\(count)")
        pendingID = id
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        Self.emit("display-link-scheduled t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) id=\(pendingID) (not-presented-evidence)")
        link.invalidate()
        if displayLink === link { displayLink = nil }
    }

    private static func emit(_ message: String) {
        logger.notice("SELECTION_PERF \(message, privacy: .public)")
    }
}

/// Attaching this zero-size view to a root overlay installs the observer after
/// the active scene has created its window. It has no layout or hit-test area.
struct SelectionPerformanceProbeInstaller: View {
    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    guard let window = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene })
                        .flatMap(\.windows)
                        .first(where: \.isKeyWindow) else { return }
                    SelectionPerformanceProbe.installIfRequested(in: window)
                }
            }
    }
}

@MainActor
private final class PassiveTouchEndRecognizer: UIGestureRecognizer {
    private let onTouchEnded: (CGPoint, TimeInterval) -> Void

    init(onTouchEnded: @escaping (CGPoint, TimeInterval) -> Void) {
        self.onTouchEnded = onTouchEnded
        super.init(target: nil, action: nil)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            onTouchEnded(touch.location(in: view), touch.timestamp)
        }
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

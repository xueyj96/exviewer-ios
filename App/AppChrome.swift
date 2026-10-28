import SwiftUI
import UIKit

enum FloatingChrome {
    static let background = Color(uiColor: .systemBackground).opacity(0.70)
    static let controlFill = Color.primary.opacity(0.10)
}

/// Flat controls follow the same compact surface and hit area as CivitViewer.
struct AppActionButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, destructive }
    var tone: Tone = .neutral
    var singleLine = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let destructive = tone == .destructive || configuration.role == .destructive
        let ink: Color = destructive ? .red : (tone == .accent ? .accentColor : .primary)
        let fill = destructive ? Color.red.opacity(scheme == .dark ? 0.18 : 0.09)
            : (tone == .accent ? Color.accentColor.opacity(scheme == .dark ? 0.20 : 0.10)
               : Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
        configuration.label
            .lineLimit(singleLine ? 1 : nil)
            .fixedSize(horizontal: singleLine, vertical: false)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .automatic
    var tone: AppActionButtonStyle.Tone = .neutral
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement) {
                content().buttonStyle(AppActionButtonStyle(tone: tone, singleLine: true))
                    .fixedSize(horizontal: true, vertical: false)
            }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) {
                content().buttonStyle(AppActionButtonStyle(tone: tone, singleLine: true))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

extension View {
    func appNavigationChrome(backButton: Bool = false) -> some View {
        modifier(AppNavigationChromeModifier(backButton: backButton))
    }
}

private struct AppNavigationChromeModifier: ViewModifier {
    let backButton: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(backButton)
            .toolbar {
                if backButton {
                    AppToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("返回")
                        .accessibilityIdentifier("BackButton")
                    }
                }
            }
            .background(NavigationChrome(backButton: backButton).frame(width: AppMode.qa ? 1 : 0, height: AppMode.qa ? 1 : 0).allowsHitTesting(false))
    }
}

@MainActor
private struct NavigationChrome: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var scheme
    let backButton: Bool

    func makeUIViewController(context: Context) -> Controller { Controller(scheme: scheme, backButton: backButton) }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.scheme = scheme; controller.backButton = backButton
        controller.applyChrome(); controller.updateInteractivePop()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.deactivate() }

    final class Binding {
        weak var gesture: UIGestureRecognizer?
        let proxy: PopDelegate
        init(_ gesture: UIGestureRecognizer, proxy: PopDelegate) { self.gesture = gesture; self.proxy = proxy }
    }

    final class DiagnosticView: UIView {
        var readState: (() -> String)?
        override var accessibilityValue: String? {
            get { readState?() }
            set { }
        }
    }

    final class Controller: UIViewController {
        var scheme: ColorScheme
        var backButton: Bool
        private weak var styledNavigation: UINavigationController?
        private var styledScheme: ColorScheme?
        private var bindings: [ObjectIdentifier: Binding] = [:]
        private var ownershipLost: Set<ObjectIdentifier> = []
        private var visible = false
        private var lifecycle = UUID()
        private var appearanceCount = 0
        private var decisionCount = 0

        init(scheme: ColorScheme, backButton: Bool) {
            self.scheme = scheme; self.backButton = backButton
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() {
            if AppMode.qa {
                let diagnostic = DiagnosticView()
                diagnostic.isAccessibilityElement = true; diagnostic.accessibilityIdentifier = "qa.navigation.flat"
                diagnostic.readState = { [weak self] in
                    guard let self, let navigation = self.navigationController else { return "navigation=none" }
                    return self.diagnosticValue(navigation)
                }
                view = diagnostic
            } else { view = UIView() }
            view.isUserInteractionEnabled = false
        }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); applyChrome() }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appearanceCount += 1
            visible = true; lifecycle = UUID(); ownershipLost.removeAll()
            updateInteractivePop()
            DispatchQueue.main.async { [weak self] in self?.updateInteractivePop() }
        }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); deactivate() }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); deactivate() }
        func deactivate() { visible = false; lifecycle = UUID(); restoreBindings() }

        func applyChrome() {
            guard let navigation = navigationController,
                  styledNavigation !== navigation || styledScheme != scheme else { return }
            styledNavigation = navigation; styledScheme = scheme
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let ink = UIColor.label.resolvedColor(with: traits)
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = UIColor.systemBackground.resolvedColor(with: traits).withAlphaComponent(0.94)
            appearance.backgroundEffect = nil; appearance.shadowColor = .clear
            appearance.titleTextAttributes = [.foregroundColor: ink]
            navigation.navigationBar.standardAppearance = appearance
            navigation.navigationBar.scrollEdgeAppearance = appearance
            navigation.navigationBar.compactAppearance = appearance
            navigation.navigationBar.tintColor = ink
        }

        func updateInteractivePop() {
            guard let navigation = navigationController else { return }
            defer { updateDiagnostic(navigation) }
            guard backButton, visible, isViewLoaded, view.window != nil,
                  navigation.viewControllers.count > 1 else { restoreBindings(); return }
            guard navigation.transitionCoordinator == nil else { return }
            var gestures = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
            if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer,
               !gestures.contains(where: { $0 === content }) { gestures.append(content) }
            for gesture in gestures {
                let key = ObjectIdentifier(gesture)
                if let binding = bindings[key] {
                    guard gesture.delegate === binding.proxy else {
                        binding.proxy.isActive = false; bindings[key] = nil; ownershipLost.insert(key); continue
                    }
                    binding.proxy.isActive = true
                } else if !ownershipLost.contains(key) {
                    let proxy = PopDelegate(original: gesture.delegate, enabled: gesture.isEnabled, navigation: navigation)
                    proxy.isActive = true
                    proxy.onDecision = { [weak self, weak navigation] in
                        self?.decisionCount += 1
                        if let navigation { self?.updateDiagnostic(navigation) }
                    }
                    bindings[key] = Binding(gesture, proxy: proxy)
                    gesture.delegate = proxy; gesture.isEnabled = true
                }
            }
        }

        private func restoreBindings() {
            let revision = lifecycle
            for (key, binding) in bindings {
                guard let gesture = binding.gesture else { bindings[key] = nil; continue }
                if gesture.state != .began && gesture.state != .changed { binding.proxy.isActive = false }
                let restore = { [weak self] in
                    // A cancelled interactive pop can make this page visible
                    // again before its old transition completion is delivered.
                    if let self, self.visible || self.lifecycle != revision { return }
                    if let gesture = binding.gesture, gesture.delegate === binding.proxy {
                        guard gesture.state != .began && gesture.state != .changed else { return }
                        binding.proxy.isActive = false
                        gesture.delegate = binding.proxy.originalDelegate
                        gesture.isEnabled = binding.proxy.originalEnabled
                    }
                    if self?.bindings[key] === binding { self?.bindings[key] = nil }
                }
                if (gesture.state == .began || gesture.state == .changed), let transition = navigationController?.transitionCoordinator {
                    if !transition.animate(alongsideTransition: nil, completion: { _ in restore() }) { restore() }
                } else { restore() }
            }
        }

        private func updateDiagnostic(_ navigation: UINavigationController) {
            guard AppMode.qa else { return }
            view.accessibilityValue = diagnosticValue(navigation)
        }

        private func diagnosticValue(_ navigation: UINavigationController) -> String {
            let values = bindings.values.map { b in
                "enabled=\(b.gesture?.isEnabled ?? false),owned=\(b.gesture?.delegate === b.proxy),active=\(b.proxy.isActive),begin=\(b.proxy.beginCount),receive=\(b.proxy.receiveCount),events=\(b.proxy.eventCount),state=\(b.gesture?.state.rawValue ?? -1)"
            }.sorted().joined(separator: "|")
            return "stack=\(navigation.viewControllers.count);visible=\(visible);appearances=\(appearanceCount);decisions=\(decisionCount);transition=\(navigation.transitionCoordinator != nil);gestures=\(values)"
        }
    }

    @MainActor final class PopDelegate: NSObject, UIGestureRecognizerDelegate {
        // Retain the original only for restoration. Forwarding its additional
        // selectors also forwards the native hidden-back rejection on iOS 26.
        weak var originalDelegate: (any UIGestureRecognizerDelegate)?
        weak var navigation: UINavigationController?
        let originalEnabled: Bool
        var isActive = false
        var beginCount = 0
        var receiveCount = 0
        var eventCount = 0
        var onDecision: (() -> Void)?
        init(original: UIGestureRecognizerDelegate?, enabled: Bool, navigation: UINavigationController) {
            if let proxy = original as? PopDelegate { originalDelegate = proxy.originalDelegate }
            else { originalDelegate = original }
            originalEnabled = enabled; self.navigation = navigation
            super.init()
        }
        @objc(gestureRecognizer:shouldReceiveTouch:)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            receiveCount += 1; defer { onDecision?() }
            if gestureRecognizer.state == .began || gestureRecognizer.state == .changed { return true }
            if #available(iOS 26.0, *), gestureRecognizer === navigation?.interactiveContentPopGestureRecognizer {
                var hit = touch.view
                while let view = hit {
                    if view is UIControl { return false }
                    if let scroll = view as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                    hit = view.superview
                }
            }
            return isActive && (navigation?.viewControllers.count ?? 0) > 1 && navigation?.transitionCoordinator == nil
        }
        @objc(gestureRecognizer:shouldReceiveEvent:)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            eventCount += 1; defer { onDecision?() }
            if gestureRecognizer.state == .began || gestureRecognizer.state == .changed { return true }
            return isActive && (navigation?.viewControllers.count ?? 0) > 1 && navigation?.transitionCoordinator == nil
        }
        @objc(gestureRecognizerShouldBegin:)
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            beginCount += 1; defer { onDecision?() }
            guard isActive, let navigation, navigation.viewControllers.count > 1,
                  navigation.transitionCoordinator == nil else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: navigation.view)
                let translation = pan.translation(in: navigation.view)
                let movement = abs(velocity.x) + abs(velocity.y) > 0.1 ? velocity : translation
                let sign: CGFloat = navigation.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
                guard movement.x * sign > 0, abs(movement.x) > abs(movement.y) else { return false }
            }
            return true
        }
    }
}

import SwiftUI

struct FloatingFeedLayout<Feed: View, Header: View>: View {
    @State private var headerHeight: CGFloat = 0
    private let feed: (CGFloat) -> Feed
    private let header: Header

    init(@ViewBuilder feed: @escaping (CGFloat) -> Feed, @ViewBuilder header: () -> Header) {
        self.feed = feed
        self.header = header()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                feed(headerHeight)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                header
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background {
                        GeometryReader { headerGeometry in
                            Color.clear
                                .onAppear { updateHeaderHeight(headerGeometry.size.height) }
                                .onChange(of: headerGeometry.size.height) { _, height in updateHeaderHeight(height) }
                        }
                    }
                    .zIndex(1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func updateHeaderHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(headerHeight - height) > 0.5 else { return }
        headerHeight = height
    }
}

struct FloatingHeaderPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .background(FloatingChrome.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            .padding(.horizontal, 12)
            .padding(.top, 6)
    }
}

struct CompactMainTabs<Content: View>: View {
    @Binding var selection: Int
    let content: Content

    private struct Destination: Identifiable {
        var id: Int
        var title: String
        var symbol: String
        var identifier: String
    }

    private let destinations = [
        Destination(id: 0, title: "发现", symbol: "square.grid.2x2", identifier: "main.tab.discover"),
        Destination(id: 1, title: "资料库", symbol: "books.vertical", identifier: "main.tab.library"),
        Destination(id: 2, title: "账号", symbol: "person.crop.circle", identifier: "main.tab.account")
    ]

    init(selection: Binding<Int>, @ViewBuilder content: () -> Content) {
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { compactBar }
    }

    private var compactBar: some View {
        HStack(spacing: 0) {
            ForEach(destinations, id: \.id) { destination in
                Button { selection = destination.id } label: {
                    VStack(spacing: 3) {
                        Image(systemName: destination.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 20)
                        Text(destination.title)
                            .font(.caption2.weight(selection == destination.id ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 4)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(selection == destination.id ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(destination.title)
                .accessibilityIdentifier(destination.identifier)
                .accessibilityAddTraits(selection == destination.id ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(FloatingChrome.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityIdentifier("main.tabs.compact")
    }
}

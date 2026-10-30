import SwiftUI

struct LibraryScopePicker: View {
    @Binding var selection: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    private let titles = ["稍后再读", "站点收藏", "阅读历史", "下载"]
    var body: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                ForEach(titles.indices, id: \.self) { index in
                    Button { selection = index } label: {
                        if selection == index { Label(titles[index], systemImage: "checkmark") }
                        else { Text(titles[index]) }
                    }.accessibilityIdentifier("library.scope.\(index)")
                }
            } label: {
                HStack { Text(titles[selection]); Spacer(); Image(systemName: "chevron.down") }
                    .font(.headline).frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("library.scope.menu")
        } else {
            Picker("资料库内容", selection: $selection) {
                ForEach(titles.indices, id: \.self) { Text(titles[$0]).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("library.scope")
        }
    }
}

struct ReadLaterSelectionActions: View {
    @ObservedObject var summary: LibrarySelectionSummary
    let store: LibrarySelectionStore
    var onRemove: () -> Void
    var body: some View {
        HStack {
            Button(summary.value.allLoadedSelected ? "取消全选" : "全选") { store.toggleAllLoaded() }
                .buttonStyle(AppActionButtonStyle(singleLine: true)).frame(minHeight: 44)
                .accessibilityIdentifier("read-later.select-all")
            Spacer()
            Button("移出稍后再读", role: .destructive, action: onRemove)
                .buttonStyle(AppActionButtonStyle(singleLine: true)).frame(minHeight: 44)
                .disabled(summary.value.count == 0).accessibilityIdentifier("read-later.remove")
        }
        .padding(8).background(FloatingChrome.background, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12).accessibilityElement(children: .contain)
        .accessibilityIdentifier("read-later.actions")
    }
}

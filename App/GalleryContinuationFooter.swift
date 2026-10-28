import SwiftUI

struct GalleryContinuationFooter: View {
    @ObservedObject var pager: GalleryPager
    @EnvironmentObject private var session: SiteSession
    var body: some View {
        Group {
            if pager.loading { ProgressView(pager.items.isEmpty ? "正在载入" : "正在更新").padding(24) }
            else if let failure = pager.failure { StatusMessage(title: failure) { pager.retry(session: session) } }
            else if pager.next != nil {
                Button("继续加载") { pager.more(session: session) }.padding(24)
            }
        }
    }
}

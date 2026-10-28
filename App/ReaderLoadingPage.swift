import SwiftUI

struct ReaderLoadingPage: View {
    let index: Int
    var progress: MediaLoadProgress? = nil
    var metadata = false
    var failure: String? = nil
    var retry: (() -> Void)? = nil

    private var phaseText: String {
        if metadata { return "正在读取页面信息…" }
        switch progress?.phase ?? .resolvingPage {
        case .resolvingPage: return "正在读取图片地址…"
        case .queued: return "等待下载…"
        case .transferring: return "正在下载…"
        case .ready: return "正在显示图片…"
        }
    }

    private var byteText: String? {
        guard let progress, progress.phase == .transferring else { return nil }
        let received = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        if let total = progress.totalBytes {
            return received + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
        return progress.completedBytes > 0 ? received : nil
    }

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                Text("第 \(index) 页").font(.subheadline.monospacedDigit())
                if let failure {
                    Text(failure).font(.caption).multilineTextAlignment(.center)
                    if let retry {
                        Button("重试这一页", action: retry)
                            .frame(minWidth: 80, minHeight: 44)
                            .accessibilityIdentifier("reader.page.retry.\(index)")
                    }
                } else {
                    if let fraction = progress?.fraction {
                        ProgressView(value: fraction).frame(width: 112).tint(.white)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                    } else { ProgressView().tint(.white) }
                    Text(phaseText).font(.caption)
                    if let byteText { Text(byteText).font(.caption2.monospacedDigit()) }
                }
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.page.loading.\(index)")
        .accessibilityValue(failure ?? phaseText)
    }
}

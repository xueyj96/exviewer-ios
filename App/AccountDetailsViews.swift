import SwiftUI
import ExViewerCore

struct QuotaDetailsView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        List {
            Section("看图额度") {
                if let used = session.quota.used, let limit = session.quota.limit {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("已用 \(used)"); Spacer(); Text("上限 \(limit)") }
                        ProgressView(value: Double(used), total: Double(max(1, limit)))
                        Text("剩余 \(session.quota.remaining ?? 0)").font(.subheadline)
                        if let recovery = session.quota.recoveryPerMinute { Text("恢复速度：约 \(recovery.formatted())／分钟").font(.caption).foregroundStyle(.secondary) }
                        if let resetCost = session.quota.resetCost { Text("站点显示的重置成本：\(resetCost)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                } else if session.quota.tracking == .ip || session.quota.tracking == .restrictedIP {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(session.quota.tracking == .restrictedIP ? "当前 IP 高分辨率访问受限" : "当前使用 IP 额度", systemImage: session.quota.tracking == .restrictedIP ? "exclamationmark.triangle" : "network")
                            .font(.headline)
                        Text("站点未返回可确认的已用量和上限，因此不显示数值。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let resetCost = session.quota.resetCost { Text("站点显示的重置成本：\(resetCost)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                } else {
                    Text("尚未读取到可确认的额度数值。")
                        .foregroundStyle(.secondary)
                }
                if let failure { Text(failure).font(.subheadline).foregroundStyle(.red) }
                Button { Task { await refresh() } } label: {
                    if loading { ProgressView() } else { Label("刷新站点额度", systemImage: "arrow.clockwise") }
                }.disabled(loading || AppMode.qa)
                if !AppMode.qa {
                    Link("在官方页面查看额度设置", destination: URL(string: "https://e-hentai.org/home.php")!)
                }
            }
            Section {
                Text("额度数值只在站点页面成功返回并识别后显示。页面结构变化、登录验证或站点故障会保留为未读取状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("看图额度").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
        .task { if session.quota.used == nil { await refresh() } }
    }

    @MainActor private func refresh() async {
        guard !AppMode.qa else { failure = "测试模式未访问账号数据。"; return }
        loading = true; failure = nil; session.error = nil
        await session.refreshQuota()
        loading = false
        if let error = session.error { failure = error }
        else if session.quota.used == nil && session.quota.tracking != .ip && session.quota.tracking != .restrictedIP { failure = "站点返回内容未能确认额度格式。" }
    }
}

struct SponsorshipView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var reading = AccountPageReading()
    @State private var loading = false
    @State private var failures: [String] = []

    private let homeURL = URL(string: "https://e-hentai.org/home.php")!
    private let donationURL = URL(string: "https://e-hentai.org/bitcoin.php")!
    private let perksURL = URL(string: "https://e-hentai.org/hathperks.php")!

    var body: some View {
        List {
            Section("账号权益状态") {
                LabeledContent("额度计算方式", value: reading.quotaTrackingMode ?? "未从站点页面识别")
                if reading.donationStatus.isEmpty {
                    Text("未读取到可确认的捐赠或服务器赞助状态。") .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reading.donationStatus.enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline) }
                }
            }
            Section("站点提供的付款信息") {
                if reading.paymentInformation.isEmpty {
                    Text("未从站点页面识别付款方式信息。可打开官方页面查看当前说明。") .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reading.paymentInformation.enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline).textSelection(.enabled) }
                }
                Link("打开官方赞助页面", destination: donationURL)
            }
            Section("Hath Perks") {
                if reading.perksInformation.isEmpty {
                    Text("未从站点页面识别权益或价格信息。") .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reading.perksInformation.enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline) }
                }
                Link("打开官方 Hath Perks 页面", destination: perksURL)
            }
            if !failures.isEmpty {
                Section("读取状态") { ForEach(Array(failures.enumerated()), id: \.offset) { _, error in Text(error).font(.caption).foregroundStyle(.red) } }
            }
            Section {
                Text("此页只展示站点当前返回并能识别的内容。不会代替你操作付款，也不会推断未显示的权益、金额或付款地址。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("赞助与权益").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
        .toolbar { AppToolbarItem(placement: .primaryAction) { Button { Task { await load() } } label: { if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") } }.disabled(loading || AppMode.qa) } }
        .task { if !AppMode.qa && !loading { await load() } }
    }

    @MainActor private func load() async {
        guard !AppMode.qa else { failures = ["测试模式未访问账号数据。"]; return }
        loading = true; failures = []; reading = AccountPageReading()
        let revision = session.generation
        let owner = session.owner
        defer { if isCurrent(revision, owner) { loading = false } }

        do {
            let html = try await session.html(homeURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readHome(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append("额度与账号状态读取失败：\(error.localizedDescription)")
        }
        do {
            let html = try await session.html(donationURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readDonation(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append("赞助页面读取失败：\(error.localizedDescription)")
        }
        do {
            let html = try await session.html(perksURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readPerks(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append("Hath Perks 页面读取失败：\(error.localizedDescription)")
        }
    }

    @MainActor private func isCurrent(_ revision: UUID, _ owner: String) -> Bool {
        revision == session.generation && owner == session.owner
    }
}

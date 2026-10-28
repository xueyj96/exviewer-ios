import SwiftUI
import ExViewerCore

struct SaveSearchSheet: View {
    var query: SearchQuery
    var site: GallerySite
    var replacing: UUID?
    var onSaved: (UUID) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?
    init(query: SearchQuery, site: GallerySite, replacing: UUID?, initialName: String, onSaved: @escaping (UUID) -> Void) {
        self.query = query; self.site = site; self.replacing = replacing; self.onSaved = onSaved; _name = State(initialValue: initialName)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("组合名称", text: $name).accessibilityIdentifier("search.save.name") }
                Section("保存内容") {
                    LabeledContent("站点", value: site.name)
                    LabeledContent("条件数量", value: String(query.count))
                    Text((try? query.expression()) ?? "请先调整搜索条件").font(.caption).foregroundStyle(.secondary)
                    Text("关键词、标签、分类、评分与页数条件会一起保存。").font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
                if replacing != nil { Section { Button("另存为新组合") { save(replacing: nil) } } }
            }.navigationTitle(replacing == nil ? "保存搜索组合" : "编辑搜索组合").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
                .toolbar { AppToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; AppToolbarItem(placement: .confirmationAction, tone: .accent) { Button("保存") { save(replacing: replacing) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("search.save.confirm") } }
        }
    }
    private func save(replacing: UUID?) {
        do {
            _ = try query.url(site: site)
            guard let id = library.saveSearch(name: name, site: site, query: query, replacing: replacing), let saved = library.snapshot.saved.first(where: { $0.id == id }), saved.query == query, saved.site == site else { failure = library.error ?? "保存未完成，请检查名称或已保存组合数量。"; return }
            onSaved(id); dismiss()
        } catch { failure = (error as? ViewerError)?.localizedDescription ?? "条件无法保存" }
    }
}

struct DiscoveryComposerView: View {
    var initialQuery: SearchQuery
    var initialSite: GallerySite
    var initialSavedID: UUID?
    var onApply: (SearchQuery, GallerySite, UUID?) throws -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @State private var draftQuery: SearchQuery
    @State private var draftSite: GallerySite
    @State private var draftSavedID: UUID?
    @State private var inputText: String
    @State private var minimumPagesText: String
    @State private var maximumPagesText: String
    @State private var tagMatch: TagMatch = .all
    @State private var advanced = false
    @State private var tagEntry = false
    @State private var failure: String?

    init(query: SearchQuery, site: GallerySite, savedID: UUID?, onApply: @escaping (SearchQuery, GallerySite, UUID?) throws -> Void) {
        initialQuery = query; initialSite = site; initialSavedID = savedID; self.onApply = onApply
        _draftQuery = State(initialValue: query)
        _draftSite = State(initialValue: site)
        _draftSavedID = State(initialValue: savedID)
        _inputText = State(initialValue: query.text)
        _minimumPagesText = State(initialValue: query.minPages.map(String.init) ?? "")
        _maximumPagesText = State(initialValue: query.maxPages.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("搜索内容") {
                    Picker("站点", selection: $draftSite) { ForEach(GallerySite.allCases) { Text($0.name).tag($0) } }
                    TextField("关键词、title:标题、namespace:标签", text: $inputText, axis: .vertical)
                        .lineLimit(1...3).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("compose.text")
                        .accessibilityHint("支持包含、~任一、-排除标签和 uploader:上传者；标签含空格时可加引号。")
                    Toggle("关键词只匹配标题", isOn: $draftQuery.titleOnly)
                    Toggle("关键词按完整短语匹配", isOn: $draftQuery.matchPhrase)
                    HStack(spacing: 8) {
                        Image(systemName: "person").foregroundStyle(.secondary)
                        TextField("作者 artist（不是上传者）", text: $draftQuery.artist)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("compose.artist")
                    }
                }

                Section("标签条件 · 包含 AND / 任一 OR / 排除") {
                    Picker("新加标签方式", selection: $tagMatch) {
                        ForEach(TagMatch.allCases, id: \.self) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented)
                    if !library.snapshot.favoriteTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(library.snapshot.favoriteTags) { tag in
                                    Button(tag.label) { addTag(tag, match: tagMatch) }
                                        .buttonStyle(AppActionButtonStyle()).accessibilityIdentifier("compose.favorite-tag.\(tag.id)")
                                }
                            }
                        }
                    }
                    Button { tagEntry = true } label: { Label("输入标签原名", systemImage: "plus") }
                        .accessibilityIdentifier("compose.add-tag")
                    ForEach(draftQuery.rules) { rule in
                        HStack(spacing: 8) {
                            Text(rule.match.name).font(.caption).foregroundStyle(.secondary)
                            Text(rule.tag.label).lineLimit(1)
                            Spacer(minLength: 0)
                            Button(role: .destructive) { draftQuery.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                                .accessibilityLabel("移除 \(rule.tag.label)")
                        }
                    }
                }

                Section("画廊分类") {
                    Text("点亮的分类参与搜索；其他题材使用标签原名，按完整名称匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("选择全部分类") { draftQuery.excludedCategories.removeAll() }.buttonStyle(.borderless)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(GalleryCategory.all) { category in
                            let excluded = draftQuery.excludedCategories.contains(category.id)
                            Button {
                                if excluded { draftQuery.excludedCategories.remove(category.id) }
                                else { draftQuery.excludedCategories.insert(category.id) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: excluded ? "circle" : "checkmark.circle.fill")
                                    Text(category.name).lineLimit(1)
                                }
                                .font(.caption).frame(maxWidth: .infinity, minHeight: 44)
                                .background(excluded ? Color(uiColor: .tertiarySystemFill) : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(excluded ? "取消排除分类 \(category.name)" : "排除分类 \(category.name)")
                            .accessibilityIdentifier("compose.category.\(category.id)")
                            .accessibilityValue(excluded ? "未选择" : "已选择")
                        }
                    }
                }

                Section {
                    DisclosureGroup("高级限制", isExpanded: $advanced) {
                        Picker("最低评分", selection: Binding(get: { draftQuery.minRating ?? 0 }, set: { draftQuery.minRating = $0 == 0 ? nil : $0 })) {
                            Text("不限").tag(0); ForEach(2...5, id: \.self) { Text("\($0) 星").tag($0) }
                        }
                        HStack {
                            TextField("最少页数", text: $minimumPagesText).keyboardType(.numberPad).accessibilityIdentifier("compose.min-pages")
                            Text("—").foregroundStyle(.secondary)
                            TextField("最多页数", text: $maximumPagesText).keyboardType(.numberPad).accessibilityIdentifier("compose.max-pages")
                        }
                        TextField("上传者 uploader（可选）", text: $draftQuery.uploader).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("compose.uploader")
                        Toggle("必须有 torrent", isOn: $draftQuery.requireTorrent)
                        if let warning = draftQuery.pageRangeWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                    }.accessibilityIdentifier("compose.advanced")
                }

                if let failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("compose.error") } }
            }
            .navigationTitle("组合搜索").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("compose.cancel")
                }
                AppToolbarItem(placement: .confirmationAction, tone: .accent) {
                    Button("搜索") { apply() }.fontWeight(.semibold).accessibilityIdentifier("compose.apply")
                }
            }
            .sheet(isPresented: $tagEntry) {
                TagEntryView { tag, match in addTag(tag, match: match) }
                    .environmentObject(library)
                    .environmentObject(session)
            }
        }
    }

    private func addTag(_ tag: GalleryTag, match: TagMatch) {
        draftQuery.rules.removeAll { $0.id == tag.id }
        draftQuery.rules.append(.init(tag: tag, match: match))
    }

    private func apply() {
        do {
            var proposed = draftQuery
            func page(_ text: String) throws -> Int? {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { return nil }
                guard let number = Int(value), number >= 0 else { throw ViewerError.invalidQuery("页数须为非负整数。") }
                return number
            }
            proposed.minPages = try page(minimumPagesText); proposed.maxPages = try page(maximumPagesText)
            proposed.artist = proposed.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            proposed.uploader = proposed.uploader.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try SearchInputParser.parse(inputText, preserving: proposed)
            _ = try parsed.query.url(site: draftSite)
            try onApply(parsed.query, draftSite, draftSavedID)
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? (error as? ViewerError)?.localizedDescription ?? "搜索条件无效"
        }
    }
}

struct SearchFilters: View {
    @Binding var query: SearchQuery
    @Binding var site: GallerySite
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @State private var addTag = false
    var body: some View {
        NavigationStack {
            Form {
                Section("范围") {
                    Picker("站点", selection: $site) { ForEach(GallerySite.allCases) { Text($0.name).tag($0) } }
                    Toggle("关键词只匹配标题", isOn: $query.titleOnly)
                    Toggle("关键词按完整短语匹配", isOn: $query.matchPhrase)
                    TextField("作者 artist", text: $query.artist).autocorrectionDisabled()
                    TextField("上传者 uploader", text: $query.uploader).autocorrectionDisabled()
                }
                Section("分类") {
                    ForEach(GalleryCategory.all) { category in
                        Toggle(category.name, isOn: Binding(get: { !query.excludedCategories.contains(category.id) }, set: { enabled in if enabled { query.excludedCategories.remove(category.id) } else { query.excludedCategories.insert(category.id) } }))
                    }
                }
                Section("评分与页数") {
                    Picker("最低评分", selection: Binding(get: { query.minRating ?? 0 }, set: { query.minRating = $0 == 0 ? nil : $0 })) { Text("不限").tag(0); ForEach(2...5, id: \.self) { Text("\($0) 星").tag($0) } }
                    HStack { TextField("最少页数", value: $query.minPages, format: .number).keyboardType(.numberPad); Text("—").foregroundStyle(.secondary); TextField("最多页数", value: $query.maxPages, format: .number).keyboardType(.numberPad) }
                    if let warning = query.pageRangeWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                    Toggle("必须有 torrent", isOn: $query.requireTorrent)
                }
                Section("标签条件") {
                    ForEach($query.rules) { $rule in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(rule.tag.label).font(.subheadline); Spacer(); Button(role: .destructive) { query.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("移除 \(rule.tag.label)") }
                            Picker("匹配", selection: $rule.match) { ForEach(TagMatch.allCases, id: \.self) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
                        }.padding(.vertical, 4)
                    }
                    Button { addTag = true } label: { Label("添加标签", systemImage: "plus") }.accessibilityIdentifier("filters.add-tag")
                }
                Section { Button("重置全部条件", role: .destructive) { query = SearchQuery() } }
            }.navigationTitle("搜索筛选").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
                .toolbar { AppToolbarItem(placement: .confirmationAction, tone: .accent) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $addTag) {
                    TagEntryView { tag, match in query.rules.removeAll { $0.id == tag.id }; query.rules.append(.init(tag: tag, match: match)) }
                        .environmentObject(library)
                        .environmentObject(session)
                }
        }
    }
}

private struct PendingTagEntry: Identifiable {
    let tag: GalleryTag
    var match: TagMatch
    let origin: String
    var status: String
    var id: String { tag.id }
}

struct TagEntryView: View {
    var onSelect: (GalleryTag, TagMatch) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @State private var text = ""
    @State private var namespace = "all"
    @State private var match: TagMatch = .all
    @StateObject private var suggestions = TagSuggestionModel()
    @State private var selected: TagSuggestion?
    @State private var verification: TagVerification = .unverified
    @State private var verificationTasks: [String: Task<Void, Never>] = [:]
    @State private var pending: [PendingTagEntry] = []
    @FocusState private var editingText: Bool
    private let namespaces = ["artist", "group", "parody", "character", "language", "cosplayer", "location", "female", "male", "mixed", "other", "reclass"]

    var body: some View {
        NavigationStack {
            Form {
                Section("标签条件") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            namespaceButton("all", title: "全部")
                            ForEach(namespaces, id: \.self) { value in namespaceButton(value, title: namespaceTitle(value)) }
                        }
                    }
                    .scrollClipDisabled()
                    .accessibilityIdentifier("tag.namespace-filter")
                    TextField("中文名或标签原名", text: $text)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("tag.name")
                        .focused($editingText).submitLabel(.done).onSubmit { editingText = false }
                        .accessibilityHint("中文只在本地词库匹配；英文前缀向 E-Hentai 请求标签候选。")
                    Picker("匹配方式", selection: $match) {
                        ForEach(TagMatch.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("tag.match")
                }

                Section("建议") {
                    if suggestions.catalog == nil {
                        Text("中文词库不可用，仍可按原名查询。")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("tag.dictionary-unavailable")
                    }
                    if suggestions.state == .loading {
                        HStack(spacing: 8) { ProgressView(); Text("正在查找标签建议…").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let message = suggestions.state.message {
                        Text(message).font(.caption).foregroundStyle(suggestions.state.isFailure ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("tag.suggestion-status")
                    }
                    ForEach(suggestions.items) { item in
                        let pendingEntry = pending.first(where: { $0.id == item.id })
                        Button { select(item) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let chinese = item.chineseName, !chinese.isEmpty {
                                        Text(chinese).font(.body.weight(.medium)).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Text(item.tag.name).font(.body).foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("\(namespaceTitle(item.tag.namespace)) · \(item.tag.namespace)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(sourceLabel(item.source)).font(.caption).foregroundStyle(.secondary)
                                        if let master = item.relatedMaster {
                                            Text("master: \(master.label)").font(.caption).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    if selected?.id == item.id {
                                        Text(verificationLabel)
                                            .font(.caption).foregroundStyle(verification == .verified ? Color.green : Color.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                if pendingEntry != nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.source == .unsupported)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
                        .accessibilityIdentifier("tag.suggestion.\(item.id)")
                        .accessibilityValue("\(sourceLabel(item.source)); \(pendingEntry.map { "已加入待添加；\($0.status)" } ?? verificationLabelFor(item))")
                        .accessibilityAddTraits(pendingEntry == nil ? [] : .isSelected)
                    }
                    if suggestions.items.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && suggestions.state != .loading {
                        Text(namespace == "all" ? "没有匹配项。选择命名空间后可明确使用未验证输入。" : "没有匹配项。可明确使用未验证输入。")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("tag.no-results")
                    }
                }

                if !library.snapshot.favoriteTags.isEmpty {
                    Section("本机常用标签") {
                        ForEach(library.snapshot.favoriteTags) { tag in
                            Button {
                                select(TagSuggestion(tag: tag, source: .saved, chineseName: suggestions.catalog?.translation(for: tag), relatedMaster: nil))
                            } label: {
                                HStack(spacing: 8) {
                                    Text(tag.namespace).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(tag.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: pending.contains(where: { $0.id == tag.id }) ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(pending.contains(where: { $0.id == tag.id }) ? Color.accentColor : Color.secondary)
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tag.favorite.\(tag.id)")
                            .accessibilityValue("本机常用；站点未验证")
                        }
                    }
                }

                if !pending.isEmpty {
                    Section("待添加（\(pending.count)）") {
                        ForEach($pending) { $entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.tag.label).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                        Text(entry.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                            .accessibilityIdentifier("tag.pending.status.\(entry.id)")
                                    }
                                    Spacer(minLength: 4)
                                    Button(role: .destructive) {
                                        verificationTasks[entry.id]?.cancel()
                                        verificationTasks[entry.id] = nil
                                        pending.removeAll { $0.id == entry.id }
                                    } label: {
                                        Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44)
                                    }
                                    .accessibilityLabel("移除待添加标签 \(entry.tag.label)")
                                    .accessibilityIdentifier("tag.pending.remove.\(entry.id)")
                                }
                                Picker("匹配方式：\(entry.tag.label)", selection: $entry.match) {
                                    ForEach(TagMatch.allCases, id: \.self) { Text($0.name).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .accessibilityIdentifier("tag.pending.match.\(entry.id)")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let manualTag {
                    Section("未验证输入") {
                        LabeledContent("原名", value: manualTag.label)
                        Text("此输入未由站点确认。添加后仍会标为未验证。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("添加未验证标签") { stageManualTag() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("tag.stage")
                    }
                }
                if let catalog = suggestions.catalog {
                    Section {
                        DisclosureGroup {
                            Text(catalog.information).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("tag.dictionary-info")
                        } label: { Text("词库来源与覆盖").accessibilityIdentifier("tag.dictionary-disclosure") }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .listSectionSpacing(16)
            .navigationTitle("添加标签").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("tag.cancel")
                }
                AppToolbarItem(placement: .confirmationAction, tone: .accent) {
                    Button("完成 \(pending.count)") {
                        let additions = pending
                        additions.forEach { onSelect($0.tag, $0.match) }
                        dismiss()
                    }
                    .disabled(pending.isEmpty)
                    .accessibilityLabel("完成，\(pending.count) 个标签")
                    .accessibilityIdentifier("tag.confirm")
                }
            }
            .onAppear { updateSuggestions() }
            .onChange(of: text) { _, _ in resetSelectionAndUpdate() }
            .onChange(of: namespace) { _, _ in resetSelectionAndUpdate() }
            .onChange(of: session.generation) { _, _ in
                verificationTasks.values.forEach { $0.cancel() }
                verificationTasks.removeAll()
                suggestions.sessionChanged()
                for index in pending.indices where pending[index].origin != "E-Hentai 站点候选" {
                    pending[index].status = "\(pending[index].origin)；会话已变化，未完成核验"
                }
                selected = nil; verification = .unverified
                updateSuggestions()
            }
            .onDisappear { verificationTasks.values.forEach { $0.cancel() }; suggestions.cancel() }
        }
    }

    private var manualTag: GalleryTag? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, namespace != "all" else { return nil }
        return GalleryTag(namespace: namespace, name: value)
    }

    private func stageManualTag() {
        guard let tag = manualTag, TagSuggestionRequest.isSelectable(tag) else { return }
        upsertPending(tag, origin: "手输标签，站点未验证", status: "未验证输入")
        clearInputForNextTag()
    }

    private var verificationLabel: String {
        if selected?.source == .qaFixture && verification == .verified {
            return "QA fixture模拟站点匹配；不代表真实站点响应"
        }
        let origin = selected.map { sourceLabel($0.source) } ?? "标签"
        switch verification {
        case .checking: return "\(origin)；正在向 E-Hentai 精确核验…"
        case .verified: return selected?.source == .site ? "站点候选" : "站点已匹配 · 来源：\(origin)"
        case .notFound: return "站点未匹配；\(origin)"
        case .failed(let reason): return "\(reason)；来源：\(origin)"
        case .unverified: return origin
        }
    }

    private func verificationLabelFor(_ item: TagSuggestion) -> String {
        guard selected?.id == item.id else {
            switch item.source {
            case .site: return "站点候选"
            case .cached: return "站点缓存，未实时验证"
            case .dictionary: return "词库匹配，站点未验证"
            case .saved: return "本机常用，未核验"
            case .unsupported: return "站点返回未支持类型，不可提交"
            case .qaFixture: return "QA 样例，未核验"
            }
        }
        return verificationLabel
    }

    private func sourceLabel(_ source: TagSuggestion.Source) -> String {
        switch source {
        case .site: return "E-Hentai 站点候选"
        case .cached: return "站点缓存候选，未实时验证"
        case .dictionary: return "词库匹配，站点未验证"
        case .saved: return "本机常用标签，站点未验证"
        case .unsupported: return "站点返回未支持类型，不可提交"
        case .qaFixture: return "QA 样例，不是站点匹配"
        }
    }

    private func namespaceTitle(_ value: String) -> String {
        ["artist": "作者", "group": "社团", "parody": "系列", "character": "角色", "language": "语言",
         "cosplayer": "扮演者", "location": "地点", "female": "女性", "male": "男性", "mixed": "混合",
         "other": "其他", "reclass": "重分类"][value] ?? value
    }

    private func namespaceButton(_ value: String, title: String) -> some View {
        let isSelected = namespace == value
        return Button { namespace = value } label: {
            Text(title).font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10).frame(minHeight: 44)
                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.accentColor : Color(uiColor: .separator), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .accessibilityLabel("标签命名空间：\(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tag.namespace.\(value)")
    }

    private func select(_ item: TagSuggestion) {
        guard item.source != .unsupported, TagSuggestionRequest.isSelectable(item.tag) else { return }
        if let index = pending.firstIndex(where: { $0.id == item.id }) {
            pending[index].match = match
            selected = item
            verification = .unverified
            return
        }
        verificationTasks[item.id]?.cancel()
        selected = item
        switch item.source {
        case .site:
            verification = .verified
            upsertPending(item.tag, origin: sourceLabel(item.source), status: "站点候选")
        case .qaFixture:
            verification = .verified
            upsertPending(item.tag, origin: "QA 样例，非真实站点匹配", status: "QA 样例，非真实站点匹配")
        case .unsupported: return
        case .cached, .dictionary, .saved:
            suggestions.cancel()
            verification = .checking
            let id = item.id
            upsertPending(item.tag, origin: sourceLabel(item.source), status: "\(sourceLabel(item.source))；正在精确核验")
            let sessionGeneration = session.generation
            verificationTasks[id] = Task {
                let result = await suggestions.verify(item.tag, session: session, qa: AppMode.qa)
                guard !Task.isCancelled, sessionGeneration == session.generation,
                      let index = pending.firstIndex(where: { $0.id == id }) else { return }
                pending[index].status = verificationStatus(result, origin: pending[index].origin)
                verificationTasks[id] = nil
                if selected?.id == id { verification = result }
            }
        }
    }

    private func resetSelectionAndUpdate() {
        selected = nil; verification = .unverified
        updateSuggestions()
    }

    private func upsertPending(_ tag: GalleryTag, origin: String, status: String) {
        if let index = pending.firstIndex(where: { $0.id == tag.id }) {
            pending[index].match = match
        } else {
            pending.append(PendingTagEntry(tag: tag, match: match, origin: origin, status: status))
        }
    }

    private func clearInputForNextTag() {
        selected = nil
        verification = .unverified
        text = ""
        editingText = true
        updateSuggestions()
    }

    private func verificationStatus(_ result: TagVerification, origin: String) -> String {
        switch result {
        case .checking: return "\(origin)；正在核验"
        case .verified: return "站点已匹配 · 来源：\(origin)"
        case .notFound: return "站点未匹配；\(origin)"
        case .failed(let reason): return "\(reason)；来源：\(origin)"
        case .unverified: return "\(origin)"
        }
    }

    private func updateSuggestions() {
        suggestions.update(prefix: text, namespace: namespace, session: session, qa: AppMode.qa)
    }
}

import SwiftUI
import ExViewerCore

struct GalleryFavoriteEditorView: View {
    let gallery: Gallery
    let onState: (GalleryFavoriteState, GalleryFavoriteForm?) -> Void
    let requestRemoval: Bool
    @StateObject private var model: GalleryFavoriteEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var mutation: Task<Void, Never>?

    init(gallery: Gallery, session: SiteSession, requestRemoval: Bool = false,
         preparation: GalleryFavoritePreparation? = nil, onState: @escaping (GalleryFavoriteState, GalleryFavoriteForm?) -> Void) {
        self.gallery = gallery; self.onState = onState; self.requestRemoval = requestRemoval
        let client = preparation?.client ?? favoriteClient(for: gallery, session: session)
        let initial = preparation?.initialForm.flatMap { $0.reference == gallery.ref ? $0 : nil }
        _model = StateObject(wrappedValue: GalleryFavoriteEditorModel(client: client, initialForm: initial))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(gallery.title).font(.subheadline).lineLimit(2)
                    LabeledContent("站点", value: gallery.ref.site.name)
                    LabeledContent("当前状态", value: status)
                        .accessibilityIdentifier("favorite.editor.status")
                }
                if model.loading {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView().accessibilityIdentifier("favorite.editor.loading-spinner")
                            Text("读取收藏…").font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("favorite.editor.loading-label")
                        }
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("favorite.editor.loading")
                    }
                }
                if let error = model.error {
                    Section {
                        Text(error).font(.subheadline).foregroundStyle(.red)
                            .accessibilityIdentifier("favorite.editor.error")
                        if model.needsVerification || model.form == nil {
                            Button(model.needsVerification ? "刷新状态" : "重新读取") {
                                mutation = Task {
                                    let confirmed = await model.reload(preserveDraft: model.form != nil)
                                    publishState()
                                    if confirmed { dismiss() }
                                }
                            }.disabled(model.working).accessibilityIdentifier("favorite.editor.refresh")
                        }
                    }
                }
                if requestRemoval, model.form != nil {
                    Section {
                        if model.canRemove {
                            Text("从站点收藏移除这部作品？")
                            Button("确认取消收藏", role: .destructive) { save(remove: true) }
                                .accessibilityIdentifier("favorite.editor.confirm-remove")
                        } else if model.observedState == .notFavorited {
                            Text("这部作品已不在站点收藏中。")
                        }
                    } footer: { Text("稍后再读、下载文件和阅读进度会保留。") }
                }
                if let form = model.form, !requestRemoval {
                    Section {
                        ForEach(form.groups) { group in
                            Button { model.selection = group.id } label: {
                                HStack(spacing: 12) {
                                    Text(group.name).foregroundStyle(.primary)
                                    Spacer(minLength: 12)
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        .opacity(model.selection == group.id ? 1 : 0)
                                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.working || model.needsVerification)
                                .accessibilityIdentifier("favorite.editor.group.\(group.id)")
                                .accessibilityValue(model.selection == group.id ? "已选择" : "未选择")
                                .accessibilityAddTraits(model.selection == group.id ? .isSelected : [])
                        }
                    } header: { Text("收藏分组") }
                    footer: { if model.selection == nil { Text("选择一个分组，再保存到站点账号。") } }
                    Section {
                        TextField("添加备注", text: $model.note, axis: .vertical)
                            .lineLimit(3...5).disabled(model.working || model.needsVerification)
                            .accessibilityIdentifier("favorite.editor.note")
                    } header: { Text("备注（可选）") }
                    footer: {
                        Text(model.noteBytes <= 200 ? "中文通常约 66 字，英文约 200 字。" :
                                (GalleryFavoriteForm.normalizedNote(model.note) == form.note ? "已保留原有备注；新备注请控制长度。" : "备注过长，请删减后保存。"))
                            .foregroundStyle(model.noteBytes > 200 && GalleryFavoriteForm.normalizedNote(model.note) != form.note ? Color.red : .secondary)
                    }
                    if form.selectedGroup != nil {
                        Section {
                            Button("移除站点收藏", role: .destructive) { removing = true }
                                .disabled(!model.canRemove).accessibilityIdentifier("favorite.editor.remove")
                        }
                    }
                }
                if AppMode.qa {
                    Text("reads=\(model.reads);posts=\(model.posts)").font(.system(size: 1)).foregroundStyle(.clear)
                        .accessibilityIdentifier("favorite.editor.qa-counts")
                }
                if model.form != nil && model.error == nil {
                    Section {
                        Button("刷新站点状态") {
                            mutation = Task {
                                let confirmed = await model.reload(preserveDraft: true)
                                publishState()
                                if confirmed { dismiss() }
                            }
                        }.disabled(model.working).accessibilityIdentifier("favorite.editor.reload")
                    }
                }
            }
            .navigationTitle("站点收藏").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(model.saving)
                        .accessibilityIdentifier("favorite.editor.cancel")
                }
                AppToolbarItem(placement: .confirmationAction, tone: .accent) {
                    Button { save() } label: {
                        if model.saving { ProgressView().accessibilityLabel("保存中") } else { Text("保存") }
                    }.disabled(!model.canSave).accessibilityIdentifier("favorite.editor.save")
                }
            }
            .confirmationDialog("从站点收藏移除这部作品？", isPresented: $removing, titleVisibility: .visible) {
                Button("移除收藏", role: .destructive) { save(remove: true) }
                    .accessibilityIdentifier("favorite.editor.confirm-remove")
            }
        }
        .presentationDetents(requestRemoval ? [.medium, .large] : [.large])
        .interactiveDismissDisabled(model.saving)
        .task {
            if model.form == nil { await model.reload(); publishState() }
        }
        .onChange(of: model.observedState) { _, _ in publishState() }
        .onDisappear { mutation?.cancel(); model.cancel() }
    }
    private var status: String {
        switch model.observedState {
        case .unknown: return model.needsVerification ? "结果待确认" : "待读取"
        case .notFavorited: return "未收藏"
        case .favorited(let group): return "已收藏 · \(group)"
        }
    }
    private func save(remove: Bool = false) {
        mutation = Task {
            let confirmed = await model.save(remove: remove)
            publishState()
            if confirmed { dismiss() }
        }
    }
    private func publishState() {
        if model.observedState == .unknown {
            if model.saving || model.needsVerification { onState(.unknown, nil) }
        } else if model.lastReadSucceeded {
            onState(model.observedState, model.form)
        }
    }
}

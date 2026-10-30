import Foundation
import ExViewerCore

@MainActor struct GalleryFavoriteClient {
    var isCurrent: () -> Bool
    var read: () async throws -> GalleryFavoriteForm
    var submit: (GalleryFavoriteRequest) async throws -> Void
    var willSubmit: () async -> Void = {}
    var didSubmit: () -> Void = {}

    static func live(reference: GalleryRef, session: SiteSession) -> Self {
        let revision = session.generation, owner = session.owner
        let current = { revision == session.generation && owner == session.owner }
        return Self(isCurrent: current, read: {
            guard session.hasCredentials else { throw ViewerError.authentication }
            let url = try GalleryFavoriteForm.endpoint(for: reference)
            return try GalleryFavoriteForm.read(await session.html(url), reference: reference)
        }, submit: { request in
            guard session.hasCredentials, current() else { throw ViewerError.stale }
            let response = try await session.html(request.url, method: "POST", body: request.body)
            try EHParser.check(response)
        }, willSubmit: {
            await FeedSnapshotCache.shared.invalidateFavorites(owner: owner)
        }, didSubmit: {
            if current() { session.favoriteChanged() }
        })
    }
}

@MainActor final class GalleryFavoriteEditorModel: ObservableObject {
    @Published private(set) var form: GalleryFavoriteForm?
    @Published var selection: Int?
    @Published var note = ""
    @Published private(set) var observedState: GalleryFavoriteState = .unknown
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var needsVerification = false
    @Published private(set) var error: String?
    private(set) var reads = 0
    private(set) var posts = 0
    private(set) var lastReadSucceeded = false
    private let client: GalleryFavoriteClient
    private var epoch = UUID()
    private var pending: (FavoriteAction, String)?
    var working: Bool { loading || saving }
    var noteBytes: Int { GalleryFavoriteForm.normalizedNote(note).utf8.count }
    var canSave: Bool {
        guard !working, !needsVerification, let form, let selection,
              noteBytes <= 200 || GalleryFavoriteForm.normalizedNote(note) == form.note else { return false }
        return !form.confirms(.move(selection), note: note)
    }
    var canRemove: Bool { !working && !needsVerification && form?.selectedGroup != nil }

    init(client: GalleryFavoriteClient, initialForm: GalleryFavoriteForm? = nil) {
        self.client = client
        if client.isCurrent(), let initialForm { _ = accept(initialForm, preserveDraft: false) }
    }

    func cancel() { epoch = UUID(); loading = false; saving = false }

    /// Returns true only when a pending edit has been observed on the server.
    @discardableResult func reload(preserveDraft: Bool = false) async -> Bool {
        guard !working, client.isCurrent() else { return false }
        let token = UUID(); epoch = token; loading = true; error = nil; lastReadSucceeded = false
        defer { if token == epoch { loading = false } }
        do {
            reads += 1
            let value = try await client.read()
            try Task.checkCancellation()
            guard epoch == token, client.isCurrent() else { return false }
            return accept(value, preserveDraft: preserveDraft)
        } catch is CancellationError { return false }
        catch {
            guard epoch == token, client.isCurrent() else { return false }
            self.error = ErrorMessages.message(error, fallback: "未能读取站点收藏，请重新读取。")
            return false
        }
    }

    @discardableResult func save(remove: Bool = false) async -> Bool {
        guard client.isCurrent(), remove ? canRemove : canSave, let form else { return false }
        lastReadSucceeded = false
        let action: FavoriteAction
        if remove { action = .remove }
        else { guard let selection else { return false }; action = .move(selection) }
        let attemptedNote = remove ? "" : GalleryFavoriteForm.normalizedNote(note)
        let request: GalleryFavoriteRequest
        do { request = try form.request(action: action, note: attemptedNote) }
        catch { self.error = ErrorMessages.message(error); return false }
        let token = UUID(); epoch = token; saving = true; error = nil
        defer { if epoch == token { saving = false } }
        await client.willSubmit()
        guard epoch == token, client.isCurrent(), !Task.isCancelled else { return false }
        pending = (action, attemptedNote)
        observedState = .unknown
        var submissionError: Error?
        posts += 1
        // Exactly one POST. Even on a lost response, verification is GET only.
        do { try await client.submit(request) } catch { submissionError = error }
        guard epoch == token, client.isCurrent(), !Task.isCancelled else { return false }
        defer { client.didSubmit() }
        do {
            reads += 1
            let value = try await client.read()
            try Task.checkCancellation()
            guard epoch == token, client.isCurrent() else { return false }
            let confirmed = accept(value, preserveDraft: true)
            if !confirmed, let submissionError {
                error = ErrorMessages.message(submissionError, fallback: "站点尚未显示这次修改，请检查后再保存。")
            }
            return confirmed
        } catch {
            guard epoch == token, client.isCurrent() else { return false }
            needsVerification = true
            self.error = "本次收藏操作结果尚未确认。请先刷新状态，再继续操作。"
            return false
        }
    }

    private func accept(_ value: GalleryFavoriteForm, preserveDraft: Bool) -> Bool {
        lastReadSucceeded = true
        form = value; observedState = value.state; needsVerification = false
        if !preserveDraft { selection = value.selectedGroup; note = value.note }
        guard let pending else { error = nil; return false }
        self.pending = nil
        if value.confirms(pending.0, note: pending.1) { error = nil; return true }
        error = "站点尚未显示这次修改，已保留你的选择；请检查后再保存。"
        return false
    }
}

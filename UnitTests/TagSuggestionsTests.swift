import XCTest
import ExViewerCore
@testable import ExViewer

final class TagSuggestionsTests: XCTestCase {
    @MainActor func testConcurrentVerificationsStayPacedWhenOneWaiterIsCancelled() async throws {
        let pacer = TagSuggestionPacer(interval: 0.08)
        try await pacer.wait()
        let tasks = (0..<3).map { _ in
            Task { @MainActor () -> TimeInterval? in
                do { try await pacer.wait(); return ProcessInfo.processInfo.systemUptime }
                catch { return nil }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        tasks[1].cancel()
        var starts: [TimeInterval] = []
        for task in tasks { if let time = await task.value { starts.append(time) } }
        let cancelled = await tasks[1].value
        XCTAssertNil(cancelled)
        XCTAssertEqual(starts.count, 2)
        try await pacer.wait()
        starts.append(ProcessInfo.processInfo.systemUptime)
        starts.sort()
        for index in 1..<starts.count {
            XCTAssertGreaterThanOrEqual(starts[index] - starts[index - 1], 0.075,
                                        "Actual releases must stay separated after concurrent waits")
        }
    }

    @MainActor func testUnsupportedCandidateRemainsUnselectableWhenReusedFromCache() async {
        let unsupported = TagSuggestion(tag: .init(namespace: "temp", name: "temporary"), source: .unsupported,
                                        chineseName: nil, relatedMaster: nil)
        let cached = TagSuggestionModel.cached(unsupported)
        XCTAssertEqual(cached.source, .unsupported)
        XCTAssertFalse(TagSuggestionRequest.isSelectable(cached.tag))
        let cachedAgain = TagSuggestionModel.cached(cached)
        XCTAssertEqual(cachedAgain.source, .unsupported)
        XCTAssertFalse(TagSuggestionRequest.isSelectable(cachedAgain.tag))
    }
    func testOfficialPayloadUsesNumericMapKeysAndOptionalSlaveMetadata() throws {
        let data = Data(#"{"tags":{"1058":{"ns":"language","tn":"english"},"7":{"tn":"sample","mns":"other","mtn":"root"}}}"#.utf8)
        let values = try EHTagSuggestionResponse.parse(data)
        XCTAssertEqual(values.map(\.tag.id), ["language:english", "other:sample"])
        XCTAssertEqual(values.first?.relatedMaster, nil)
        XCTAssertEqual(values.last?.relatedMaster, GalleryTag(namespace: "other", name: "root"))
    }

    func testEmptyArrayIsValidNoResultsPayload() throws {
        XCTAssertTrue(try EHTagSuggestionResponse.parse(Data(#"{"tags":[]}"#.utf8)).isEmpty)
        XCTAssertTrue(try EHTagSuggestionResponse.parse(Data("[]".utf8)).isEmpty)
    }

    func testSiteErrorPayloadNeverSurfacesServerText() {
        let data = Data(#"{"error":"private diagnostic example"}"#.utf8)
        XCTAssertThrowsError(try EHTagSuggestionResponse.parse(data)) { error in
            XCTAssertEqual(error as? TagSuggestionFailure, .site)
            XCTAssertFalse(error.localizedDescription.contains("private diagnostic example"))
        }
    }

    func testAllNamespaceRequestUsesPlainPrefixAndRetainsEveryReturnedNamespace() throws {
        let payload = Data(#"{"tags":{"1":{"ns":"language","tn":"english"},"2":{"ns":"temp","tn":"temporary"}}}"#.utf8)
        let parsed = try EHTagSuggestionResponse.parse(payload)
        XCTAssertEqual(TagSuggestionRequest.text(prefix: "english", namespace: "all"), "english")
        XCTAssertEqual(TagSuggestionRequest.text(prefix: "eng", namespace: "language"), "language:eng")
        XCTAssertEqual(TagSuggestionRequest.matching(parsed, namespace: "all").map(\.tag.namespace), ["language", "temp"])
        XCTAssertEqual(TagSuggestionRequest.matching(parsed, namespace: "language").map(\.tag.namespace), ["language"])
        XCTAssertTrue(TagSuggestionRequest.isSelectable(GalleryTag(namespace: "language", name: "english")))
        XCTAssertFalse(TagSuggestionRequest.isSelectable(GalleryTag(namespace: "temp", name: "temporary")))
    }

    func testLocalChineseAndOriginalNameMatchesRemainUnverifiedDictionaryResults() {
        let catalog = TagTranslationCatalog(
            version: "fixture-v1", source: "EhTagTranslation/Database", commit: "fixture-commit",
            license: "CC BY-NC-SA 3.0 CN", updatedAt: nil,
            namespaces: ["language": ["english": "英语", "japanese": "日语"], "artist": ["sample artist": "样例作者"]]
        )
        let chinese = catalog.matches("英语", namespace: "all")
        XCTAssertEqual(chinese.map(\.tag.id), ["language:english"])
        XCTAssertEqual(chinese.first?.source, .dictionary)
        XCTAssertEqual(chinese.first?.chineseName, "英语")
        XCTAssertEqual(catalog.matches("sample", namespace: "artist").first?.tag.name, "sample artist")
        XCTAssertTrue(catalog.matches("英语", namespace: "artist").isEmpty)
        XCTAssertTrue(catalog.information.contains("非全站标签目录"))
    }

    @MainActor func testDelayedQACandidateFromPriorQueryCannotReplaceCurrentResults() async throws {
        let model = TagSuggestionModel(catalog: nil)
        let session = SiteSession(qa: true)
        model.update(prefix: "english", namespace: "all", session: session, qa: true, arguments: ["--qa-tags-delayed"])
        try await Task.sleep(nanoseconds: 100_000_000)
        model.update(prefix: "prev", namespace: "all", session: session, qa: true, arguments: ["--qa-tags-delayed"])
        for _ in 0..<180 {
            if model.items.first?.tag.id == "artist:preview" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.items.map(\.tag.id), ["artist:preview"])
        XCTAssertEqual(model.items.first?.source, .qaFixture)
    }

    func testCancelledLocalWorkerReturnsNoPartialResults() async {
        let values = Dictionary(uniqueKeysWithValues: (0..<4_000).map { ("tag-\($0)", "中文标签\($0)") })
        let catalog = TagTranslationCatalog(version: "fixture-v1", source: "test", commit: "fixture", license: "test", updatedAt: nil, namespaces: ["other": values])
        let worker = Task.detached { () -> [TagSuggestion] in
            withUnsafeCurrentTask { $0?.cancel() }
            return catalog.matches("中文", namespace: "all")
        }
        let matches = await worker.value
        XCTAssertTrue(matches.isEmpty)
    }

    func testLargeLocalMatchSetIsCappedBeforeReturning() {
        let values = Dictionary(uniqueKeysWithValues: (0..<4_000).map { ("tag-\($0)", "中文标签\($0)") })
        let catalog = TagTranslationCatalog(version: "fixture-v1", source: "test", commit: "fixture", license: "test", updatedAt: nil, namespaces: ["other": values])
        XCTAssertEqual(catalog.matches("tag", namespace: "all").count, 20)
    }
}

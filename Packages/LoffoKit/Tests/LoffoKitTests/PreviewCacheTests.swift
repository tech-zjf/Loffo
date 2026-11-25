import Foundation
import LoffoDomain
import Testing

@testable import LoffoFeatures

@Test @MainActor func previewCacheSeparatesModesAndEvictsWithinTheAppBudget() {
    let cache = PreviewCache(maximumEntries: 2, maximumBytes: 128)
    let firstWorkspace = URL(fileURLWithPath: "/project-one")
    let secondWorkspace = URL(fileURLWithPath: "/project-two")
    cache.acquire(workspace: firstWorkspace)
    cache.acquire(workspace: firstWorkspace)
    cache.acquire(workspace: secondWorkspace)
    cache.insert(
        CodePresentation(text: "one"), workspace: firstWorkspace, path: "a",
        comparison: false, expanded: false, version: 1)
    cache.insert(
        CodePresentation(text: "two"), workspace: firstWorkspace, path: "b",
        comparison: false, expanded: false, version: 1)
    #expect(
        cache.value(workspace: firstWorkspace, path: "a", comparison: true, expanded: false) == nil)
    #expect(
        cache.value(workspace: firstWorkspace, path: "a", comparison: false, expanded: false)?.text == "one")
    #expect(cache.value(workspace: secondWorkspace, path: "a", comparison: false, expanded: false) == nil)
    cache.insert(
        CodePresentation(text: "new"), workspace: firstWorkspace, path: "c",
        comparison: false, expanded: false, version: 2)
    #expect(cache.value(workspace: firstWorkspace, path: "b", comparison: false, expanded: false) == nil)
    cache.insert(
        CodePresentation(text: "old"), workspace: firstWorkspace, path: "c",
        comparison: false, expanded: false, version: 1)
    #expect(
        cache.value(workspace: firstWorkspace, path: "c", comparison: false, expanded: false)?.text == "new")
    cache.insert(
        CodePresentation(text: String(repeating: "x", count: 33)), workspace: firstWorkspace,
        path: "large", comparison: false, expanded: false, version: 1)
    #expect(
        cache.value(workspace: firstWorkspace, path: "large", comparison: false, expanded: false) == nil)
    #expect(cache.bytes <= 128)
    cache.release(workspace: firstWorkspace)
    #expect(
        cache.value(workspace: firstWorkspace, path: "c", comparison: false, expanded: false)?.text == "new")
    cache.release(workspace: firstWorkspace)
    #expect(
        cache.value(workspace: firstWorkspace, path: "c", comparison: false, expanded: false) == nil)
    #expect(cache.bytes == 0)
    cache.release(workspace: secondWorkspace)
    cache.removeAll()
    #expect(cache.bytes == 0)
}

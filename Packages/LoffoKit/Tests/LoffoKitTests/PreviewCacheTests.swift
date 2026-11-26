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
        comparison: false, expanded: false, version: 1, generation: cache.generation)
    cache.insert(
        CodePresentation(text: "two"), workspace: firstWorkspace, path: "b",
        comparison: false, expanded: false, version: 1, generation: cache.generation)
    #expect(
        cache.value(workspace: firstWorkspace, path: "a", comparison: true, expanded: false) == nil)
    #expect(
        cache.value(workspace: firstWorkspace, path: "a", comparison: false, expanded: false)?.text == "one")
    #expect(cache.value(workspace: secondWorkspace, path: "a", comparison: false, expanded: false) == nil)
    cache.insert(
        CodePresentation(text: "new"), workspace: firstWorkspace, path: "c",
        comparison: false, expanded: false, version: 2, generation: cache.generation)
    #expect(cache.value(workspace: firstWorkspace, path: "b", comparison: false, expanded: false) == nil)
    cache.insert(
        CodePresentation(text: "old"), workspace: firstWorkspace, path: "c",
        comparison: false, expanded: false, version: 1, generation: cache.generation)
    #expect(
        cache.value(workspace: firstWorkspace, path: "c", comparison: false, expanded: false)?.text == "new")
    cache.insert(
        CodePresentation(text: String(repeating: "x", count: 33)), workspace: firstWorkspace,
        path: "large", comparison: false, expanded: false, version: 1, generation: cache.generation)
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

@Test @MainActor func invalidatedCacheRejectsAnOlderWindowsInFlightResult() {
    let cache = PreviewCache()
    let workspace = URL(fileURLWithPath: "/project")
    let oldGeneration = cache.generation
    cache.remove(workspace: workspace, path: "file", comparison: true)
    cache.insert(
        CodePresentation(text: "obsolete"), workspace: workspace, path: "file", comparison: true,
        expanded: false, version: 1, generation: oldGeneration)
    #expect(cache.value(workspace: workspace, path: "file", comparison: true, expanded: false) == nil)
    cache.insert(
        CodePresentation(text: "current"), workspace: workspace, path: "file", comparison: true,
        expanded: false, version: 2, generation: cache.generation)
    #expect(
        cache.value(workspace: workspace, path: "file", comparison: true, expanded: false)?.text == "current")
}

@Test @MainActor func discardingPreviewsKeepsActiveValueAndRejectsOlderResults() {
    let cache = PreviewCache()
    let workspace = URL(fileURLWithPath: "/project")
    let generation = cache.generation
    cache.insert(
        CodePresentation(text: "visible"), workspace: workspace, path: "file", comparison: false,
        expanded: false, version: 1, generation: generation)
    let active = cache.value(workspace: workspace, path: "file", comparison: false, expanded: false)
    cache.removeAll()
    cache.insert(
        CodePresentation(text: "obsolete"), workspace: workspace, path: "file", comparison: false,
        expanded: false, version: 1, generation: generation)
    #expect(active?.text == "visible")
    #expect(cache.bytes == 0)
    #expect(cache.value(workspace: workspace, path: "file", comparison: false, expanded: false) == nil)
}

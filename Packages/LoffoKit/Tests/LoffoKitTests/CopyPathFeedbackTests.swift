import Foundation
import Testing

@testable import LoffoFeatures

@Test @MainActor func copyPathConfirmationExpiresAfterThreeSeconds() async throws {
    let feedback = CopyPathFeedback()
    var received: String?
    feedback.copy("目录/file.swift") {
        received = $0
        return true
    }
    #expect(received == "目录/file.swift")
    #expect(feedback.isCopied)
    try await Task.sleep(for: .milliseconds(2_500))
    #expect(feedback.isCopied)
    for _ in 0..<200 where feedback.isCopied { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!feedback.isCopied)
}

@Test @MainActor func copyPathFailureAndSelectionResetClearConfirmation() async throws {
    let feedback = CopyPathFeedback(duration: .milliseconds(250))
    feedback.copy("first") { _ in true }
    #expect(feedback.isCopied)
    feedback.copy("second") { _ in false }
    #expect(!feedback.isCopied)
    feedback.copy("third") { _ in true }
    try await Task.sleep(for: .milliseconds(150))
    feedback.copy("fourth") { _ in true }
    try await Task.sleep(for: .milliseconds(150))
    #expect(feedback.isCopied, "An older timer must not clear a newer confirmation")
    feedback.reset()
    #expect(!feedback.isCopied)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!feedback.isCopied)
}

import Foundation
import LoffoDomain

/// Reserves a conservative estimated allowance before loading. Copies retain the same lease.
final class BaselineLease: Sendable {
    static let reservedBytes = 8 * 1_024 * 1_024
    private let admission: WorkAdmission
    init(admission: WorkAdmission) { self.admission = admission }
    deinit {
        let admission = admission
        Task { await admission.release(bytes: Self.reservedBytes) }
    }
}

struct BaselineSnapshot: Sendable {
    let intent: UUID
    let text: String
    let label: String
    let revision: String?
    let lease: BaselineLease
}

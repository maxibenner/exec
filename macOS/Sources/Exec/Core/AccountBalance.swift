import Foundation

/// Provider-reported account credit, separate from subscription allowance and token usage.
struct AccountBalance: Codable, Equatable, Sendable {
    let amount: Decimal
    let currency: String
}

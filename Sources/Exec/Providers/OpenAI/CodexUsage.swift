import Foundation

enum CodexUsage {
    static func request(accessToken: String, accountID: String) -> URLRequest {
        var request = CodexConnection.request(path: "", accessToken: accessToken, accountID: accountID)
        request.url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return request
    }

    static func decode(_ data: Data) throws -> AccountUsage? {
        struct Response: Decodable {
            struct Limits: Decodable {
                struct Window: Decodable {
                    let used_percent: Double
                    let limit_window_seconds: Int
                    let reset_at: Double
                }
                let primary_window: Window?
                let secondary_window: Window?
            }
            let rate_limit: Limits?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let windows = [response.rate_limit?.primary_window, response.rate_limit?.secondary_window].compactMap { window -> AccountUsage.Window? in
            guard let window, window.used_percent.isFinite, (0...100).contains(window.used_percent),
                  window.limit_window_seconds > 0, window.reset_at.isFinite, window.reset_at > 0 else { return nil }
            return .init(durationSeconds: window.limit_window_seconds, usedPercent: window.used_percent,
                         resetsAt: Date(timeIntervalSince1970: window.reset_at))
        }
        return windows.isEmpty ? nil : AccountUsage(windows: windows)
    }
}

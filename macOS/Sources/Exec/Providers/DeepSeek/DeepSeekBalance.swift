import Foundation

enum DeepSeekBalance {
    static func decode(_ data: Data) throws -> [AccountBalance] {
        struct Response: Decodable {
            struct Balance: Decodable { let currency: String; let total_balance: String }
            let balance_infos: [Balance]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.balance_infos.isEmpty else { throw ExecError("DeepSeek balance is unavailable.") }
        return try response.balance_infos.map { balance in
            guard ["USD", "CNY"].contains(balance.currency),
                  balance.total_balance.count <= 64,
                  balance.total_balance.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let amount = Decimal(string: balance.total_balance, locale: Locale(identifier: "en_US_POSIX")),
                  !amount.isNaN else { throw ExecError("DeepSeek returned an invalid balance.") }
            return AccountBalance(amount: amount, currency: balance.currency)
        }
    }
}

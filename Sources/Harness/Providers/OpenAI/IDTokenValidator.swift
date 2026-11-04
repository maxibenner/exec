import Foundation
import Security

// Validate OIDC identity before accepting or replacing credentials. RS256 is the
// algorithm advertised by OpenAI discovery; all other algorithms fail closed.
enum IDTokenValidator {
    struct Identity { let subject: String; let email: String?; let accountID: String? }

    static func validate(_ token: String, clientID: String, nonce: String) async throws -> Identity {
        let (data, response) = try await OpenAIHTTP.session.data(from: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        try OpenAIHTTP.check(response)
        return try verify(token, clientID: clientID, nonce: nonce, jwks: data)
    }

    static func verify(_ token: String, clientID: String, nonce: String, jwks: Data) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = decode(parts[0]), let claimsData = decode(parts[1]),
              let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else {
            throw HarnessError("Invalid identity token.")
        }
        let keys = try JSONDecoder().decode(KeySet.self, from: jwks)
        guard let key = keys.keys.first(where: { $0.kid == kid && $0.kty == "RSA" }),
              let n = decode(key.n), let e = decode(key.e) else { throw HarnessError("Unknown identity signing key.") }
        let der = element(0x30, integer(n) + integer(e))
        guard let publicKey = SecKeyCreateWithData(der as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil) else {
            throw HarnessError("Identity signature verification failed.")
        }
        let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any] ?? [:]
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == OpenAIHTTP.auth,
              audience.contains(clientID),
              (audience.count == 1 || claims["azp"] as? String == clientID),
              (claims["azp"] == nil || claims["azp"] as? String == clientID),
              (claims["nbf"] == nil || (claims["nbf"] as? Double ?? .infinity) <= Date().timeIntervalSince1970),
              let expiry = claims["exp"] as? Double, expiry > Date().timeIntervalSince1970,
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw HarnessError("Identity claims did not match this sign-in attempt.")
        }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return Identity(subject: subject, email: claims["email"] as? String, accountID: auth?["chatgpt_account_id"] as? String)
    }

    static func decode(_ value: String) -> Data? {
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }

    private struct KeySet: Decodable {
        struct Key: Decodable { let kid: String; let kty: String; let n: String; let e: String }
        let keys: [Key]
    }

    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return element(0x02, bytes)
    }

    private static func element(_ tag: UInt8, _ content: Data) -> Data {
        var length = content.count
        if length < 128 { return Data([tag, UInt8(length)]) + content }
        var bytes: [UInt8] = []
        while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
        return Data([tag, 0x80 | UInt8(bytes.count)] + bytes) + content
    }
}

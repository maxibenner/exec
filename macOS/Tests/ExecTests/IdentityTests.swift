import Foundation
import Security

struct IdentityTests {
    func verifiesSignatureAndRejectsInvalidClaims() throws {
        let privateKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let der = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        var offset = 0
        let sequence = readElement(Array(der), offset: &offset)
        offset = 0
        let modulus = readElement(sequence, offset: &offset)
        let exponent = readElement(sequence, offset: &offset)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "test", "kty": "RSA", "n": base64(Data(modulus)), "e": base64(Data(exponent))
        ]]])
        let claims: [String: Any] = [
            "iss": "https://auth.openai.com", "sub": "account", "aud": "client",
            "nonce": "nonce", "email": "test@example.com", "exp": Date().timeIntervalSince1970 + 600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "workspace"]
        ]
        func token(_ claims: [String: Any], algorithm: String = "RS256") throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "test"])
            let body = try JSONSerialization.data(withJSONObject: claims)
            let input = "\(base64(header)).\(base64(body))"
            let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
            return input + "." + base64(signature)
        }
        let valid = try token(claims)
        let identity = try IDTokenValidator.verify(valid, clientID: "client", nonce: "nonce", jwks: jwks)
        try expect(identity.subject == "account")
        try expect(identity.email == "test@example.com")
        try expect(identity.accountID == "workspace")
        for (key, value) in [
            ("iss", "https://untrusted.example" as Any), ("aud", "other" as Any),
            ("nonce", "wrong" as Any), ("exp", 0 as Any), ("azp", "other" as Any),
            ("nbf", Date().timeIntervalSince1970 + 600 as Any)
        ] {
            var changed = claims
            changed[key] = value
            try expectFailure { _ = try IDTokenValidator.verify(token(changed), clientID: "client", nonce: "nonce", jwks: jwks) }
        }
        try expectFailure { _ = try IDTokenValidator.verify(token(claims, algorithm: "none"), clientID: "client", nonce: "nonce", jwks: jwks) }
        var parts = valid.split(separator: ".").map(String.init)
        var forged = claims
        forged["sub"] = "attacker"
        parts[1] = base64(try JSONSerialization.data(withJSONObject: forged))
        try expectFailure { _ = try IDTokenValidator.verify(parts.joined(separator: "."), clientID: "client", nonce: "nonce", jwks: jwks) }
    }

    private func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // Test-only reader for the two INTEGERs in Security's PKCS#1 RSA public key.
    private func readElement(_ bytes: [UInt8], offset: inout Int) -> [UInt8] {
        offset += 1
        var length = Int(bytes[offset]); offset += 1
        if length & 128 != 0 {
            let count = length & 127
            length = 0
            for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
        }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }
}

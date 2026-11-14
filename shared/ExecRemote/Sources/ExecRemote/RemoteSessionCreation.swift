/// Provider-neutral model options, copied into per-session settings without
/// modifying the host's shared defaults.
public enum RemoteSessionCreation {
    public static func initialEffort(model: RemoteJSON, settings: RemoteJSON) -> String {
        let supported = model["efforts"].array.compactMap { $0["id"].string }
        let preferred = settings["effort"].string ?? model["defaultEffort"].string ?? ""
        return supported.contains(preferred) ? preferred : ""
    }

    public static func body(workspace: String, model: RemoteJSON, effort: String, settings: RemoteJSON) -> RemoteJSON {
        var fields: [String: RemoteJSON]
        if case .object(let existing) = settings { fields = existing }
        else { fields = ["systemPrompt": .string(""), "autoApprove": .bool(false)] }
        let supported = model["efforts"].array.contains { $0["id"].string == effort }
        fields["effort"] = supported ? .string(effort) : .null
        return .object(["workspace": .string(workspace), "model": model["id"], "settings": .object(fields)])
    }
}

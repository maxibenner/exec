#if canImport(ExecTranscript)
import ExecTranscript
#endif

/// Provider-neutral options, copied into per-session settings without modifying
/// the host's shared defaults.
public enum RemoteSessionCreation {
    public typealias Tool = ToolDisplayMetadata

    /// Flat configuration order matching macOS's visible Inspect/Modify/Execute
    /// groups. Display metadata does not grant capabilities or bypass approvals.
    public static let tools: [Tool] = [
        "list_files", "read_file", "search_text", "web_search", "fetch_content", "take_screenshot",
        "edit_file", "generate_image", "shell"
    ].map { ToolDisplayMetadata(name: $0) }

    private static let alwaysEnabledTools: Set<String> = ["delegate", "wait"]

    public struct ToolSelection: Sendable {
        private let supported: Set<String>
        private let initialDisabled: Set<String>
        private let orchestrationOverride: [String]?
        public private(set) var disabledTools: Set<String>

        public init(library: RemoteJSON, supportedTools: [String] = RemoteSessionCreation.tools.map(\.id)) {
            supported = Set(supportedTools).subtracting(RemoteSessionCreation.alwaysEnabledTools)
            // Missing legacy defaults disable shell; an explicit [] enables all.
            let defaults: [String]
            if case .array(let names) = library["defaultDisabledTools"] {
                defaults = names.compactMap(\.string)
            } else {
                defaults = ["shell"]
            }
            let inherited = Set(defaults)
            let sessionDefaults = inherited.subtracting(RemoteSessionCreation.alwaysEnabledTools)
            initialDisabled = sessionDefaults.intersection(supported)
            disabledTools = initialDisabled
            // Untouched drafts must override disabled orchestration without
            // dropping other inherited names, including unavailable tools.
            orchestrationOverride = inherited == sessionDefaults ? nil : sessionDefaults.sorted()
        }

        public func isEnabled(_ name: String) -> Bool {
            RemoteSessionCreation.alwaysEnabledTools.contains(name)
                || (supported.contains(name) && !disabledTools.contains(name))
        }

        public mutating func setEnabled(_ name: String, _ enabled: Bool) {
            guard supported.contains(name) else { return }
            if enabled { disabledTools.remove(name) }
            else { disabledTools.insert(name) }
        }

        /// Unchanged selections inherit defaults unless orchestration needs an
        /// override. Edited selections contain only supported names; [] is
        /// intentional and must not become null or omission.
        public var creationDisabledTools: [String]? {
            disabledTools == initialDisabled ? orchestrationOverride : disabledTools.sorted()
        }
    }

    public static func initialEffort(model: RemoteJSON, settings: RemoteJSON) -> String {
        let supported = model["efforts"].array.compactMap { $0["id"].string }
        let preferred = settings["effort"].string ?? model["defaultEffort"].string ?? ""
        return supported.contains(preferred) ? preferred : ""
    }

    public static func body(workspace: String, model: RemoteJSON, effort: String, settings: RemoteJSON,
                            tools: ToolSelection? = nil) -> RemoteJSON {
        var fields: [String: RemoteJSON]
        if case .object(let existing) = settings { fields = existing }
        else { fields = ["systemPrompt": .string(""), "autoApprove": .bool(false)] }
        let supported = model["efforts"].array.contains { $0["id"].string == effort }
        fields["effort"] = supported ? .string(effort) : .null
        var body: [String: RemoteJSON] = ["workspace": .string(workspace), "model": model["id"], "settings": .object(fields)]
        if let disabled = tools?.creationDisabledTools {
            body["disabledTools"] = .array(disabled.map(RemoteJSON.string))
        }
        return .object(body)
    }
}

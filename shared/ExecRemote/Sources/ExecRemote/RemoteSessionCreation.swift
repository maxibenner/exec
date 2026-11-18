/// Provider-neutral options, copied into per-session settings without modifying
/// the host's shared defaults.
public enum RemoteSessionCreation {
    public struct Tool: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let icon: String
    }

    /// The bundled host's catalog, matching macOS SessionTool. Selection does not
    /// grant runtime capabilities or bypass tool approvals.
    public static let tools: [Tool] = [
        .init(id: "list_files", label: "List files", icon: "folder"),
        .init(id: "read_file", label: "Read file", icon: "doc.text"),
        .init(id: "search_text", label: "Search text", icon: "magnifyingglass"),
        .init(id: "edit_file", label: "Edit file", icon: "pencil"),
        .init(id: "shell", label: "Run shell command", icon: "terminal"),
        .init(id: "web_search", label: "Search the web", icon: "globe"),
        .init(id: "fetch_content", label: "Fetch web page", icon: "doc.text"),
        .init(id: "generate_image", label: "Generate image", icon: "photo"),
        .init(id: "take_screenshot", label: "Take screenshot", icon: "camera"),
        .init(id: "delegate", label: "Delegate to sub-agents", icon: "person.2"),
        .init(id: "wait", label: "Wait", icon: "stopwatch")
    ]

    public struct ToolSelection: Sendable {
        private let supported: Set<String>
        private let initialDisabled: Set<String>
        public private(set) var disabledTools: Set<String>

        public init(library: RemoteJSON, supportedTools: [String] = RemoteSessionCreation.tools.map(\.id)) {
            supported = Set(supportedTools)
            // Missing legacy defaults disable shell; an explicit [] enables all.
            let defaults: [String]
            if case .array(let names) = library["defaultDisabledTools"] {
                defaults = names.compactMap(\.string)
            } else {
                defaults = ["shell"]
            }
            initialDisabled = Set(defaults).intersection(supported)
            disabledTools = initialDisabled
        }

        public func isEnabled(_ name: String) -> Bool {
            supported.contains(name) && !disabledTools.contains(name)
        }

        public mutating func setEnabled(_ name: String, _ enabled: Bool) {
            guard supported.contains(name) else { return }
            if enabled { disabledTools.remove(name) }
            else { disabledTools.insert(name) }
        }

        /// Omission preserves backend inheritance, including unavailable default
        /// names. Edited selections must contain only supported names; [] is
        /// intentional and must not become null or omission.
        public var creationDisabledTools: [String]? {
            disabledTools == initialDisabled ? nil : disabledTools.sorted()
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

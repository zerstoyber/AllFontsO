import FontsoCore
import Foundation

enum ResearchSettings {
    static let kindKey = "fontso.research.kind"
    static let baseURLKey = "fontso.research.baseURL"
    static let modelKey = "fontso.research.model"
    static let labelKey = "fontso.research.label"
    static let workspaceKey = "fontso.research.workspace"

    static var kind: String {
        get { UserDefaults.standard.string(forKey: kindKey) ?? "apple" }
        set { UserDefaults.standard.set(newValue, forKey: kindKey) }
    }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var label: String {
        get { UserDefaults.standard.string(forKey: labelKey) ?? "Apple Intelligence" }
        set { UserDefaults.standard.set(newValue, forKey: labelKey) }
    }

    static var workspaceID: String {
        get { UserDefaults.standard.string(forKey: workspaceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: workspaceKey) }
    }

    static func useApple() {
        kind = "apple"
        label = "Apple Intelligence"
    }

    static func useCompatible(baseURL: String, model: String, label: String) {
        kind = "compatible"
        self.baseURL = baseURL
        self.model = model
        self.label = label
    }

    static func useAnthropic(model: String, workspaceID: String) {
        kind = "anthropic"
        self.model = model
        self.workspaceID = workspaceID
        label = "Claude · \(model)"
    }
}

enum ResearchKeychain {
    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fontso", isDirectory: true)
        return base.appendingPathComponent("research-key")
    }

    static func save(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? trimmed.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func load() -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ResearchChoice: Identifiable, Hashable {
    var id: String
    var title: String
    var kind: String
    var baseURL: String
    var model: String
}

enum ResearchConnection {
    static func complete(
        history: [ResearchMessage],
        faces: [FontFace],
        lists: [ResearchList] = []
    ) async throws -> ResearchTurn {
        if let turn = ResearchDialogue.followUp(history: history, faces: faces, lists: lists) {
            if turn.listName != nil { return turn }
            return await speak(turn, history: history)
        }
        if let turn = ResearchDialogue.libraryAnswer(history: history, faces: faces) {
            return await speak(turn, history: history)
        }
        let text: String
        switch ResearchSettings.kind {
        case "anthropic":
            text = try await anthropic(history: history, faces: faces)
        case "compatible":
            text = try await compatible(history: history, faces: faces)
        default:
            let latest = history.last(where: { $0.role == "user" })?.text ?? ""
            let shown = history.flatMap(\.suggestions).map(\.family)
            let cards = FontResearch.candidates(in: faces, query: latest, avoiding: shown, limit: 24)
            text = try await ResearchAssistant.reply(history: history, candidates: cards)
        }
        return ResearchDialogue.repair(text, history: history, faces: faces, lists: lists)
    }

    static func discover() async -> [ResearchChoice] {
        var found = [ResearchChoice(id: "apple", title: "Apple Intelligence", kind: "apple", baseURL: "", model: "")]
        if let names = try? await modelIDs(url: "http://127.0.0.1:11434/api/tags", keyPath: "models", nameKey: "name") {
            for name in names {
                found.append(ResearchChoice(
                    id: "ollama:\(name)",
                    title: "Ollama · \(name)",
                    kind: "compatible",
                    baseURL: "http://127.0.0.1:11434/v1",
                    model: name
                ))
            }
        }
        if let names = try? await modelIDs(url: "http://127.0.0.1:1234/v1/models", keyPath: "data", nameKey: "id") {
            for name in names {
                found.append(ResearchChoice(
                    id: "lmstudio:\(name)",
                    title: "LM Studio · \(name)",
                    kind: "compatible",
                    baseURL: "http://127.0.0.1:1234/v1",
                    model: name
                ))
            }
        }
        return found
    }

    private static func compatible(history: [ResearchMessage], faces: [FontFace]) async throws -> String {
        let root = ResearchSettings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: root.hasSuffix("/") ? root + "chat/completions" : root + "/chat/completions") else {
            throw FontsoError.message("The model address is not a valid URL.")
        }
        let latest = history.last(where: { $0.role == "user" })?.text ?? ""
        var messages: [[String: Any]] = [["role": "system", "content": ResearchPrompt.instructions(for: latest)]]
        for message in history where message.role == "user" || message.role == "assistant" {
            messages.append(["role": message.role, "content": message.text])
        }
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "search_fonts",
                "description": "Search the user's AllFontsO library. Call this before naming any font.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "What the font should feel like or be used for."]],
                    "required": ["query"]
                ]
            ]
        ]]
        for _ in 0..<4 {
            let body: [String: Any] = [
                "model": ResearchSettings.model,
                "messages": messages,
                "tools": tools
            ]
            let payload = try await post(url: url, body: body, bearer: ResearchKeychain.load(), anthropic: false)
            guard let choice = (payload["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else {
                throw FontsoError.message("The model sent an unexpected reply.")
            }
            if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                messages.append(message)
                for call in calls {
                    let id = call["id"] as? String ?? UUID().uuidString
                    let function = call["function"] as? [String: Any]
                    let arguments = function?["arguments"] as? String ?? "{}"
                    let query = queryArgument(arguments)
                    let result = searchText(query: query, faces: faces)
                    messages.append(["role": "tool", "tool_call_id": id, "content": result])
                }
                continue
            }
            let text = (message["content"] as? String)?.cleanedFontName ?? ""
            if text.isEmpty { throw FontsoError.message("The model did not reply.") }
            return text
        }
        throw FontsoError.message("The model kept searching and did not answer.")
    }

    /// Claude writes the sentence. The font choice and the list change stay with the library.
    private static func speak(_ turn: ResearchTurn, history: [ResearchMessage]) async -> ResearchTurn {
        guard ResearchSettings.kind == "anthropic" else { return turn }
        guard let spoken = try? await phrase(turn, history: history) else { return turn }
        let text = spoken.cleanedFontName.replacingOccurrences(of: "**", with: "")
        guard text.count > 12,
              !ResearchDialogue.isRefusal(text),
              !ResearchDialogue.isInstructionLeak(text),
              !text.localizedCaseInsensitiveContains("neustart"),
              !text.localizedCaseInsensitiveContains("restart") else { return turn }
        var voiced = turn
        voiced.text = text
        return voiced
    }

    private static func phrase(_ turn: ResearchTurn, history: [ResearchMessage]) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return turn.text }
        let key = ResearchKeychain.load()
        guard !key.isEmpty else { return turn.text }
        let latest = history.last { $0.role == "user" }?.text ?? ""
        let fonts = turn.suggestions.prefix(12).map { suggestion in
            suggestion.reason.isEmpty ? suggestion.family : "\(suggestion.family): \(suggestion.reason)"
        }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": ResearchSettings.model.isEmpty ? "claude-haiku-4-5" : ResearchSettings.model,
            "max_tokens": 350,
            "system": "You are talking with the user inside their font manager. Answer the latest message in its language, in two or three sentences. Use only the facts and the fonts listed. Write font names as plain words, without asterisks or markdown. A named style exists. Do not say a cut is missing, do not add fonts, do not mention instructions, and do not refuse.",
            "messages": [[
                "role": "user",
                "content": "Latest message:\n\(latest)\n\nFacts:\n\(turn.text)\n\nFonts:\n\(fonts)"
            ]]
        ]
        let payload = try await post(url: url, body: body, bearer: key, anthropic: true)
        let blocks = payload["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    private static func anthropic(history: [ResearchMessage], faces: [FontFace]) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw FontsoError.message("Claude's address is invalid.")
        }
        let key = ResearchKeychain.load()
        guard !key.isEmpty else { throw FontsoError.message("Add a Claude API key in Model.") }
        var messages: [[String: Any]] = history.filter { $0.role == "user" || $0.role == "assistant" }.map {
            ["role": $0.role, "content": $0.text]
        }
        let tools: [[String: Any]] = [[
            "name": "search_fonts",
            "description": "Search the user's AllFontsO library. Call this before naming any font.",
            "input_schema": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"]
            ]
        ]]
        for _ in 0..<4 {
            let body: [String: Any] = [
                "model": ResearchSettings.model.isEmpty ? "claude-haiku-4-5" : ResearchSettings.model,
                "max_tokens": 1200,
                "system": ResearchPrompt.instructions(for: history.last(where: { $0.role == "user" })?.text ?? ""),
                "messages": messages,
                "tools": tools
            ]
            let payload = try await post(url: url, body: body, bearer: key, anthropic: true)
            let blocks = payload["content"] as? [[String: Any]] ?? []
            let toolUses = blocks.filter { ($0["type"] as? String) == "tool_use" }
            if !toolUses.isEmpty {
                messages.append(["role": "assistant", "content": blocks])
                let results: [[String: Any]] = toolUses.map { block in
                    let query = (block["input"] as? [String: Any])?["query"] as? String ?? ""
                    return [
                        "type": "tool_result",
                        "tool_use_id": block["id"] as? String ?? "",
                        "content": searchText(query: query, faces: faces)
                    ]
                }
                messages.append(["role": "user", "content": results])
                continue
            }
            let text = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n").cleanedFontName
            if text.isEmpty { throw FontsoError.message("Claude did not reply.") }
            return text
        }
        throw FontsoError.message("Claude kept searching and did not answer.")
    }

    private static func searchText(query: String, faces: [FontFace]) -> String {
        let cards = FontResearch.candidates(in: faces, query: query, limit: 20)
        if cards.isEmpty { return "No matching fonts in the library." }
        return cards.map(\.line).joined(separator: "\n")
    }

    private static func queryArgument(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? String else { return raw }
        return query
    }

    private static func modelIDs(url: String, keyPath: String, nameKey: String) async throws -> [String] {
        guard let endpoint = URL(string: url) else { return [] }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else { return [] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object[keyPath] as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[nameKey] as? String }
    }

    private static func post(url: URL, body: [String: Any], bearer: String, anthropic: Bool) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if anthropic {
            request.setValue(bearer, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let workspace = ResearchSettings.workspaceID.cleanedFontName
            if !workspace.isEmpty {
                request.setValue(workspace, forHTTPHeaderField: "anthropic-workspace-id")
            }
        } else if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FontsoError.message("The model did not respond.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FontsoError.message("The model sent a reply AllFontsO could not read.")
        }
        guard http.statusCode < 300 else {
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? "The model returned an error (\(http.statusCode))."
            if message.contains("anthropic-workspace-id") {
                throw FontsoError.message("This Claude key needs a workspace ID. In Model, open Workspaces, copy the ID that starts with wrkspc_, paste it under the key, and choose Use Claude again.")
            }
            throw FontsoError.message(message)
        }
        return object
    }
}

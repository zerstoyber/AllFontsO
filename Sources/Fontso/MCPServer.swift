import FontsoCore
import Foundation
import Network

/// Settings for letting another program drive AllFontsO over the Model Context Protocol. Off until the user switches it on.
enum MCPSettings {
    static let enabledKey = "fontso.mcp.enabled"
    static let preferredPort: UInt16 = 41417

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var portFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fontso", isDirectory: true)
            .appendingPathComponent("mcp-port")
    }

    static func endpoint(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "Fontso"
    }

    /// Configuration for programs that launch MCP servers themselves, such as Claude Desktop.
    static func stdioConfiguration() -> String {
        let path = executablePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "allfontso": {
              "command": "\(path)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }
}

/// A small Streamable HTTP server on 127.0.0.1 that answers MCP JSON-RPC requests with library tools.
@MainActor
final class MCPServer {
    private(set) var port: UInt16?
    private(set) var lastError: String?
    private var listener: NWListener?
    private weak var store: LibraryStore?
    private let sessionID = UUID().uuidString

    func start(store: LibraryStore) {
        guard listener == nil else { return }
        self.store = store
        lastError = nil
        var chosen: UInt16?
        for candidate in [MCPSettings.preferredPort, MCPSettings.preferredPort + 1, MCPSettings.preferredPort + 2] {
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            parameters.allowLocalEndpointReuse = true
            guard let next = try? NWListener(using: parameters) else { continue }
            next.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            next.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.listenerChanged(state, port: candidate)
                }
            }
            next.start(queue: .global(qos: .userInitiated))
            listener = next
            chosen = candidate
            break
        }
        guard let chosen else {
            lastError = "No local port was free for MCP."
            return
        }
        port = chosen
        writePortFile(chosen)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        try? FileManager.default.removeItem(at: MCPSettings.portFile)
    }

    private func listenerChanged(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .failed(let error):
            lastError = error.localizedDescription
            listener = nil
            self.port = nil
        default:
            break
        }
    }

    private func writePortFile(_ port: UInt16) {
        let file = MCPSettings.portFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(port)".write(to: file, atomically: true, encoding: .utf8)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readRequest(connection, buffer: Data())
    }

    private nonisolated func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            if let request = HTTPRequest.parse(next) {
                Task { @MainActor in
                    let response = await self.respond(to: request)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }
            if complete || next.count > (1 << 22) {
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: next)
        }
    }

    private func respond(to request: HTTPRequest) async -> Data {
        guard request.path == "/mcp" || request.path == "/mcp/" || request.path == "/" else {
            return HTTPRequest.response(status: 404, body: Data("Not found".utf8), type: "text/plain")
        }
        if request.method == "OPTIONS" {
            return HTTPRequest.response(status: 204, body: Data(), type: "text/plain")
        }
        if request.method == "GET" {
            let text = "AllFontsO MCP. Send JSON-RPC 2.0 requests with POST."
            return HTTPRequest.response(status: 405, body: Data(text.utf8), type: "text/plain")
        }
        if request.method == "DELETE" {
            return HTTPRequest.response(status: 200, body: Data(), type: "text/plain")
        }
        guard request.method == "POST" else {
            return HTTPRequest.response(status: 405, body: Data(), type: "text/plain")
        }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) else {
            let error = MCPTools.errorEnvelope(id: nil, code: -32700, message: "The request was not JSON.")
            return HTTPRequest.response(status: 400, body: error, type: "application/json")
        }
        if let batch = json as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for message in batch {
                if let reply = await handle(message) { replies.append(reply) }
            }
            if replies.isEmpty {
                return HTTPRequest.response(status: 202, body: Data(), type: "application/json")
            }
            let data = (try? JSONSerialization.data(withJSONObject: replies)) ?? Data("[]".utf8)
            return HTTPRequest.response(status: 200, body: data, type: "application/json", session: sessionID)
        }
        guard let message = json as? [String: Any] else {
            let error = MCPTools.errorEnvelope(id: nil, code: -32600, message: "The request was not a JSON-RPC message.")
            return HTTPRequest.response(status: 400, body: error, type: "application/json")
        }
        guard let reply = await handle(message) else {
            return HTTPRequest.response(status: 202, body: Data(), type: "application/json", session: sessionID)
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        return HTTPRequest.response(status: 200, body: data, type: "application/json", session: sessionID)
    }

    private func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let store else { return nil }
        return await MCPTools.handle(message, store: store)
    }
}

/// JSON-RPC methods and the tools AllFontsO offers.
@MainActor
enum MCPTools {
    nonisolated static let protocolVersion = "2025-06-18"

    static func handle(_ message: [String: Any], store: LibraryStore) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        if id == nil {
            return nil
        }
        switch method {
        case "initialize":
            return envelope(id: id, result: initializeResult(params))
        case "ping":
            return envelope(id: id, result: [:])
        case "tools/list":
            return envelope(id: id, result: ["tools": toolDescriptions()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, arguments: arguments, store: store)
                return envelope(id: id, result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ])
            } catch {
                return envelope(id: id, result: [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true
                ])
            }
        case "resources/list":
            return envelope(id: id, result: ["resources": []])
        case "prompts/list":
            return envelope(id: id, result: ["prompts": []])
        default:
            return errorObject(id: id, code: -32601, message: "Unknown method \(method).")
        }
    }

    /// The answer to initialize. The program's own protocol version is taken when it is one AllFontsO speaks, so
    /// older and newer programs both connect.
    nonisolated static func initializeResult(_ params: [String: Any]) -> [String: Any] {
        let asked = params["protocolVersion"] as? String ?? ""
        let spoken = ["2024-11-05", "2025-03-26", "2025-06-18"]
        return [
            "protocolVersion": spoken.contains(asked) ? asked : protocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "AllFontsO", "version": AppChrome.version],
            "instructions": "AllFontsO is the user's font manager on this Mac. Search the library before naming a font. Activation and lists change the user's system, so do only what they asked."
        ]
    }

    /// What the stdio bridge answers by itself while AllFontsO is closed or MCP is off. A program such as Claude
    /// Desktop starts the bridge when it launches, often before AllFontsO is open: it still connects and sees the
    /// tools, and a tool says what to do until AllFontsO is there.
    nonisolated static func offlineReply(_ message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String ?? "" {
        case "initialize":
            return envelope(id: id, result: initializeResult(params))
        case "ping":
            return envelope(id: id, result: [:])
        case "tools/list":
            return envelope(id: id, result: ["tools": toolDescriptions()])
        case "resources/list":
            return envelope(id: id, result: ["resources": []])
        case "prompts/list":
            return envelope(id: id, result: ["prompts": []])
        case "tools/call":
            return envelope(id: id, result: [
                "content": [["type": "text", "text": "AllFontsO is not answering. Ask the user to open AllFontsO and, under Chat › Model, choose Your own AI; then try again."]],
                "isError": true
            ])
        default:
            return errorObject(id: id, code: -32601, message: "Unknown method.")
        }
    }

    nonisolated static func toolDescriptions() -> [[String: Any]] {
        [
            tool(
                "search_fonts",
                "Search the user's font library by feeling, use, category, contrast, x-height, width, foundry, or name. Returns families with a short form description. Call this before naming any font.",
                properties: [
                    "query": ["type": "string", "description": "What the font should feel like, be used for, or be called."],
                    "limit": ["type": "integer", "description": "How many families to return. Default 20."]
                ],
                required: ["query"]
            ),
            tool(
                "font_details",
                "Every cut of one family: style, format, foundry, designer, file, activation, proportions.",
                properties: ["family": ["type": "string"]],
                required: ["family"]
            ),
            tool(
                "library_summary",
                "Counts of the library, the lists, and the source folders.",
                properties: [:],
                required: []
            ),
            tool(
                "show_fonts",
                "Select families in AllFontsO so the user sees them in the preview.",
                properties: [
                    "families": ["type": "array", "items": ["type": "string"]],
                    "style": ["type": "string", "description": "Optional style name, for example Bold. Without it every cut of the family is shown."]
                ],
                required: ["families"]
            ),
            tool(
                "activate_fonts",
                "Activate fonts so InDesign and other apps can use them. Give a family and, optionally, one style.",
                properties: [
                    "family": ["type": "string"],
                    "style": ["type": "string"]
                ],
                required: ["family"]
            ),
            tool(
                "deactivate_fonts",
                "Deactivate fonts the user activated earlier. System fonts stay active.",
                properties: [
                    "family": ["type": "string"],
                    "style": ["type": "string"]
                ],
                required: ["family"]
            ),
            tool(
                "similar_fonts",
                "Families whose letterforms are close to a reference family, by x-height, width, weight, contrast, and the outline of n and o.",
                properties: [
                    "family": ["type": "string"],
                    "style": ["type": "string"],
                    "limit": ["type": "integer"]
                ],
                required: ["family"]
            ),
            tool(
                "lists",
                "The user's lists and what is in them.",
                properties: [:],
                required: []
            ),
            tool(
                "create_list",
                "Create a list with this name. Returns the list, also when it already exists.",
                properties: ["name": ["type": "string"]],
                required: ["name"]
            ),
            tool(
                "add_to_list",
                "Add a family, or one style of it, to a list. The list is created when it does not exist.",
                properties: [
                    "list": ["type": "string"],
                    "family": ["type": "string"],
                    "style": ["type": "string"]
                ],
                required: ["list", "family"]
            ),
            tool(
                "remove_from_list",
                "Remove a family, or one style of it, from a list.",
                properties: [
                    "list": ["type": "string"],
                    "family": ["type": "string"],
                    "style": ["type": "string"]
                ],
                required: ["list", "family"]
            ),
            tool(
                "set_favorite",
                "Mark a family as a favorite, or take the mark away.",
                properties: [
                    "family": ["type": "string"],
                    "favorite": ["type": "boolean"]
                ],
                required: ["family", "favorite"]
            ),
            tool(
                "news",
                "New font names and posts from the foundries the user follows. Nothing is downloaded.",
                properties: ["limit": ["type": "integer"]],
                required: []
            )
        ]
    }

    static func call(_ name: String, arguments: [String: Any], store: LibraryStore) async throws -> String {
        switch name {
        case "search_fonts":
            let query = string(arguments["query"])
            guard !query.isEmpty else { throw FontsoError.message("Give a query.") }
            let limit = clamp(arguments["limit"], fallback: 20, max: 60)
            let cards = FontResearch.candidates(in: store.fonts, query: query, limit: limit)
            if cards.isEmpty { return "No matching fonts in the library." }
            return "family | category | form | styles | foundry | variable or static | state\n"
                + cards.map(\.line).joined(separator: "\n")
        case "font_details":
            let faces = try cuts(arguments, store: store)
            return faces.map { face in
                var parts = [
                    "\(face.family) \(face.style)",
                    face.format.uppercased(),
                    face.isVariable ? "variable" : "static",
                    face.activation.isAvailableToApps ? "active" : "inactive",
                    "weight \(face.weightClass)",
                    "width \(face.widthClass)",
                    face.category.rawValue
                ]
                if !face.manufacturer.isEmpty { parts.append("foundry \(face.manufacturer)") }
                if !face.designer.isEmpty { parts.append("designer \(face.designer)") }
                if face.xHeight > 0 { parts.append("x-height \(face.xHeight)‰") }
                if face.capHeight > 0 { parts.append("cap height \(face.capHeight)‰") }
                if face.averageWidth > 0 { parts.append("average width \(face.averageWidth)‰") }
                let project = store.license(for: face)
                if !project.isEmpty { parts.append("licensed for \(project)") }
                parts.append(face.filePath)
                return parts.joined(separator: " | ")
            }.joined(separator: "\n")
        case "library_summary":
            let families = Set(store.fonts.map { $0.family.lowercased() }).count
            let active = store.fonts.filter { $0.activation.isAvailableToApps }.count
            var lines = [
                "\(store.fonts.count) cuts in \(families) families, \(active) active.",
                "Folders: " + (store.folders.isEmpty ? "none" : store.folders.map(\.path).joined(separator: ", "))
            ]
            if store.groups.isEmpty {
                lines.append("Lists: none")
            } else {
                lines.append("Lists: " + store.groups.map { "\($0.name) (\(store.count(.group($0.id))))" }.joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        case "show_fonts":
            let families = (arguments["families"] as? [Any] ?? []).map { string($0) }.filter { !$0.isEmpty }
            guard !families.isEmpty else { throw FontsoError.message("Name at least one family.") }
            let style = string(arguments["style"])
            var ids = Set<Int64>()
            var shown: [String] = []
            for family in families {
                let faces = store.cuts(in: family).filter { style.isEmpty || $0.style.caseInsensitiveCompare(style) == .orderedSame }
                guard !faces.isEmpty else { continue }
                ids.formUnion(faces.map(\.id))
                shown.append(faces[0].family)
            }
            guard !ids.isEmpty else { throw FontsoError.message("None of these families is in the library.") }
            store.filter = .all
            store.outsideSelection = []
            store.selection = ids
            return "Showing " + shown.joined(separator: ", ") + " in the preview."
        case "activate_fonts":
            let faces = try cuts(arguments, store: store)
            let paths = Array(Set(faces.filter(\.canActivate).map(\.filePath)))
            if paths.isEmpty { return "\(faces[0].family) is already active." }
            store.activate(paths: paths)
            return "Activating \(faces[0].family): \(paths.count) \(paths.count == 1 ? "file" : "files")."
        case "deactivate_fonts":
            let faces = try cuts(arguments, store: store)
            let paths = Array(Set(faces.filter(\.canDeactivate).map(\.filePath)))
            if paths.isEmpty { return "\(faces[0].family) is a system font or already inactive, so nothing changed." }
            store.deactivate(paths: paths)
            return "Deactivating \(faces[0].family): \(paths.count) \(paths.count == 1 ? "file" : "files")."
        case "similar_fonts":
            let faces = try cuts(arguments, store: store)
            let reference = faces.first { !$0.isItalic } ?? faces[0]
            let limit = clamp(arguments["limit"], fallback: 12, max: 36)
            let library = store.fonts
            let ranked = await Task.detached(priority: .userInitiated) {
                let coarse = FormMatch.neighbors(of: reference, in: library)
                return FormMatch.refine(coarse, reference: reference)
            }.value
            if ranked.isEmpty { return "No other family is close to \(reference.family)." }
            return "Close to \(reference.family) \(reference.style):\n"
                + ranked.prefix(limit).map { "\($0.face.family) \($0.face.style) | \($0.face.category.rawValue) | \($0.score)% alike" }.joined(separator: "\n")
        case "lists":
            if store.groups.isEmpty { return "The user has no lists yet." }
            return store.groups.map { group in
                let keys = store.listOrder[group.id] ?? Array(store.membership[group.id, default: []])
                let names = keys.compactMap { key in
                    store.face(identity: key).map { "\($0.family) \($0.style)" }
                }
                let outside = (store.listLinks[group.id] ?? []).map { "\($0.name) (outside, \($0.source))" }
                let items = names + outside
                return "\(group.name): " + (items.isEmpty ? "empty" : items.joined(separator: ", "))
            }.joined(separator: "\n")
        case "create_list":
            let name = string(arguments["name"])
            guard !name.isEmpty else { throw FontsoError.message("Give the list a name.") }
            let group = try store.ensureGroup(named: name)
            return "List \(group.name) is ready."
        case "add_to_list":
            let listName = string(arguments["list"])
            guard !listName.isEmpty else { throw FontsoError.message("Name the list.") }
            let faces = try cuts(arguments, store: store)
            let group = try store.ensureGroup(named: listName)
            store.addToGroup(group.id, identities: faces.map(\.identity))
            return "Added \(faces.count) \(faces.count == 1 ? "cut" : "cuts") of \(faces[0].family) to \(group.name)."
        case "remove_from_list":
            let listName = string(arguments["list"])
            guard let group = store.groups.first(where: { $0.name.caseInsensitiveCompare(listName) == .orderedSame }) else {
                throw FontsoError.message("There is no list called \(listName).")
            }
            let faces = try cuts(arguments, store: store)
            store.removeFromGroup(group.id, identities: faces.map(\.identity))
            return "Removed \(faces[0].family) from \(group.name)."
        case "set_favorite":
            let faces = try cuts(arguments, store: store)
            let on = arguments["favorite"] as? Bool ?? true
            store.setFavorites(faces.map(\.identity), on: on)
            return on ? "\(faces[0].family) is a favorite." : "\(faces[0].family) is no longer a favorite."
        case "news":
            let limit = clamp(arguments["limit"], fallback: 20, max: 60)
            let items = store.notices.filter { !$0.seen }.prefix(limit)
            if items.isEmpty { return "No new names from followed foundries." }
            return items.map { notice in
                let date = notice.publishedAt.map { "published \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "undated"
                return "\(notice.name) | \(notice.foundryName) | \(date) | \(notice.url.absoluteString)"
            }.joined(separator: "\n")
        default:
            throw FontsoError.message("Unknown tool \(name).")
        }
    }

    private static func cuts(_ arguments: [String: Any], store: LibraryStore) throws -> [FontFace] {
        let family = string(arguments["family"])
        guard !family.isEmpty else { throw FontsoError.message("Name the family.") }
        let style = string(arguments["style"])
        var faces = store.cuts(in: family)
        if faces.isEmpty {
            let folded = family.lowercased()
            faces = store.fonts.filter { $0.family.lowercased().contains(folded) }
        }
        guard !faces.isEmpty else { throw FontsoError.message("\(family) is not in the library.") }
        if !style.isEmpty {
            let picked = faces.filter { $0.style.caseInsensitiveCompare(style) == .orderedSame }
            guard !picked.isEmpty else {
                throw FontsoError.message("\(family) has no style called \(style). Styles: " + faces.map(\.style).joined(separator: ", "))
            }
            return picked
        }
        return faces
    }

    private nonisolated static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func clamp(_ value: Any?, fallback: Int, max top: Int) -> Int {
        let raw = (value as? Int) ?? Int((value as? Double) ?? Double(fallback))
        return min(max(raw, 1), top)
    }

    private nonisolated static func envelope(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private nonisolated static func errorObject(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    nonisolated static func errorEnvelope(id: Any?, code: Int, message: String) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return HTTPRequest(method: String(parts[0]).uppercased(), path: path, headers: headers, body: Data(body))
    }

    static func response(status: Int, body: Data, type: String, session: String? = nil) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "OK"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
        if let session { head += "Mcp-Session-Id: \(session)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// Runs when the binary is started with --mcp. Reads JSON-RPC lines from stdin and forwards them to the running app.
enum MCPStdioBridge {
    static func run() -> Never {
        let output = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                write(MCPTools.errorEnvelope(id: nil, code: -32700, message: "The line was not JSON."), to: output)
                continue
            }
            let isNotification: Bool
            if let dictionary = object as? [String: Any] {
                isNotification = dictionary["id"] == nil
            } else {
                isNotification = false
            }
            guard let reply = forward(data) else {
                // AllFontsO is closed or MCP is off: the bridge answers what it can by itself.
                if !isNotification, let message = object as? [String: Any],
                   let offline = MCPTools.offlineReply(message),
                   let body = try? JSONSerialization.data(withJSONObject: offline) {
                    write(body, to: output)
                } else if !isNotification {
                    write(MCPTools.errorEnvelope(
                        id: nil,
                        code: -32000,
                        message: "AllFontsO is not running, or Your own AI is switched off under Chat › Model."
                    ), to: output)
                }
                continue
            }
            if !reply.isEmpty {
                write(reply, to: output)
            }
        }
        exit(0)
    }

    private static func write(_ data: Data, to output: FileHandle) {
        var line = data
        line.append(0x0A)
        output.write(line)
    }

    private static func forward(_ data: Data) -> Data? {
        guard let text = try? String(contentsOf: MCPSettings.portFile, encoding: .utf8),
              let port = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = URL(string: MCPSettings.endpoint(port: port)) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data
        let gate = DispatchSemaphore(value: 0)
        var reply: Data?
        var status = 0
        let task = URLSession.shared.dataTask(with: request) { body, response, _ in
            reply = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            gate.signal()
        }
        task.resume()
        gate.wait()
        guard status != 0 else { return nil }
        if status == 202 { return Data() }
        return reply
    }
}

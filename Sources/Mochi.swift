// Eden: a floating desktop pet for local app commands and optional CLI integrations.
// Return handles app commands and local to-dos. Terminal messaging requires the Advanced menu.
// Claude Code can still supply replies, questions and progress through its existing hooks.
import Cocoa
import CoreServices
import ServiceManagement

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Field: NSTextView {
    var stringValue: String {
        get { string }
        set { string = newValue; needsDisplay = true }
    }
    var placeholderAttributedString: NSAttributedString? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty { placeholderAttributedString?.draw(at: NSPoint(x: 2, y: 5)) }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // standard editing shortcuts inside the field
        if e.modifierFlags.contains(.command), let k = e.charactersIgnoringModifiers {
            let map: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                                           "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
                                           "z": Selector(("undo:"))]
            if let s = map[k], NSApp.sendAction(s, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: e)
    }
}

// a view whose corners stay fully round as it grows and shrinks
final class Pill: NSView {
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layer?.cornerRadius = min(s.height/2, 16) }
}
final class PillGlass: NSVisualEffectView {
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layer?.cornerRadius = min(s.height/2, 15) }
}

final class PetHandle: NSView {
    var onClick: (() -> Void)?
    private var downEvent: NSEvent?
    private var dragged = false
    override func mouseDown(with event: NSEvent) { downEvent = event; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        guard let downEvent, !dragged else { return }
        let a = downEvent.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) >= 5 else { return }
        dragged = true
        window?.performDrag(with: downEvent)
    }
    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
        downEvent = nil
    }
}

enum PetChatLayout {
    static func targetFrame(current: NSRect, wasOpen: Bool, willOpen: Bool,
                            size: NSSize, visible: NSRect?) -> NSRect {
        let catCenter = current.minX + (wasOpen ? 28 : current.width / 2)
        var frame = NSRect(x: catCenter - (willOpen ? 28 : size.width / 2), y: current.minY,
                           width: size.width, height: size.height)
        if let visible {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - size.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - size.height - 8)
        }
        return frame
    }
}

// MARK: - the goo

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }
func hex(_ s: String) -> NSColor {
    let v = Int(s.dropFirst(), radix: 16) ?? 0
    return rgb(CGFloat(v >> 16 & 255) / 255, CGFloat(v >> 8 & 255) / 255, CGFloat(v & 255) / 255)
}

// MARK: - shared bits

let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochi")
let cyanText = NSColor(red: 0.5, green: 0.9, blue: 1, alpha: 0.9)

enum LauncherCommand: Equatable {
    case message
    case browseCodexThreads
    case open([String])
    case invalidAppReference
}

enum GuidedMessageDestination: String, Equatable {
    case chatGPT, claude

    var name: String { self == .chatGPT ? "ChatGPT" : "Claude" }
    var bundleID: String { self == .chatGPT ? "com.openai.chat" : "com.anthropic.claudefordesktop" }
    var website: URL { URL(string: self == .chatGPT ? "https://chatgpt.com/" : "https://claude.ai/")! }
}

struct GuidedMessageIntentParser {
    func parse(_ input: String) -> GuidedMessageDestination? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        let pattern = #"^(?:(?:i )?(?:want|would like) to )?(?:send (?:a )?message to|message|send to|write to) (chatgpt|claude)(?: please)?$"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(text[range])
        return match.hasSuffix("chatgpt") || match.hasSuffix("chatgpt please") ? .chatGPT : .claude
    }
}

struct GuidedMessageFlow {
    enum State: Equatable {
        case idle
        case composing(GuidedMessageDestination)
        case editing(GuidedMessageDestination, String)
        case confirming(GuidedMessageDestination, String)
    }
    private(set) var state: State = .idle

    var isActive: Bool { state != .idle }
    var draft: String? {
        switch state {
        case .editing(_, let text), .confirming(_, let text): return text
        default: return nil
        }
    }
    mutating func start(_ destination: GuidedMessageDestination) {
        if let draft { state = .editing(destination, draft) }
        else { state = .composing(destination) }
    }
    mutating func capture(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch state {
        case .composing(let destination), .editing(let destination, _):
            state = .confirming(destination, text); return true
        case .confirming(let destination, _):
            state = .confirming(destination, text); return true
        case .idle: return false
        }
    }
    mutating func edit() {
        if case .confirming(let destination, let text) = state { state = .editing(destination, text) }
    }
    mutating func cancel() { state = .idle }
}

struct LauncherCommandParser {
    func parse(_ input: String) -> LauncherCommand {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.hasSuffix("?") else { return .message }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower == "show my codex conversations" || lower == "show codex conversations"
            || lower == "show my codex threads" || lower == "show codex threads" {
            return .browseCodexThreads
        }
        guard let match = lower.range(of: #"^(?:open|launch|start|switch to|show)\s+"#, options: .regularExpression) else {
            return .message
        }
        let verb = lower[..<match.upperBound].trimmingCharacters(in: .whitespaces)
        let body = String(text[match.upperBound...])
        let separated = body.replacingOccurrences(of: #"\s+(?:and|&)\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
        let parts = separated.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return .invalidAppReference }
        for part in parts {
            // The launcher takes names and bundle IDs only, never paths or URLs.
            if part.contains("/") || part.contains(":") || part.hasPrefix("~") || part.hasPrefix(".") {
                return .invalidAppReference
            }
        }
        let first = parts[0].split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
        if parts.count == 1 {
            if ["a", "an", "the", "my", "me", "your", "this", "that", "our", "some"].contains(first) {
                return .message
            }
            if verb == "start" && parts[0].split(whereSeparator: \.isWhitespace).count == 1
                && first.hasSuffix("ing") { return .message }
        }
        var unique: [String] = []
        for part in parts where !unique.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            unique.append(part)
        }
        return .open(unique)
    }
}

struct InstalledApplication: Hashable {
    let url: URL
    let displayName: String
    let bundleName: String
    let bundleID: String
    let fileName: String

    init?(url: URL) {
        let location = url.standardizedFileURL.resolvingSymlinksInPath()
        guard location.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: location),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let fileName = location.deletingPathExtension().lastPathComponent
        self.url = location
        self.fileName = fileName
        self.bundleID = id
        self.bundleName = (bundle.infoDictionary?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        self.displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? self.bundleName
    }

    var names: [String] { [displayName, bundleName, fileName] }
}

struct GuidedMessageAppResolver {
    static func verifiedApp(for destination: GuidedMessageDestination, at url: URL?) -> InstalledApplication? {
        guard let url, let app = InstalledApplication(url: url), app.bundleID == destination.bundleID,
              app.names.contains(where: { $0.caseInsensitiveCompare(destination.name) == .orderedSame }) else { return nil }
        return app
    }
}

enum LauncherResolution: Equatable {
    case exact([InstalledApplication])
    case alias([InstalledApplication])
    case suggestions([InstalledApplication])
    case missing
}

struct LauncherAppResolver {
    private enum AliasTarget {
        case bundleID(String)
        case namePrefix(String)
    }
    private static let aliases: [String: AliasTarget] = [
        "codex": .bundleID("com.openai.codex"),
        "chat gpt": .bundleID("com.openai.chat"),
        "vs code": .bundleID("com.microsoft.VSCode"),
        "vscode": .bundleID("com.microsoft.VSCode"),
        "code": .bundleID("com.microsoft.VSCode"),
        "chrome": .bundleID("com.google.Chrome"),
        "photoshop": .namePrefix("adobe photoshop")
    ]

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace)
        return words.joined(separator: " ")
    }

    static func aliasBundleID(for name: String) -> String? {
        if case .bundleID(let id) = aliases[normalized(name)] { return id }
        return nil
    }

    static func resolve(_ name: String, in apps: [InstalledApplication]) -> LauncherResolution {
        let key = normalized(name)
        guard !key.isEmpty else { return .missing }
        let sorted = apps.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
        let exact = sorted.filter { app in
            app.names.contains { normalized($0) == key } || normalized(app.bundleID) == key
        }
        if !exact.isEmpty { return .exact(exact) }
        if let alias = aliases[key] {
            let matches = sorted.filter { app in
                switch alias {
                case .bundleID(let id): return app.bundleID.caseInsensitiveCompare(id) == .orderedSame
                case .namePrefix(let prefix): return app.names.contains { normalized($0).hasPrefix(prefix) }
                }
            }
            if !matches.isEmpty { return .alias(matches) }
        }
        guard key.count >= 3 else { return .missing }
        let suggestions = sorted.filter { app in
            app.names.contains { candidate in
                let candidate = normalized(candidate)
                return candidate.contains(key) || (candidate.count <= 24 && key.count <= 24 &&
                    editDistance(candidate, key, limit: 2) <= 2)
            }
        }
        return suggestions.isEmpty ? .missing : .suggestions(Array(suggestions.prefix(12)))
    }

    private static func editDistance(_ left: String, _ right: String, limit: Int) -> Int {
        let a = Array(left), b = Array(right)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))
            }
            row = next
        }
        return row[b.count]
    }
}

enum LauncherAppDiscovery {
    static func sameLocation(_ left: URL, _ right: URL) -> Bool {
        left.standardizedFileURL.resolvingSymlinksInPath() ==
            right.standardizedFileURL.resolvingSymlinksInPath()
    }

    static var standardRoots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
    }

    static func catalog(roots: [URL], registeredURLs: [URL]) -> [InstalledApplication] {
        var paths = registeredURLs
        for root in roots { scan(root, depth: 0, into: &paths) }
        var found: [URL: InstalledApplication] = [:]
        for path in paths {
            if let app = InstalledApplication(url: path) { found[app.url] = app }
        }
        return Array(found.values)
    }

    private static func scan(_ folder: URL, depth: Int, into paths: inout [URL]) {
        guard depth <= 2, let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return }
        for child in children {
            if child.pathExtension.lowercased() == "app" { paths.append(child); continue }
            guard depth < 2, (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
                  (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
            scan(child, depth: depth + 1, into: &paths)
        }
    }

    private static func spotlightURLs() -> [URL] {
        guard let query = MDQueryCreate(kCFAllocatorDefault,
            "kMDItemContentTypeTree == \"com.apple.application-bundle\"" as CFString, nil, nil) else { return [] }
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            MDQueryStop(query)
            return []
        }
        defer { MDQueryStop(query) }
        var paths: [URL] = []
        for index in 0..<min(MDQueryGetResultCount(query), 10_000) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                paths.append(URL(fileURLWithPath: path))
            }
        }
        return paths
    }

    static func discover(names: [String], completion: @escaping ([InstalledApplication]) -> Void) {
        let workspace = NSWorkspace.shared
        var registered = workspace.runningApplications.compactMap(\.bundleURL)
        for name in names {
            // Launch Services can find a registered app outside the standard folders.
            if let path = workspace.fullPath(forApplication: name) {
                registered.append(URL(fileURLWithPath: path))
            }
            for id in [name, LauncherAppResolver.aliasBundleID(for: name)].compactMap({ $0 }) {
                if let url = workspace.urlForApplication(withBundleIdentifier: id) { registered.append(url) }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = catalog(roots: standardRoots, registeredURLs: registered + spotlightURLs())
            DispatchQueue.main.async { completion(apps) }
        }
    }
}

enum ProviderID: String, CaseIterable {
    case claude, codex

    var adapter: ProviderAdapter {
        switch self {
        case .claude: return ClaudeProvider()
        case .codex: return CodexProvider()
        }
    }
}

protocol ProviderAdapter {
    var name: String { get }
    var executable: String { get }
    func matchesProcess(_ command: String) -> Bool
}

private func commandStarts(_ command: String, with executable: String) -> Bool {
    guard let first = command.split(whereSeparator: \.isWhitespace).first else { return false }
    return (first as NSString).lastPathComponent == executable
}

struct ClaudeProvider: ProviderAdapter {
    let name = "Claude Code"
    let executable = "claude"
    func matchesProcess(_ command: String) -> Bool {
        guard !command.contains("bg-spare") else { return false }
        if commandStarts(command, with: executable) { return true }
        let parts = command.split(whereSeparator: \.isWhitespace)
        return parts.count > 1 && (parts[0] as NSString).lastPathComponent == "node"
            && (parts[1] as NSString).lastPathComponent == executable
    }
}

struct CodexProvider: ProviderAdapter {
    let name = "Codex CLI"
    let executable = "codex"
    func matchesProcess(_ command: String) -> Bool { commandStarts(command, with: executable) }
}

// Eden-owned Codex App Server connection. History reads and explicitly selected turns only.
private final class CodexHistoryClient {
    enum Failure: LocalizedError {
        case unavailable(String)
        case validation(String)
        case rejected(Int?, String)
        case timeout(String)
        case exited(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .validation(let message): return message
            case .rejected(_, let message): return "Codex App Server: \(String(message.prefix(200)))"
            case .timeout(let method): return "Codex App Server timed out during \(method)"
            case .exited(let status): return "Codex App Server exited (status \(status))"
            }
        }

        // Diagnostics never contain server-supplied text, which can include private data.
        var safeSummary: String {
            switch self {
            case .unavailable: return "App Server transport or response unavailable"
            case .validation(let message): return message
            case .rejected(_, let message):
                if let category = activeWorkCategory { return category }
                let lower = message.lowercased()
                if lower.contains("not found") { return "App Server reported not found" }
                if lower.contains("permission") || lower.contains("access denied") {
                    return "App Server reported a permission error"
                }
                if lower.contains("experimentalapi") { return "App Server reported an experimental API requirement" }
                return "App Server rejected the request"
            case .timeout: return "App Server request timed out"
            case .exited: return "App Server process exited"
            }
        }

        var rpcCode: Int? { if case .rejected(let code, _) = self { return code }; return nil }

        var activeWorkCategory: String? {
            guard case .rejected(let code, let message) = self, code == -32600 else { return nil }
            let lower = message.lowercased()
            if lower.contains("different rollout path") { return "Thread is running with a different rollout path" }
            if lower.contains("active writer") { return "Thread has another active writer" }
            if lower.contains("active turn") || lower.contains("turn is active") {
                return "Thread has an active turn"
            }
            if lower.contains("already running") { return "Thread is already running" }
            if lower.contains("already active") || lower.contains("active work") {
                return "Thread has active work"
            }
            if lower.contains("already") && (lower.contains("running") || lower.contains("active")) {
                return "Thread reports active work or ownership"
            }
            return nil
        }
    }

    struct Thread {
        let id: String, title: String, cwd: String, source: String, status: String
        let projectID: String?, modelProvider: String
        let local: Bool

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String, let cwd = value["cwd"] as? String,
                  let status = value["status"] as? [String: Any], let state = status["type"] as? String else { return nil }
            self.id = id; self.cwd = cwd; self.status = state
            projectID = value["projectId"] as? String
            modelProvider = value["modelProvider"] as? String ?? ""
            let name = (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (value["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            title = String((name?.isEmpty == false ? name : preview) ?? "Untitled").prefix(100).description
            if let s = value["source"] as? String { source = s }
            else if let s = value["source"] as? [String: Any], let custom = s["custom"] as? String { source = custom }
            else { source = "unknown" }
            local = UUID(uuidString: id) != nil && cwd.hasPrefix("/") &&
                ["cli", "vscode", "appServer"].contains(source) && (value["ephemeral"] as? Bool) != true
        }
    }

    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var stopped = false
    var onNotification: ((String, [String: Any]) -> Void)?
    var onServerRequest: ((Any, String, [String: Any]) -> Void)?
    var onDisconnect: ((Failure) -> Void)?

    init(executable: String) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func connect(_ done: @escaping (Result<Void, Error>) -> Void) {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.failAll(.exited(process.terminationStatus)) }
        }
        do { try process.run() } catch {
            stop(); done(.failure(Failure.unavailable("Could not start Codex App Server: \(error.localizedDescription)"))); return
        }
        request("initialize", ["clientInfo": ["name": "katescape_history", "title": "Eden History", "version": "0.1"]]) { [weak self] result in
            switch result {
            case .failure(let error): done(.failure(error))
            case .success:
                self?.notify("initialized", [:])
                done(.success(()))
            }
        }
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 8,
                 _ done: @escaping (Result<[String: Any], Error>) -> Void) {
        guard !stopped, process.isRunning else {
            done(.failure(Failure.unavailable("Codex App Server is unavailable"))); return
        }
        let id = nextID; nextID += 1
        pending[id] = done
        send(["method": method, "id": id, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
            callback(.failure(Failure.timeout(method)))
            self.failAll(.timeout(method))
        }
    }

    func respond(to id: Any, result: [String: Any]) {
        send(["id": id, "result": result])
    }

    func reject(to id: Any, message: String) {
        send(["id": id, "error": ["code": -32601, "message": message]])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else {
            failAll(.unavailable("Could not encode Codex protocol request")); return
        }
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { failAll(.unavailable("Could not write to Codex App Server")) }
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty { failAll(.unavailable("Codex App Server closed its output")); return }
        buffer.append(data)
        guard buffer.count <= 4_000_000 else { failAll(.unavailable("Codex App Server response exceeded the size limit")); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failAll(.unavailable("Codex App Server returned malformed JSON")); return
            }
            if let method = value["method"] as? String {
                let params = value["params"] as? [String: Any] ?? [:]
                if let id = value["id"] { onServerRequest?(id, method, params) }
                else { onNotification?(method, params) }
                continue
            }
            if value["id"] == nil { continue }
            guard let id = value["id"] as? Int else {
                failAll(.unavailable("Codex App Server returned an invalid response ID")); return
            }
            guard let callback = pending.removeValue(forKey: id) else { continue }
            if let error = value["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown protocol error"
                callback(.failure(Failure.rejected(error["code"] as? Int, message)))
            } else if let result = value["result"] as? [String: Any] {
                callback(.success(result))
            } else {
                callback(.failure(Failure.unavailable("Codex App Server returned an invalid response")))
            }
        }
    }

    private func failAll(_ failure: Failure) {
        guard !stopped else { return }
        let callbacks = pending.values; pending.removeAll()
        stop()
        for callback in callbacks { callback(.failure(failure)) }
        onDisconnect?(failure)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    deinit { stop() }
}

// App Server exposes account type, email and plan here, but no workspace ID.
// API-key accounts have no stable identity in account/read, so direct sending is unavailable for them.
private struct CodexAccountContext: Equatable {
    let email: String
    let plan: String

    init?(_ response: [String: Any]) {
        guard let account = response["account"] as? [String: Any],
              account["type"] as? String == "chatgpt",
              let email = account["email"] as? String, !email.isEmpty,
              let plan = account["planType"] as? String else { return nil }
        self.email = email; self.plan = plan
    }
}

// In-memory, opt-in send diagnostics. Never retain thread IDs, paths, account data or text.
private struct CodexSendDiagnostic {
    let started = Date()
    var stage = "preflight"
    var method = "none"
    var code: Int?
    var summary = "Checking destination"
    var turnStartAttempted = false
    var delivery = "not sent"
    var transport = "connected"
    var listStatusAtSelection = "not recorded"
    var readStatusBeforeResume = "not checked"
    var readStatusAfterRejection = "not checked"
    var loadedInKatescapeServer = "not checked"

    var report: String {
        """
        Operation: Codex Desktop send
        Time: \(ISO8601DateFormatter().string(from: started))
        Stage: \(stage)
        RPC method: \(method)
        RPC code: \(code.map(String.init) ?? "none")
        Result: \(summary)
        turn/start attempted: \(turnStartAttempted ? "yes" : "no")
        Delivery: \(delivery)
        App Server: \(transport)
        thread/list status at selection: \(listStatusAtSelection)
        thread/read before resume: \(readStatusBeforeResume)
        thread/read after rejection: \(readStatusAfterRejection)
        Loaded in Eden App Server after rejection: \(loadedInKatescapeServer)
        """
    }
}

private final class CodexThreadPickerView: NSView {
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 60, width: 600, height: 28))
    private let details = NSTextField(wrappingLabelWithString: "")
    let threads: [CodexHistoryClient.Thread]

    init(threads: [CodexHistoryClient.Thread]) {
        self.threads = threads
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 90))
        popup.addItems(withTitles: threads.map { $0.title })
        popup.target = self; popup.action = #selector(updateDetails)
        addSubview(popup)
        details.frame = NSRect(x: 0, y: 0, width: 600, height: 56)
        details.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        addSubview(details)
        updateDetails()
    }

    required init?(coder: NSCoder) { nil }

    var selected: CodexHistoryClient.Thread? {
        let index = popup.indexOfSelectedItem
        return threads.indices.contains(index) ? threads[index] : nil
    }

    @objc private func updateDetails() {
        guard let thread = selected else { return }
        details.stringValue = "ID: \(thread.id)\nDirectory: \(thread.cwd)\nSource: \(thread.source) · Status: \(thread.status)"
    }
}

// a button that works on the first click, even when Mochi isn't the active app
final class Tap: NSButton { override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } }

// smoked glass in a floating panel, like the pill. Returns the panel and a content view that can be cleared and rebuilt
func glassPanel(_ size: NSSize, radius: CGFloat = 15) -> (Panel, NSView) {
    let p = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = true
    let ring = NSView(); ring.wantsLayer = true; ring.layer?.cornerRadius = radius
    ring.layer?.borderWidth = 1; ring.layer?.borderColor = NSColor(white: 0, alpha: 0.45).cgColor
    p.contentView = ring
    let glass = NSVisualEffectView(frame: ring.bounds.insetBy(dx: 1, dy: 1)); glass.autoresizingMask = [.width, .height]
    glass.appearance = NSAppearance(named: .darkAqua); glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
    glass.wantsLayer = true; glass.layer?.cornerRadius = radius - 1; glass.layer?.masksToBounds = true
    glass.layer?.borderWidth = 1; glass.layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
    ring.addSubview(glass)
    let tint = NSView(frame: glass.bounds); tint.autoresizingMask = [.width, .height]
    tint.wantsLayer = true; tint.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.62).cgColor
    glass.addSubview(tint)
    let content = NSView(frame: glass.bounds); content.autoresizingMask = [.width, .height]
    glass.addSubview(content)
    return (p, content)
}

func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = NSColor(white: 1, alpha: 0.92), mono: Bool = false, wrap: CGFloat? = nil) -> NSTextField {
    let l = wrap == nil ? NSTextField(labelWithString: s) : NSTextField(wrappingLabelWithString: s)
    l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    if let w = wrap {
        l.preferredMaxLayoutWidth = w
        l.frame.size = NSSize(width: w, height: ceil(l.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10000)).height))
    } else { l.sizeToFit() }
    return l
}

// MARK: - the to-do list, kept on this Mac (Claude can add to it too, with ~/Claude/prompt-bar/todo.py)

struct Todo: Codable { var id: String; var text: String; var added: Double; var done: Double? }
let todoFile = supportDir.appendingPathComponent("todos.json")
func loadTodos() -> [Todo] {
    guard let d = try? Data(contentsOf: todoFile), let t = try? JSONDecoder().decode([Todo].self, from: d) else { return [] }
    let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    return t.filter { $0.done == nil || $0.done! >= today }   // checked-off things fade away the next day
}
func saveTodos(_ t: [Todo]) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(t) { try? d.write(to: todoFile, options: .atomic) }
}
func ago(_ t: Double) -> String {
    let s = Date().timeIntervalSince1970 - t
    return s < 60 ? "now" : s < 3600 ? "\(Int(s / 60))m" : s < 86400 ? "\(Int(s / 3600))h" : "\(Int(s / 86400))d"
}

struct GooColors { let body, edge, shine: NSColor }
// Mochi's colour comes from ~/Library/Application Support/Mochi/config.json ({"color": "#33c7ff"}); the installer asks for it,
// and "Change Mochi's Color…" in her menu changes it any time. The edge and shine are worked out from the body colour.
func gooColors(_ body: NSColor) -> GooColors {
    let b = body.usingColorSpace(.sRGB) ?? body
    return GooColors(body: b, edge: b.blended(withFraction: 0.38, of: .black) ?? b, shine: b.blended(withFraction: 0.72, of: .white) ?? b)
}
func enabledSocial() -> [String] {
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochi/config.json")
    guard let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
    return j["social"] as? [String] ?? []
}
func savedColor() -> NSColor {
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochi/config.json")
    if let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["color"] as? String { return hex(s) }
    return rgb(0.20, 0.78, 1.00)
}
func saveColor(_ c: NSColor) {
    let s = c.usingColorSpace(.sRGB) ?? c
    let h = String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochi")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.json")
    var j = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    j["color"] = h; try? JSONSerialization.data(withJSONObject: j).write(to: file)
}
var mochiGoo = gooColors(savedColor())

// Bundle sprites are optional so PB_PET_ART=mochi remains a development-only visual fallback.
private enum CatSprites {
    static func load(_ name: String, in state: String, count: Int, size: NSSize) -> [NSImage] {
        (1...count).compactMap { number in
            guard let url = Bundle.main.url(forResource: String(format: "%@_%02d", name, number),
                                            withExtension: "png", subdirectory: "PetSprites/Eden/\(state)"),
                  let image = NSImage(contentsOf: url), image.size == size else { return nil }
            return image
        }
    }
    static let idle = load("idle", in: "idle", count: 4, size: NSSize(width: 288, height: 288))
    static let blink = load("blink", in: "blink", count: 4, size: NSSize(width: 288, height: 288))
    static let sleeping = load("sleep", in: "sleeping", count: 3, size: NSSize(width: 288, height: 256))
    static let thinking = load("thinking", in: "thinking", count: 4, size: NSSize(width: 288, height: 288))
    static let happy = load("happy", in: "happy", count: 4, size: NSSize(width: 320, height: 320))
    static var available: Bool {
        idle.count == 4 && blink.count == 4 && sleeping.count == 3 && thinking.count == 4 && happy.count == 4
    }
}

// a little goo blob drawn in chunky pixels. It breathes, blinks and follows the cursor; hops, throws, thinks,
// sleeps, gets petted; and dresses for the time of day (coffee in the morning, sunglasses on Friday afternoon, a nightcap late)
final class Goo: NSView {
    let cols = 16, rows = 14, px: CGFloat = 2
    var t = 0.0
    var colors = mochiGoo { didSet { layer?.shadowColor = colors.body.cgColor } }
    var thinking = false
    var asking = false                   // Claude asked a question: a little "?" over its head
    var fed = 0                          // messages sent today: a little rounder with each
    var hopT = -10.0, hops = 1
    var sparkT = -10.0, worryT = -10.0, throwT = -10.0, heartT = -10.0
    var lean = 0.0, leanV = 0.0          // springy sway, for wiggles and flings
    var nextBlink = 2.5, blinkT = -10.0
    var catTime = 0.0, catNextBlink = 6.0, catBlinkStart = -10.0
    var look = 0.0, lookTo = 0.0, lookY = 0, nextLook = 4.0, greetUntil = -10.0
    var lastActive = 0.0, sleepSince: Double? = nil
    var hoverSince: Double? = nil
    var timer: Timer?

    // for testing the outfits: PB_HOUR=8 or PB_WEEKDAY=6 (Friday) in the environment
    let env = ProcessInfo.processInfo.environment
    var useCat: Bool { env["PB_PET_ART"] != "mochi" && CatSprites.available }
    var catDrawSize: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = colors.body.cgColor; layer?.shadowOpacity = 0.55; layer?.shadowRadius = 4; layer?.shadowOffset = .zero
        // 12 frames a second, for a pixel-art feel
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/12, repeats: true) { [weak self] _ in self?.step() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to the pill underneath

    // things that happen to it
    func hop(_ n: Int = 1) { hopT = t; hops = n; wake() }
    func proud() { hop(2); sparkT = t }
    func worry() { worryT = t; leanV += 1.2; wake() }
    func throwIt() { throwT = t; wake() }
    func fling(_ vx: Double) { leanV += max(-2.2, min(2.2, -vx / 500)); wake() }
    func greet() { hop(); lookTo = 1; greetUntil = t + 2.5 }
    func wake() { lastActive = t; if sleepSince != nil { sleepSince = nil; hopT = t; hops = 1 } }

    var hour: Int { Int(env["PB_HOUR"] ?? "") ?? Calendar.current.component(.hour, from: Date()) }
    var weekday: Int { Int(env["PB_WEEKDAY"] ?? "") ?? Calendar.current.component(.weekday, from: Date()) }   // 6 = Friday
    var night: Bool { hour >= 22 || hour < 5 }
    var sleeping: Bool { sleepSince != nil }

    func step() {
        t += 1.0/12
        if t > nextBlink { blinkT = t; nextBlink = t + 2.5 + Double.random(in: 0...3) }
        if useCat && !sleeping && !isHidden && window?.isVisible == true {
            catTime += 1.0/12
            if catTime >= catNextBlink {
                catBlinkStart = catTime
                catNextBlink = catTime + 7 + Double.random(in: 0...5)
            }
        }

        // eyes follow the cursor when it's near, otherwise glance around now and then
        let m = NSEvent.mouseLocation
        var near = false, over = false
        if let w = window {
            let c = w.convertPoint(toScreen: convert(NSPoint(x: bounds.midX - 4, y: bounds.midY), to: nil))
            let dx = m.x - c.x, dy = m.y - c.y
            near = dx * dx + dy * dy < 260 * 260
            if near && t > greetUntil { lookTo = max(-1, min(1, dx / 70)); lookY = dy > 40 ? 1 : dy < -40 ? -1 : 0 }
            let enlargedCat = useCat && catDrawSize > 28
            over = abs(dx) < (enlargedCat ? 54 : 15) && abs(dy) < (enlargedCat ? 58 : 14)
        }
        if !near && t > greetUntil {
            lookY = 0
            if t > nextLook { lookTo = [-1, 0, 0, 1].randomElement()!; nextLook = t + 2 + Double.random(in: 0...3) }
        }
        look += (lookTo - look) * 0.35

        // hovering: a happy wiggle, then petting, then a heart
        if over {
            if hoverSince == nil { hoverSince = t; leanV += 0.8 }
            wake()
            if t - hoverSince! > 2.2 && t - heartT > 2.6 { heartT = t }
        } else { hoverSince = nil }

        // springy sway
        leanV += -lean * 0.3; leanV *= 0.78; lean = max(-2.5, min(2.5, lean + leanV))

        // melts into a sleepy puddle after a quiet spell (sooner late at night)
        if thinking { lastActive = t }
        if sleepSince == nil && t - lastActive > (night ? 60 : 300) { sleepSince = t }
        switch env["PB_MOOD"] {
        case "sleepy": if sleepSince == nil { sleepSince = t - 2 }
        case "pet": if t - heartT > 2.6 { heartT = t }
        case "proud": if t - sparkT > 1.6 { proud() }
        case "worried": if t - worryT > 1.5 { worry() }
        default: break
        }
        needsDisplay = true
    }

    var petting: Bool { if env["PB_MOOD"] == "pet" { return true }; if let h = hoverSince { return t - h > 0.6 } else { return false } }

    private func drawCat() {
        let neutralState = sleeping || thinking || asking || petting || t - worryT < 1.4
        let blinkFrame = Int((catTime - catBlinkStart) * 12)
        let image: NSImage
        if !neutralState && (0..<4).contains(blinkFrame) { image = CatSprites.blink[blinkFrame] }
        else if neutralState { image = CatSprites.idle[0] }
        else { image = CatSprites.idle[Int(catTime / 0.45) % 4] }

        // Every frame uses the full 288-square canvas, so the paws keep one baseline.
        let hopAge = t - hopT, throwAge = t - throwT
        let hopLift = hopAge >= 0 && hopAge < 0.7 * Double(hops)
            ? 1.5 * sin((hopAge.truncatingRemainder(dividingBy: 0.7) / 0.7) * .pi) : 0
        let throwLift = throwAge >= 0 && throwAge < 0.72 ? 1.5 * sin(throwAge / 0.72 * .pi) : 0
        let offsetX = max(-1, min(1, lean * 0.35)).rounded()
        let context = NSGraphicsContext.current
        let previousInterpolation = context?.imageInterpolation
        context?.imageInterpolation = .none
        image.draw(in: NSRect(x: 2 + offsetX, y: max(hopLift, throwLift).rounded(.down),
                              width: catDrawSize, height: catDrawSize),
                   from: NSRect(origin: .zero, size: image.size), operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        if let previousInterpolation { context?.imageInterpolation = previousInterpolation }

        func cell(_ x: Int, _ y: Int, _ color: NSColor) {
            color.setFill(); NSRect(x: CGFloat(x * 2), y: CGFloat(y * 2), width: 2, height: 2).fill()
        }
        let white = NSColor.white
        if sleeping {
            for (x, y) in [(13, 11), (14, 11), (14, 12), (13, 13), (14, 13)] { cell(x, y, white) }
        } else if asking {
            for (x, y) in [(12, 12), (13, 13), (14, 12), (14, 11), (13, 10), (13, 8)] { cell(x, y, white) }
        } else if thinking {
            for x in 11...13 where x - 11 <= Int(catTime * 2.5) % 3 { cell(x, 12, white) }
        }
        if petting || t - heartT < 1.6 {
            let pink = rgb(1, 0.42, 0.62)
            for (x, y) in [(12, 11), (14, 11), (12, 10), (13, 10), (14, 10), (13, 9)] { cell(x, y, pink) }
        }
        if t - sparkT < 1.4 {
            for (x, y) in [(1, 11), (2, 12), (3, 11), (2, 10)] { cell(x, y, white) }
        }
        if t - worryT < 1.4 { cell(14, 10, rgb(1, 0.75, 0.4)); cell(14, 8, rgb(1, 0.75, 0.4)) }
    }

    override func draw(_ r: NSRect) {
        if useCat { drawCat(); return }
        let ox = 0.0 as CGFloat
        func cell(_ x: Int, _ y: Int, _ c: NSColor) {
            guard x >= 0, x < cols, y >= 0, y < rows else { return }
            c.setFill(); NSRect(x: ox + CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px).fill()
        }
        let ink = rgb(0.03, 0.12, 0.24), white = NSColor.white

        // ---- shape: breathing, hops, the throw, sleep and snacks ----
        let breathe = sin(t * (sleeping ? 1.4 : 2.6))
        var lift = 0.0, squash = 0.0, splat = 0.0
        let hp = t - hopT, hopLen = 0.7
        if hp < hopLen * Double(hops) {
            let k = hp.truncatingRemainder(dividingBy: hopLen) / hopLen
            if k < 0.15 { squash = 0.22 * (k / 0.15) }
            else if k < 0.85 { let a = (k - 0.15) / 0.7; lift = 3 * sin(a * .pi); squash = -0.18 * sin(a * .pi) }
            else { squash = 0.18 * (1 - (k - 0.85) / 0.15) }
        }
        let tp = t - throwT
        if tp < 0.95 {
            // crouch, spring up tall (the plane leaves here), drop, splat
            if tp < 0.18 { squash = 0.32 * tp / 0.18 }
            else if tp < 0.5 { let a = (tp - 0.18) / 0.32; lift = 4 * sin(a * .pi / 2); squash = -0.28 }
            else if tp < 0.72 { let a = (tp - 0.5) / 0.22; lift = 4 * (1 - a * a); squash = -0.1 }
            else { let a = (tp - 0.72) / 0.23; squash = 0.34 * (1 - a); splat = 2 * (1 - a) }
        }
        var melt = 0.0
        if let s = sleepSince { melt = min(1, (t - s) / 1.5) }
        let worried = t - worryT < 1.4
        let shiver = worried ? sin(t * 40) * 0.5 : 0

        let round = 1 + Double(min(fed, 15)) * 0.012
        let hgt = 7.4 * (1 + 0.05 * breathe - squash) * (1 - 0.42 * melt)
        let wid = 4.8 * (1 - 0.04 * breathe + squash * 0.8) * (1 + 0.22 * melt) * round
        let sway = lean + shiver
        let cx = 7.0
        let base = Int(lift.rounded())

        var on = Array(repeating: Array(repeating: false, count: cols), count: rows)
        for y in 0..<rows {
            let yy = Double(y - base)
            guard yy >= 0 else { continue }
            let tilt = sway * yy / max(hgt, 1)
            for x in 0..<cols {
                let dx = (Double(x) - cx - tilt) / wid, dy = yy / hgt
                if dx * dx + dy * dy <= 1 { on[y][x] = true }
            }
        }
        if base == 0 {
            // the puddle: the bottom row spreads wider and ripples; wider still on a splat
            for x in 0..<cols where abs(Double(x) - cx) <= wid + 1 + splat + 0.6 * sin(t * 3 + Double(x)) { on[0][x] = true }
        }
        let top = (0..<rows).last { on[$0].contains(true) } ?? 0

        for y in 0..<rows { for x in 0..<cols where on[y][x] {
            let rim = x == 0 || x == cols - 1 || y == rows - 1 || !on[y][x-1] || !on[y][x+1] || (y + 1 < rows && !on[y+1][x])
            cell(x, y, rim ? colors.edge : colors.body)
        }}
        let sx = Int((cx - wid * 0.45).rounded())
        if top - 1 >= 0, sx >= 0, on[top - 1][sx] { cell(sx, top - 1, colors.shine) }
        if top - 2 >= 0, sx >= 0, on[top - 2][sx] { cell(sx, top - 2, colors.shine.withAlphaComponent(0.6)) }

        // ---- face ----
        let mid = Int((cx + sway * 0.4).rounded())
        let ex = mid + Int((look * 1.0).rounded())
        var ey = base + Int((hgt * 0.42).rounded())
        if thinking { ey += 1 } else { ey += lookY }
        ey = max(base + 1, min(top - 1, ey))
        let happy = hp < hopLen * Double(hops) || tp < 0.95 || petting
        let blinking = t - blinkT < 0.15
        let shades = weekday == 6 && hour >= 12 && hour < 18 && !sleeping

        func onBody(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < cols && y >= 0 && y < rows && on[y][x] }
        func dot(_ x: Int, _ y: Int, _ c: NSColor) { if onBody(x, y) { cell(x, y, c) } }

        if shades {
            // two lenses and a bridge, a glint on each
            let gy = ey - (thinking ? 1 : 0)
            for x in [ex - 3, ex - 2, ex - 1, ex + 1, ex + 2, ex + 3] { dot(x, gy, ink); dot(x, gy + 1, ink) }
            dot(ex, gy + 1, ink)
            dot(ex - 3, gy + 1, white.withAlphaComponent(0.85)); dot(ex + 1, gy + 1, white.withAlphaComponent(0.85))
        } else {
            for e in [ex - 2, ex + 2] {
                let out = e < ex ? -1 : 1
                if sleeping || blinking { dot(e, ey, ink); dot(e + out, ey, ink) }               // closed
                else if petting { dot(e - 1, ey, ink); dot(e, ey + 1, ink); dot(e + 1, ey, ink) }   // ^ ^
                else if worried { dot(e, ey, ink); dot(e, ey + 1, ink); dot(e + out, ey, ink); dot(e + out, ey + 1, ink); dot(e, ey + 1, white) }
                else { dot(e, ey, ink); dot(e, ey + 1, ink) }
            }
        }
        if petting { dot(ex - 4, ey - 1, rgb(1, 0.5, 0.65)); dot(ex + 4, ey - 1, rgb(1, 0.5, 0.65)) }   // blush
        if worried { dot(ex, ey - 2, ink) }
        else if happy && !sleeping { dot(ex - 1, ey - 1, ink); dot(ex, ey - 2, ink); dot(ex + 1, ey - 1, ink) }

        // ---- outfits ----
        if hour >= 6 && hour < 11 {
            // morning coffee, steaming
            let mug = rgb(0.96, 0.95, 0.92), coffee = rgb(0.45, 0.28, 0.18)
            cell(13, 0, mug); cell(14, 0, mug); cell(13, 1, mug); cell(14, 1, mug); cell(15, 1, mug)
            cell(13, 2, coffee); cell(14, 2, coffee)
            let s = Int(t * 3) % 2
            cell(13 + s, 3 + Int(t * 2) % 2, white.withAlphaComponent(0.45))
            cell(14 - s, 5 - Int(t * 2) % 2, white.withAlphaComponent(0.3))
        }
        if night {
            // a striped nightcap with a pom, flopped to one side
            let cap = rgb(0.32, 0.40, 0.92), stripe = rgb(0.85, 0.88, 1)
            let y0 = top
            for x in (mid - 3)...(mid + 2) { cell(x, y0, x % 2 == 0 ? cap : stripe) }
            for x in (mid - 2)...(mid + 1) { cell(x, y0 + 1, cap) }
            cell(mid, y0 + 2, cap); cell(mid + 1, y0 + 2, cap); cell(mid + 2, y0 + 2, cap)
            cell(mid + 3, y0 + 1, white)
        }

        // ---- little extras above its head ----
        if thinking && !sleeping {
            let n = Int(t * 2.5) % 4
            for i in 0..<3 where i < n { cell(mid + 3 + i * 2, min(rows - 1, top + 1 + i), colors.shine) }
        }
        if asking && !sleeping && Int(t * 2) % 3 != 0 {
            for (dx, dy) in [(0, 4), (1, 4), (2, 4), (2, 3), (1, 2), (1, 0)] { cell(mid + 3 + dx, min(rows - 1, top + 1 + dy), white) }
        }
        if sleeping && melt >= 1 {
            // a "z" drifting up
            let f = Int((t * 1.2).truncatingRemainder(dividingBy: 4)), zx = mid + 3, zy = top + 1 + f
            let c = white.withAlphaComponent(0.75)
            for (dx, dy) in [(0, 2), (1, 2), (2, 2), (1, 1), (0, 0), (1, 0), (2, 0)] { cell(zx + dx, zy + dy, c) }
        }
        if t - heartT < 1.6 {
            let hy = top + 1 + Int((t - heartT) * 2), hx = mid + 2, pink = rgb(1, 0.42, 0.62)
            for (dx, dy) in [(0, 3), (1, 3), (3, 3), (4, 3), (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (1, 1), (2, 1), (3, 1), (2, 0)] { cell(hx + dx, hy + dy, pink) }
        }
        if t - sparkT < 1.4 {
            let on2 = Int(t * 6) % 2 == 0
            for (x, y) in (on2 ? [(1, top), (13, top - 2), (14, 2)] : [(1, top - 3), (12, top + 1), (15, 5)]) {
                cell(x, y, white); cell(x - 1, y, colors.shine); cell(x + 1, y, colors.shine); cell(x, y - 1, colors.shine); cell(x, y + 1, colors.shine)
            }
        }
    }
}

// the paper plane the goo throws when a message is sent: flies across the bar with a sparkly trail and bursts at the end
final class Fx: NSView {
    let px: CGFloat = 2
    var start = NSPoint.zero, end = NSPoint.zero, t0 = 0.0
    var trail: [NSPoint] = []
    var color = mochiGoo.body
    var timer: Timer?
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    func launch(from a: NSPoint, to b: NSPoint, color c: NSColor) {
        start = a; end = b; color = c; trail = []; t0 = CACurrentMediaTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] tm in
            guard let self else { return }
            if CACurrentMediaTime() - self.t0 > 1.15 { tm.invalidate(); self.trail = [] }
            self.needsDisplay = true
        }
    }

    override func draw(_ r: NSRect) {
        let e = CACurrentMediaTime() - t0
        guard e < 1.15 else { return }
        func cell(_ p: NSPoint, _ c: NSColor) {
            c.setFill(); NSRect(x: (p.x / px).rounded() * px, y: (p.y / px).rounded() * px, width: px, height: px).fill()
        }
        let fly = 0.7, k = min(1, e / fly)
        let ease = k * k * (3 - 2 * k)
        // up out of the goo, then a long swoop right
        let p = NSPoint(x: start.x + (end.x - start.x) * ease, y: start.y + (end.y - start.y) * ease + 6 * sin(k * .pi))
        if k < 1 {
            trail.append(p); if trail.count > 26 { trail.removeFirst() }
            // the plane, nose to the right
            for (dx, dy, c) in [(0, 2, NSColor.white), (0, 1, .white), (1, 1, .white), (2, 1, .white), (3, 1, .white), (4, 1, .white),
                                (0, 0, mochiGoo.shine), (1, 0, mochiGoo.shine), (2, 0, mochiGoo.shine)] as [(CGFloat, CGFloat, NSColor)] {
                cell(NSPoint(x: p.x + dx * px, y: p.y + dy * px), c)
            }
        }
        // trail: twinkly pixels that fade out
        for (i, q) in trail.enumerated() where i % 2 == Int(e * 30) % 2 {
            let a = CGFloat(i) / CGFloat(max(trail.count, 1))
            cell(NSPoint(x: q.x - 2, y: q.y + px), color.withAlphaComponent(0.25 + 0.6 * a * (k < 1 ? 1 : max(0, 1 - (e - fly) / 0.45))))
        }
        // burst at the end
        if e > fly {
            let b = (e - fly) / 0.45, d = 3 + b * 9, a = max(0, 1 - b)
            for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7), (-0.7, -0.7)] {
                cell(NSPoint(x: end.x + 4 + dx * d, y: end.y + 2 + dy * d), (Int(dx * 10) % 2 == 0 ? NSColor.white : color).withAlphaComponent(a))
            }
        }
    }
}

// tiny goos for a list of people (unused by default: a hook for your own customisations)
final class Visitors: NSView {
    var tints: [NSColor] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var t = 0.0
    var timer: Timer?
    let px: CGFloat = 2, shown = 4
    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/12, repeats: true) { [weak self] _ in self?.t += 1.0/12; if self?.tints.isEmpty == false { self?.needsDisplay = true } }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    var extra: Int { max(0, tints.count - shown) }
    var width: CGFloat {
        guard !tints.isEmpty else { return 0 }
        let n = CGFloat(min(tints.count, shown))
        return n * 10 + (n - 1) * 3 + (extra > 0 ? 20 : 0)
    }

    override func draw(_ r: NSRect) {
        for (i, c) in tints.prefix(shown).enumerated() {
            let x0 = CGFloat(i) * 13, bob: CGFloat = sin(t * 3 + Double(i) * 1.3) > 0.6 ? px : 0
            let edge = c.blended(withFraction: 0.35, of: .black) ?? c
            // a 5×4 goo: rounded top, flat bottom, two eye pixels
            let shape = [".XXX.", "XXXXX", "XXXXX", "XXXXX"]
            for (row, line) in shape.enumerated() {
                for (col, ch) in line.enumerated() where ch == "X" {
                    let y = CGFloat(3 - row) * px + bob, x = x0 + CGFloat(col) * px
                    let rim = row == 0 || col == 0 || col == 4 || (row == 1 && (col == 0 || col == 4))
                    (rim ? edge : c).setFill(); NSRect(x: x, y: y, width: px, height: px).fill()
                }
            }
            rgb(0.1, 0.15, 0.25).setFill()
            NSRect(x: x0 + px, y: 2 * px + bob, width: px, height: px).fill()
            NSRect(x: x0 + 3 * px, y: 2 * px + bob, width: px, height: px).fill()
        }
        if extra > 0 {
            ("+\(extra)" as NSString).draw(at: NSPoint(x: CGFloat(shown) * 13 + 1, y: -1),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.7)])
        }
    }
}

// unread counts from social sites open in Chrome (read from their tab titles, like "(3) Instagram"), as tiny pixel badges
struct SocialSite {
    let key: String, name: String, hosts: [String]
    let icon: [String]                 // 7×7 pixel art: letters pick colours from `palette`
    let palette: [Character: NSColor]
}

let socialSites: [SocialSite] = [
    SocialSite(key: "ig", name: "Instagram", hosts: ["instagram.com"],
               icon: [".abbbc.", "a.....c", "a.ddd.c", "a.d.d.c", "a.ddd.c", "a....ec", ".aeeec."],
               palette: ["a": hex("#ff3e8a"), "b": hex("#ff5e5b"), "c": hex("#ff9b3d"), "d": .white, "e": hex("#c13ad6")]),
    SocialSite(key: "th", name: "Threads", hosts: ["threads.net", "threads.com"],
               icon: [".wwwww.", "w.....w", "w.www.w", "w.w.w.w", "w.wwwww", "w......", ".wwwww."],
               palette: ["w": .white]),
    SocialSite(key: "li", name: "LinkedIn", hosts: ["linkedin.com"],
               icon: ["bbbbbbb", "bwbbbbb", "bbbbbbb", "bwbwwwb", "bwbwbwb", "bwbwbwb", "bbbbbbb"],
               palette: ["b": hex("#0a66c2"), "w": .white]),
    SocialSite(key: "x", name: "X", hosts: ["x.com", "twitter.com"],
               icon: ["w.....w", ".w...w.", "..w.w..", "...w...", "..w.w..", ".w...w.", "w.....w"],
               palette: ["w": .white]),
]

final class Social: NSView {
    var counts: [(site: SocialSite, n: Int)] = [] { didSet { needsDisplay = true } }
    let px: CGFloat = 2
    let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) }

    func label(_ n: Int) -> String { n > 99 ? "99+" : "\(n)" }
    func slot(_ n: Int) -> CGFloat { 14 + 3 + (label(n) as NSString).size(withAttributes: [.font: font]).width + 7 }
    var width: CGFloat { counts.isEmpty ? 0 : counts.reduce(0) { $0 + slot($1.n) } - 7 }

    // which site sits under a point (in this view's coordinates)
    func site(at p: NSPoint) -> SocialSite? {
        var x: CGFloat = 0
        for c in counts { let w = slot(c.n); if p.x >= x && p.x < x + w { return c.site }; x += w }
        return nil
    }

    override func draw(_ r: NSRect) {
        var x: CGFloat = 0
        for c in counts {
            for (row, line) in c.site.icon.enumerated() {
                for (col, ch) in line.enumerated() {
                    guard let col_ = c.site.palette[ch] else { continue }
                    col_.setFill(); NSRect(x: x + CGFloat(col) * px, y: CGFloat(6 - row) * px, width: px, height: px).fill()
                }
            }
            (label(c.n) as NSString).draw(at: NSPoint(x: x + 17, y: 0), withAttributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.85)])
            x += slot(c.n)
        }
    }
}

// a pixel checklist and how many things are still open
final class TodoBadge: NSView {
    var n = 0 { didSet { needsDisplay = true } }
    let px: CGFloat = 2, font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) }
    var width: CGFloat { n == 0 ? 0 : 17 + ("\(n)" as NSString).size(withAttributes: [.font: font]).width }
    override func draw(_ r: NSRect) {
        guard n > 0 else { return }
        let icon = ["wwwwwww", "w.....w", "w...llw", "wg....w", "wwg.llw", "w.g...w", "wwwwwww"]
        let pal: [Character: NSColor] = ["w": NSColor(white: 1, alpha: 0.8), "g": hex("#7ad3a3"), "l": NSColor(white: 1, alpha: 0.5)]
        for (row, line) in icon.enumerated() {
            for (col, ch) in line.enumerated() { guard let c = pal[ch] else { continue }; c.setFill(); NSRect(x: CGFloat(col) * px, y: CGFloat(6 - row) * px, width: px, height: px).fill() }
        }
        ("\(n)" as NSString).draw(at: NSPoint(x: 17, y: 0), withAttributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.85)])
    }
}

// the name on the pill: its letters bob in a gentle wave while the pill is idle
final class Wave: NSView {
    var stringValue = "" { didSet { needsDisplay = true } }
    var textColor = NSColor.white { didSet { needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13, weight: .medium)
    var bobbing = true
    var t = 0.0
    var timer: Timer?

    init(_ s: String) {
        super.init(frame: .zero)
        stringValue = s
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in
            guard let self, !self.isHidden else { return }
            self.t += 1.0/30
            if self.bobbing { self.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    var attrs: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: textColor] }
    func sizeToFit() {
        let sz = (stringValue as NSString).size(withAttributes: attrs)
        setFrameSize(NSSize(width: ceil(sz.width) + 1, height: ceil(sz.height) + 4))   // room to bob
    }

    override func draw(_ r: NSRect) {
        var x: CGFloat = 0
        for (i, ch) in stringValue.enumerated() {
            let c = String(ch) as NSString
            let dy = bobbing ? 1.6 * sin(t * 3.2 - Double(i) * 0.75) : 0
            c.draw(at: NSPoint(x: x, y: 2 + dy), withAttributes: attrs)
            x += c.size(withAttributes: attrs).width
        }
    }
}

final class Bar: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate, NSGestureRecognizerDelegate, NSMenuDelegate {
    var provider = ProviderID(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .claude
    var pillProviderMenu: NSMenu?
    private var pillTerminalMenu: NSMenu?
    private var historyClient: CodexHistoryClient?
    private var discoveredThreads: [CodexHistoryClient.Thread] = []
    private var browsedCodexAccount: CodexAccountContext?
    private enum CodexRoute { case terminal, desktop }
    private var codexRoute: CodexRoute = .terminal
    private var selectedCodexThread: CodexHistoryClient.Thread?
    private var selectedCodexAccount: CodexAccountContext?
    private var codexStarting = false
    private var codexAwaitingTurnAck = false
    private var codexTurnID: String?
    private var codexFinalText = ""
    private var codexFileChangePreviews: [String: String] = [:]
    private var codexQueuedEvents: [(String, [String: Any])] = []
    private var codexQueuedRequests: [(Any, String, [String: Any])] = []
    private var codexActivity = ""
    private var codexSendDiagnostic: CodexSendDiagnostic?
    var panel: Panel!
    var field: Field!
    var inputScroll: NSScrollView!
    var inputBackground: NSView!
    var chatGlass: PillGlass!
    var chatTitle: NSTextField!
    var closeChatButton: Tap!
    var petHandle: PetHandle!
    var status: NSTextField!
    var mini: Wave!
    var dot: Goo!
    var fx: Fx!
    var visitors: Visitors!
    var social: Social!
    var socialSeen: [String: Int]? = nil
    var socialTabs: [String: (win: Int, tab: Int)] = [:]
    var ring: Pill!
    var statusItem: NSStatusItem!         // the little goo in the menu bar, so Mochi is always findable
    var meter: NSTextField!              // while Claude works: how long, and how many tokens it has written
    var meterText = ""
    var todoBadge: TodoBadge!
    var todos: [Todo] = []
    var todoMTime: Date?
    var todoPanel: Panel?, todoBox: NSView?
    var outsideMonitor: Any?, localMonitor: Any?
    // a question from Claude (AskUserQuestion), shown with its options as buttons
    var qPanel: Panel?, qBox: NSView?
    var qData: [String: Any]?
    var qShownId = "", qIndex = 0
    var answeringOther = false
    let questionFile = supportDir.appendingPathComponent("question.json")
    let progressFile = supportDir.appendingPathComponent("progress.json")
    var progressSeen = ""
    // the step Claude is on right now ("Add a focus diary to Mochi"), as a little line just above the pill
    var nowPanel: Panel?, nowLabel: NSTextField?
    var nowText = ""
    let doingFile = supportDir.appendingPathComponent("doing.json")
    // the reply bubble, in pages with arrows when it's long
    var pages: [String] = [], page = 0
    var prevBtn: Tap!, nextBtn: Tap!, pageLabel: NSTextField!
    var sending = false
    private var launcherInProgress = false
    private var guidedMessage = GuidedMessageFlow()
    var lastApp: NSRunningApplication?
    var open = false

    // summary bubble that pops up above the bar when Claude finishes a reply (fed by notify.py, a Claude Code Stop hook)
    var bubble: Panel!
    var bubbleText: NSTextField!
    var bubbleProject: NSTextField!
    var lastSeen: Date?
    var hideWork: DispatchWorkItem?
    let lastFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochi/last.json")
    // written by the same hook when a prompt is submitted, so the goo knows Claude is thinking
    let workFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochi/working.json")
    var seenVisitors: Set<String>? = nil
    var lastMidX: CGFloat = 0, lastMoveT = 0.0

    // The collapsed window contains only the pet; the chat grows above it.
    let W: CGFloat = 340, H: CGFloat = 168
    let w: CGFloat = 144, h: CGFloat = 144

    // focus diary: what Mochi did lately, written out whenever it loses focus while the bar is open (to catch focus thieves)
    var recent: [String] = []
    func note(_ s: String) { recent.append("\(String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))) \(s)"); if recent.count > 12 { recent.removeFirst() } }
    func diary(_ why: String) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let line = "\(Date()) FOCUS LOST (\(why)) open=\(open) typed=\(field.stringValue.count) front=\(front) recent=[\(recent.joined(separator: " | "))]\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mochi.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.open else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.diary("app resigned active") }
        }
        // remember the last app you were in (that isn't this bar), to hand focus back after sending
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.bundleIdentifier != Bundle.main.bundleIdentifier { self?.lastApp = a }
        }
        lastApp = NSWorkspace.shared.frontmostApplication

        // start on the screen the mouse is on
        let mouse = NSEvent.mouseLocation
        var scr = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!).visibleFrame
        if let i = Int(ProcessInfo.processInfo.environment["PB_SCREEN"] ?? ""), i < NSScreen.screens.count { scr = NSScreen.screens[i].visibleFrame }
        let initialFrame = PetChatLayout.targetFrame(
            current: NSRect(x: scr.midX - w/2, y: scr.minY + 18, width: w, height: h),
            wasOpen: false, willOpen: false, size: NSSize(width: w, height: h), visible: scr)
        panel = Panel(contentRect: initialFrame,
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.delegate = self

        // Transparent pet when collapsed; the smoked glass is shown only for chat.
        ring = Pill(frame: NSRect(x: 0, y: 0, width: w, height: h))
        ring.wantsLayer = true; ring.layer?.cornerRadius = 16
        ring.layer?.borderWidth = 0; ring.layer?.borderColor = NSColor(white: 0, alpha: 0.45).cgColor
        panel.contentView = ring

        let glass = PillGlass(frame: NSRect(x: 1, y: 1, width: w - 2, height: h - 2))
        chatGlass = glass
        glass.autoresizingMask = [.width, .height]
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 15; glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1; glass.layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        ring.addSubview(glass)

        // tint so the pill stays dark whatever is behind it
        let tint = NSView(frame: glass.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true; tint.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.62).cgColor
        glass.addSubview(tint)

        petHandle = PetHandle(frame: NSRect(x: 0, y: 0, width: w, height: h))
        petHandle.onClick = { [weak self] in self?.catClicked() }
        ring.addSubview(petHandle)
        dot = Goo(frame: NSRect(x: 0, y: 0, width: 132, height: 128))
        ring.addSubview(dot)
        let d = UserDefaults.standard, today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        dot.fed = d.double(forKey: "fedDay") == today ? d.integer(forKey: "fed") : 0
        visitors = Visitors(frame: NSRect(x: 0, y: 0, width: 80, height: 12))
        glass.addSubview(visitors)
        social = Social(frame: NSRect(x: 0, y: 0, width: 60, height: 14))
        glass.addSubview(social)
        social.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clickedSocialBadge(_:))))
        todoBadge = TodoBadge(frame: NSRect(x: 0, y: 0, width: 40, height: 14))
        glass.addSubview(todoBadge)
        todoBadge.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clickedTodoBadge(_:))))
        meter = NSTextField(labelWithString: "")
        meter.font = .monospacedSystemFont(ofSize: 10, weight: .medium); meter.textColor = cyanText
        glass.addSubview(meter)

        // Kept for existing status updates, but never shown in the pet-only view.
        mini = Wave("Eden")
        mini.font = .systemFont(ofSize: 13, weight: .medium)
        mini.textColor = NSColor(white: 1, alpha: 0.85)
        glass.addSubview(mini)

        chatTitle = NSTextField(labelWithString: "Eden")
        chatTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        chatTitle.textColor = .white
        glass.addSubview(chatTitle)
        closeChatButton = Tap(frame: .zero)
        closeChatButton.title = "×"
        closeChatButton.font = .systemFont(ofSize: 21, weight: .regular)
        closeChatButton.isBordered = false
        closeChatButton.target = self
        closeChatButton.action = #selector(collapseChat)
        closeChatButton.toolTip = "Close chat (draft kept)"
        glass.addSubview(closeChatButton)

        inputBackground = NSView(frame: .zero)
        inputBackground.wantsLayer = true
        inputBackground.layer?.cornerRadius = 10
        inputBackground.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        inputBackground.layer?.borderWidth = 1
        inputBackground.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        glass.addSubview(inputBackground)
        inputScroll = NSScrollView(frame: .zero)
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        glass.addSubview(inputScroll)
        field = Field(frame: NSRect(x: 0, y: 0, width: 296, height: 60))
        resetPlaceholder()
        field.font = .systemFont(ofSize: 14); field.textColor = .white
        field.drawsBackground = false; field.isRichText = false
        field.isHorizontallyResizable = false; field.isVerticallyResizable = true
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.containerSize = NSSize(width: 296, height: CGFloat.greatestFiniteMagnitude)
        field.textContainerInset = NSSize(width: 0, height: 4)
        field.delegate = self
        inputScroll.documentView = field

        status = NSTextField(labelWithString: "desktop commands")
        status.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        status.textColor = NSColor(white: 1, alpha: 0.6); status.alignment = .left
        status.frame = NSRect(x: 54, y: 16, width: W - 72, height: 14)
        status.cell?.lineBreakMode = .byTruncatingMiddle
        glass.addSubview(status)

        // on top of everything: the paper plane
        fx = Fx(frame: glass.bounds); fx.autoresizingMask = [.width, .height]
        glass.addSubview(fx)

        let menu = NSMenu()
        let browse = NSMenuItem(title: "Browse Codex Threads…", action: #selector(browseCodexThreads), keyEquivalent: "")
        browse.target = self; menu.addItem(browse)
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advanced.submenu = makeAdvancedMenu(pill: true); menu.addItem(advanced)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login); menu.addItem(.separator())
        let paint = NSMenuItem(title: "Change Original Pet Color…", action: #selector(pickColor(_:)), keyEquivalent: "")
        paint.target = self; menu.addItem(paint); menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Eden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // open at login: switched on once, the first time; after that the menu item decides
        if !UserDefaults.standard.bool(forKey: "loginSet") {
            UserDefaults.standard.set(true, forKey: "loginSet")
            do { try SMAppService.mainApp.register(); login.state = .on } catch { NSLog("login item: \(error)") }
        }
        ring.menu = menu; glass.menu = menu; petHandle.menu = menu
        social.menu = menu; todoBadge.menu = menu

        lay()
        panel.orderFrontRegardless()
        makeStatusItem()

        makeBubble()
        lastSeen = modified()   // don't pop up an old reply at launch
        if let d = try? Data(contentsOf: progressFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { progressSeen = j["text"] as? String ?? "" }
        if let d = try? Data(contentsOf: questionFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["id"] as? String, Date().timeIntervalSince1970 - (j["time"] as? Double ?? 0) > 1800 { qShownId = id }   // a stale question
        reloadTodos(announce: false)
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.checkReply() }

        lastMidX = panel.frame.midX

        // social notifications, only if you said yes in the installer: unread counts read from tabs already open in Chrome
        if !enabledSocial().isEmpty || (ProcessInfo.processInfo.environment["PB_DEMO"] ?? "").contains("social") {
            checkSocial()
            Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkSocial() }
        }

        // PB_DEMO=send in the environment plays the send animation without sending anything (for checking it)
        if (ProcessInfo.processInfo.environment["PB_DEMO"] ?? "").contains("send") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.setOpen(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { self.celebrateSend() }
        }
    }

    // MARK: the menu bar pet

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if ProcessInfo.processInfo.environment["PB_PET_ART"] != "mochi", let cat = CatSprites.idle.first {
            let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .none
                cat.draw(in: rect, from: NSRect(origin: .zero, size: cat.size),
                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                return true
            }
            img.isTemplate = false
            statusItem.button?.image = img
        } else {
            let shape = ["..XXXXX..", ".XXXXXXX.", "XXXXXXXXX", "XX.XXX.XX", "XX.XXX.XX", "XXXXXXXXX", "XXXXXXXXX", "XXXXXXXXXXX"]
            let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
                NSColor.black.setFill()
                for (row, line) in shape.enumerated() { for (col, ch) in line.enumerated() where ch == "X" {
                    NSRect(x: CGFloat(col) * 1.6 + 0.2, y: CGFloat(row) * 1.6 + 3.4, width: 1.6, height: 1.6).fill()
                } }
                return true
            }
            img.isTemplate = true
            statusItem.button?.image = img
        }
        statusItem.button?.toolTip = "Eden"
        let m = NSMenu(); m.delegate = self; statusItem.menu = m
    }

    // the menu is rebuilt each time it opens, so the to-do count and Show/Hide are current
    func menuNeedsUpdate(_ m: NSMenu) {
        guard m === statusItem?.menu else { return }
        m.removeAllItems()
        func item(_ t: String, _ a: Selector) { let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; m.addItem(i) }
        item("Find Eden", #selector(findMochi))
        item("Ask Eden…", #selector(messageMochi))
        let n = todos.filter { $0.done == nil }.count
        item(n > 0 ? "To-do list (\(n))" : "To-do list", #selector(openTodoFromMenu))
        item(panel.isVisible ? "Hide Eden" : "Show Eden", #selector(toggleShown))
        m.addItem(.separator())
        item("Browse Codex Threads…", #selector(browseCodexThreads))
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advanced.submenu = makeAdvancedMenu(); m.addItem(advanced)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off; m.addItem(login)
        m.addItem(withTitle: "Quit Eden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func makeProviderMenu() -> NSMenu {
        let menu = NSMenu()
        for id in ProviderID.allCases {
            let item = NSMenuItem(title: id.adapter.name, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id.rawValue; item.state = id == provider ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeAdvancedMenu(pill: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        providerItem.submenu = makeProviderMenu()
        if pill { pillProviderMenu = providerItem.submenu }
        menu.addItem(providerItem)
        let terminalItem = NSMenuItem(title: "Terminal Destination", action: nil, keyEquivalent: "")
        terminalItem.submenu = makeTerminalDestinationMenu()
        if pill { pillTerminalMenu = terminalItem.submenu }
        menu.addItem(terminalItem)
        let sendItem = NSMenuItem(title: "Send Draft to Selected CLI in Terminal…",
                                  action: #selector(sendAdvancedMessage), keyEquivalent: "")
        sendItem.target = self; menu.addItem(sendItem)
        return menu
    }

    private func makeTerminalDestinationMenu() -> NSMenu {
        let menu = NSMenu()
        for id in ProviderID.allCases {
            let item = NSMenuItem(title: "\(id.adapter.name) in Terminal",
                                  action: #selector(selectTerminalDestination(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id.rawValue
            item.state = id == provider && codexRoute == .terminal ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectTerminalDestination(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let next = ProviderID(rawValue: raw) else { return }
        if next != provider { selectProvider(item) }
        if next == .codex && codexRoute != .terminal { useCodexTerminal() }
        pillTerminalMenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == next.rawValue ? .on : .off
        }
    }

    @objc private func showCodexSendDiagnostics() {
        let enabled = UserDefaults.standard.bool(forKey: "codexSendDiagnosticsEnabled")
        let alert = NSAlert()
        alert.messageText = "Codex send diagnostics"
        if enabled {
            alert.informativeText = codexSendDiagnostic?.report ?? "Enabled. No direct-send attempt has been recorded in this app session."
            alert.addButton(withTitle: "Copy result")
            alert.addButton(withTitle: "Disable")
            alert.addButton(withTitle: "Close")
        } else {
            alert.informativeText = "Enable in-memory diagnostics for future Codex Desktop sends? They record the failing stage, RPC method and code, delivery state, and process failures. They never retain message text, transcripts, thread IDs, paths, or account data."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        if enabled {
            if choice == .alertFirstButtonReturn, let report = codexSendDiagnostic?.report {
                NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.setString(report, forType: .string)
            } else if choice == .alertSecondButtonReturn {
                UserDefaults.standard.set(false, forKey: "codexSendDiagnosticsEnabled")
                codexSendDiagnostic = nil
            }
        } else if choice == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: "codexSendDiagnosticsEnabled")
            codexSendDiagnostic = nil
        }
    }

    @objc private func useCodexTerminal() {
        guard provider == .codex else { return }
        let wasActive = codexStarting || codexTurnID != nil
        clearCodexDestination()
        updateDestinationDisplay()
        if wasActive { flash("Codex turn may continue; follow it in Codex", false) }
    }

    @objc func selectProvider(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let next = ProviderID(rawValue: raw), next != provider else { return }
        let wasActive = codexStarting || codexTurnID != nil
        if provider == .codex { clearCodexDestination() }
        provider = next
        UserDefaults.standard.set(next.rawValue, forKey: "provider")
        pillProviderMenu?.items.forEach { $0.state = ($0.representedObject as? String) == next.rawValue ? .on : .off }
        pillTerminalMenu?.items.forEach { $0.state = ($0.representedObject as? String) == next.rawValue ? .on : .off }
        answeringOther = false; resetPlaceholder()
        dot.thinking = false; dot.asking = false
        meterText = ""; meter.stringValue = ""
        nowText = ""; showStep("")
        qData = nil; hideQuestion(); hideBubble()
        progressSeen = ""; lastSeen = modified()
        if next == .claude {
            qShownId = ""
            if let data = try? Data(contentsOf: questionFile),
               let question = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               Date().timeIntervalSince1970 - (question["time"] as? Double ?? 0) > 1800 {
                qShownId = question["id"] as? String ?? ""
            }
        }
        updateDestinationDisplay()
        if wasActive { flash("Codex turn may continue; follow it in Codex", false) }
        if !open { fitCollapsed() }; lay()
    }

    private func destinationLabel() -> String {
        "desktop commands"
    }

    private func updateDestinationDisplay() {
        status.stringValue = destinationLabel()
        status.textColor = NSColor(white: 1, alpha: 0.6)
        status.toolTip = "Ask for a desktop action. Terminal sending is in Advanced."
        resetPlaceholder()
        if !open { fitCollapsed() }; lay()
    }

    private func clearCodexDestination() {
        if let client = historyClient {
            for (id, method, _) in codexQueuedRequests { declineCodexRequest(id, method, client: client) }
        }
        historyClient?.stop(); historyClient = nil
        selectedCodexThread = nil; selectedCodexAccount = nil; browsedCodexAccount = nil
        discoveredThreads = []; codexRoute = .terminal
        codexStarting = false; codexAwaitingTurnAck = false; codexTurnID = nil
        codexQueuedEvents = []; codexQueuedRequests = []; codexFinalText = ""; codexFileChangePreviews = [:]
        codexActivity = ""; sending = false; dot.thinking = false
    }

    // A separate, consented history surface. It never changes the Terminal destination.
    @objc func browseCodexThreads() {
        if !UserDefaults.standard.bool(forKey: "codexHistoryConsent") {
            let alert = NSAlert()
            alert.messageText = "Browse local Codex threads?"
            alert.informativeText = "Eden will start its own local Codex App Server connection to browse thread titles, directories and selected transcript text. Browsing is read-only. Thread data stays in memory."
            alert.addButton(withTitle: "Allow browsing")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else {
                showBubble("Okay, I didn't open Codex conversations.", project: "Eden", react: false)
                return
            }
            UserDefaults.standard.set(true, forKey: "codexHistoryConsent")
        }
        guard !codexStarting && codexTurnID == nil else {
            historyError("A Codex turn is active. Wait for it to finish before browsing conversations.", closeConnection: false)
            return
        }
        clearCodexDestination()
        historyClient?.stop(); historyClient = nil; discoveredThreads = []; browsedCodexAccount = nil
        guard let executable = executablePath(for: CodexProvider()) else {
            historyError("Codex CLI is unavailable. Install it separately before browsing threads."); return
        }
        let client = CodexHistoryClient(executable: executable)
        historyClient = client
        client.onNotification = { [weak self, weak client] method, params in
            guard let self, let client, self.historyClient === client else { return }
            self.codexNotification(method, params, client: client)
        }
        client.onServerRequest = { [weak self, weak client] id, method, params in
            guard let self, let client, self.historyClient === client else { return }
            self.codexServerRequest(id, method, params, client: client)
        }
        client.onDisconnect = { [weak self, weak client] reason in
            guard let self, let client, self.historyClient === client else { return }
            self.codexDisconnected(reason)
        }
        flash("reading Codex threads…", false)
        client.connect { [weak self, weak client] result in
            guard let self, let client, self.historyClient === client else { return }
            if case .failure(let error) = result { self.historyError(error.localizedDescription); return }
            client.request("account/read", ["refreshToken": false]) { [weak self, weak client] result in
                guard let self, let client, self.historyClient === client else { return }
                switch result {
                case .failure(let error): self.historyError(error.localizedDescription)
                case .success(let response):
                    guard let requiresAuth = response["requiresOpenaiAuth"] as? Bool,
                          response.keys.contains("account") else {
                        self.historyError("This Codex version returned an unsupported account response."); return
                    }
                    if requiresAuth &&
                        (response["account"] == nil || response["account"] is NSNull) {
                        self.historyError("Codex sign-in is unavailable. Sign in using Codex, then try again.")
                    } else {
                        self.browsedCodexAccount = CodexAccountContext(response)
                        self.loadCodexThreads(client, cursor: nil, page: 0, seen: [])
                    }
                }
            }
        }
    }

    private func loadCodexThreads(_ client: CodexHistoryClient, cursor: String?, page: Int, seen: Set<String>) {
        var params: [String: Any] = ["limit": 25, "useStateDbOnly": true,
            "sourceKinds": ["cli", "vscode", "appServer", "unknown"], "sortKey": "updated_at"]
        if let cursor { params["cursor"] = cursor }
        client.request("thread/list", params) { [weak self, weak client] result in
            guard let self, let client, self.historyClient === client else { return }
            switch result {
            case .failure(let error): self.historyError(error.localizedDescription)
            case .success(let response):
                guard let values = response["data"] as? [[String: Any]] else {
                    self.historyError("This Codex version returned an unsupported thread list response."); return
                }
                let parsed = values.compactMap(CodexHistoryClient.Thread.init)
                guard parsed.count == values.count else {
                    self.historyError("Codex returned thread metadata Eden cannot safely display."); return
                }
                self.discoveredThreads.append(contentsOf: parsed)
                if let next = response["nextCursor"] as? String, !next.isEmpty, page < 3, !seen.contains(next) {
                    self.loadCodexThreads(client, cursor: next, page: page + 1, seen: seen.union([next]))
                } else { self.showCodexThreadPicker(client) }
            }
        }
    }

    private func showCodexThreadPicker(_ client: CodexHistoryClient) {
        guard historyClient === client else { return }
        guard !discoveredThreads.isEmpty else {
            historyError("No local Codex threads were returned for this account, host and source filter."); return
        }
        let alert = NSAlert()
        alert.messageText = "Local Codex threads"
        alert.informativeText = "Showing up to 100 local threads. Preview the latest 8 turns or open a thread in Codex."
        let picker = CodexThreadPickerView(threads: discoveredThreads)
        alert.accessoryView = picker
        alert.addButton(withTitle: "View selected")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            guard let selected = picker.selected else { historyError("No thread was selected."); return }
            readCodexThread(client, selected)
        } else { client.stop(); historyClient = nil; discoveredThreads = [] }
    }

    private func selectCodexConversation(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread) {
        guard historyClient === client, thread.local else {
            historyError("This thread is not a confirmed local Codex conversation."); return
        }
        guard let account = browsedCodexAccount else {
            historyError("Direct sending requires a verifiable ChatGPT Codex account. Read-only browsing is still available."); return
        }
        if provider != .codex {
            let item = NSMenuItem()
            item.representedObject = ProviderID.codex.rawValue
            selectProvider(item)
        }
        selectedCodexThread = thread; selectedCodexAccount = account
        codexRoute = .desktop; discoveredThreads = []
        updateDestinationDisplay()
        flash("Codex Desktop selected")
    }

    private func readCodexThread(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread) {
        client.request("thread/read", ["threadId": thread.id]) { [weak self, weak client] result in
            guard let self, let client, self.historyClient === client else { return }
            switch result {
            case .failure(let error): self.historyError(error.localizedDescription)
            case .success(let response):
                guard let value = response["thread"] as? [String: Any], value["id"] as? String == thread.id else {
                    self.historyError("Codex could not confirm the selected thread."); return
                }
                client.request("thread/turns/list", ["threadId": thread.id, "limit": 8,
                    "sortDirection": "desc", "itemsView": "full"]) { [weak self, weak client] result in
                    guard let self, let client, self.historyClient === client else { return }
                    switch result {
                    case .failure(let error):
                        self.showCodexTranscript(client, thread, turns: [], note: "Transcript unavailable: \(error.localizedDescription)")
                    case .success(let response):
                        guard let turns = response["data"] as? [[String: Any]] else {
                            self.showCodexTranscript(client, thread, turns: [], note: "Codex returned an unsupported transcript response."); return
                        }
                        self.showCodexTranscript(client, thread, turns: turns)
                    }
                }
            }
        }
    }

    private func showCodexTranscript(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread,
                                     turns: [[String: Any]], note: String? = nil) {
        var lines: [String] = []
        for turn in turns.reversed() {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items {
                if item["type"] as? String == "userMessage", let content = item["content"] as? [[String: Any]] {
                    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { lines.append("YOU: " + String(text.prefix(500))) }
                } else if item["type"] as? String == "agentMessage", let text = item["text"] as? String,
                          !text.isEmpty { lines.append("CODEX: " + String(text.prefix(500))) }
            }
        }
        let body = note ?? (lines.isEmpty ? "No text messages in the latest 8 turns." : lines.joined(separator: "\n\n"))
        let alert = NSAlert()
        alert.messageText = thread.title
        alert.informativeText = "ID: \(thread.id)\nDirectory: \(thread.cwd)\nSource: \(thread.source) · Status: \(thread.status)\nLatest 8 turns only"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 300))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.string = String(body.prefix(8_000)); view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = view; alert.accessoryView = scroll
        if thread.local { alert.addButton(withTitle: "Open in Codex") }
        alert.addButton(withTitle: "Back to threads")
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        if thread.local && choice == .alertFirstButtonReturn {
            guard let url = URL(string: "codex://threads/\(thread.id)"),
                  NSWorkspace.shared.open(url) else {
                historyError("Codex Desktop could not open this local thread."); return
            }
            client.stop(); historyClient = nil; discoveredThreads = []
        } else { showCodexThreadPicker(client) }
    }

    private func historyError(_ message: String, closeConnection: Bool = true) {
        if closeConnection { historyClient?.stop(); historyClient = nil; discoveredThreads = [] }
        showBubble("I couldn't load Codex conversations. Your draft is still here.",
                   project: "Eden", react: false)
        let alert = NSAlert()
        alert.messageText = "Codex threads unavailable"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // bring the pill to the bottom middle of the screen you're on, and say hi
    @objc func findMochi() {
        let mouse = NSEvent.mouseLocation
        let scr = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!).visibleFrame
        let f = panel.frame
        panel.setFrame(NSRect(x: scr.midX - f.width/2, y: scr.minY + 18, width: f.width, height: f.height), display: true)
        panel.orderFrontRegardless(); repositionPanels()
        dot.greet()
    }
    @objc func messageMochi() { if !panel.isVisible { findMochi() }; setOpen(true) }
    @objc func openTodoFromMenu() { if !panel.isVisible { findMochi() }; showTodoList() }
    @objc func toggleShown() {
        if panel.isVisible { setOpen(false); hideBubble(); hideTodoList(); nowPanel?.orderOut(nil); panel.orderOut(nil) } else { findMochi() }
    }

    // MARK: colour: the system colour picker, live
    @objc func pickColor(_ sender: Any?) {
        let panel = NSColorPanel.shared; panel.setTarget(self); panel.setAction(#selector(colorPicked(_:)))
        panel.color = mochiGoo.body; panel.showsAlpha = false; NSApp.activate(ignoringOtherApps: true); panel.orderFront(nil)
    }
    @objc func colorPicked(_ panel: NSColorPanel) {
        mochiGoo = gooColors(panel.color); dot.colors = mochiGoo; fx.color = mochiGoo.body; saveColor(panel.color)
    }

    // (the visitors strip is kept for anyone who wants to feed it their own list: call showVisitors with [["name", "tint", "page"]])
    func showVisitors(_ here: [[String: Any]]) {
        let tint: [String: NSColor] = ["mint": hex("#7ad3a3"), "lilac": hex("#b89bff"), "sky": hex("#8cc1ff")]
        visitors.tints = here.map { tint[$0["tint"] as? String ?? ""] ?? hex("#7ad3a3") }
        func place(_ m: [String: Any]) -> String {
            var p = (m["page"] as? String ?? "").replacingOccurrences(of: ".html", with: "")
            if p.hasPrefix("app#") { p = String(p.dropFirst(4)) } else if p == "app" || p.isEmpty { p = "home" }
            return p
        }
        visitorNote = here.isEmpty ? "" : "Here now:\n" + here.map { "\($0["name"] as? String ?? "Someone") · \(place($0))" }.joined(separator: "\n")
        ring.toolTip = tooltipText(); petHandle.toolTip = tooltipText()
        // someone new: the goo says hi, and the bubble says who
        let ids = Set(here.compactMap { $0["id"] as? String })
        if let seen = seenVisitors, let m = here.first(where: { !seen.contains($0["id"] as? String ?? "") }) {
            dot.greet()
            showBubble("\(m["name"] as? String ?? "Someone") just arrived on \(place(m))", project: "", react: false)
        }
        seenVisitors = ids
        if !open { fitCollapsed() }
        lay()
    }

    // MARK: social notifications: read the titles of tabs already open in Chrome (no logins, nothing fetched)
    func checkSocial() {
        note("social check")
        let demoSocial = (ProcessInfo.processInfo.environment["PB_DEMO"] ?? "").contains("social")   // demo badges: never touches Chrome
        let r = demoSocial ? (out: "", err: nil) : run("""
        if application "Google Chrome" is not running then return ""
        set out to ""
        set sep to character id 9   -- a real tab character (inside Chrome's tell block, "tab" means a browser tab)
        tell application "Google Chrome"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set out to out & (id of w) & sep & i & sep & (URL of t) & sep & (title of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """)
        if r.err != nil { return }
        var best: [String: Int] = [:]
        var where_: [String: (win: Int, tab: Int)] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let win = Int(f[0]), let tab = Int(f[1]) else { continue }
            let url = String(f[2]).lowercased(), title = String(f[3])
            guard let site = socialSites.filter({ enabledSocial().contains($0.key) }).first(where: { s in s.hosts.contains { url.contains("://" + $0) || url.contains("." + $0) } }) else { continue }
            // "(3) Instagram", "(12+) Feed | LinkedIn"
            var n = 0
            if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
                n = Int(title[title.index(after: title.startIndex)..<close].filter(\.isNumber)) ?? 0
            }
            if where_[site.key] == nil || n > (best[site.key] ?? 0) { where_[site.key] = (win, tab) }
            best[site.key] = max(best[site.key] ?? 0, n)
        }
        if (ProcessInfo.processInfo.environment["PB_DEMO"] ?? "").contains("social") { best = ["ig": 3, "li": 12, "th": 1] }   // for checking the look
        socialTabs = where_
        social.counts = socialSites.compactMap { s in (best[s.key] ?? 0) > 0 ? (s, best[s.key]!) : nil }
        ring.toolTip = tooltipText(); petHandle.toolTip = tooltipText()
        // a count went up: Mochi hops, and the bubble says where
        if let seen = socialSeen {
            let ups = socialSites.compactMap { s -> String? in
                let d = (best[s.key] ?? 0) - (seen[s.key] ?? 0)
                return d > 0 ? "\(d) new on \(s.name)" : nil
            }
            if !ups.isEmpty { showBubble(ups.joined(separator: " · "), project: "notifications", react: false); dot.hop() }
        }
        socialSeen = best
        if !open { fitCollapsed() }
        lay()
    }

    // click a badge: jump to that tab in Chrome
    func openSocial(_ site: SocialSite) {
        guard let w = socialTabs[site.key] else { return }
        _ = run("""
        tell application "Google Chrome"
            set w to (first window whose id is \(w.win))
            set active tab index of w to \(w.tab)
            set index of w to 1
            activate
        end tell
        """)
    }

    var visitorNote = ""
    func tooltipText() -> String? {
        var parts: [String] = []
        if !social.counts.isEmpty { parts.append(social.counts.map { "\($0.site.name): \($0.n)" }.joined(separator: " · ")) }
        if !visitorNote.isEmpty { parts.append(visitorNote) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    var collapsedWidth: CGFloat { w }

    func fitCollapsed() {
        guard !open else { return }
        let W2 = collapsedWidth, f = panel.frame
        if abs(f.width - W2) > 0.5 { panel.setFrame(NSRect(x: f.midX - W2/2, y: f.minY, width: W2, height: h), display: true) }
    }

    // The pet stays at the lower left while chat grows above it.
    func lay() {
        dot.catDrawSize = open ? 28 : 128
        dot.frame = NSRect(x: open ? 12 : 6, y: open ? 12 : 8,
                           width: open ? 32 : 132, height: open ? 28 : 128)
        dot.needsDisplay = true
        petHandle.frame = NSRect(x: open ? 8 : 0, y: open ? 8 : 0,
                                 width: open ? 44 : w, height: open ? 40 : h)
        chatGlass.isHidden = !open
        mini.isHidden = true
        guard open else { return }
        chatTitle.frame = NSRect(x: 16, y: H - 31, width: 245, height: 20)
        closeChatButton.frame = NSRect(x: W - 36, y: H - 37, width: 28, height: 28)
        var x: CGFloat = 16
        visitors.frame = NSRect(x: x, y: H - 57, width: max(visitors.width, 1), height: 12)
        visitors.isHidden = visitors.tints.isEmpty
        if !visitors.isHidden { x = visitors.frame.maxX + 8 }
        social.frame = NSRect(x: x, y: H - 59, width: max(social.width, 1), height: 14)
        social.isHidden = social.counts.isEmpty
        if !social.isHidden { x = social.frame.maxX + 8 }
        todoBadge.frame = NSRect(x: x, y: H - 57, width: max(todoBadge.width, 1), height: 14)
        todoBadge.isHidden = todoBadge.n == 0
        if !todoBadge.isHidden { x = todoBadge.frame.maxX + 8 }
        meter.sizeToFit()
        meter.frame.origin = NSPoint(x: min(x, W - meter.frame.width - 12), y: H - 58)
        meter.isHidden = meterText.isEmpty
        inputBackground.frame = NSRect(x: 12, y: 42, width: W - 24, height: 67)
        inputScroll.frame = NSRect(x: 19, y: 48, width: W - 38, height: 55)
        status.frame = NSRect(x: 54, y: 17, width: W - 68, height: 15)
        inputScroll.isHidden = false
        status.isHidden = false
    }

    private func catClicked() {
        if open { setOpen(false); return }
        if todoPanel?.isVisible == true && (todoPanel?.alphaValue ?? 0) > 0.5 { hideTodoList(); return }
        setOpen(true)
    }

    @objc private func clickedSocialBadge(_ gesture: NSClickGestureRecognizer) {
        if let site = social.site(at: gesture.location(in: social)) { openSocial(site) }
    }

    @objc private func clickedTodoBadge(_ gesture: NSClickGestureRecognizer) { toggleTodoList() }

    @objc private func collapseChat() { setOpen(false) }

    // grow or shrink around the bar's current bottom centre
    func setOpen(_ o: Bool) {
        note("setOpen \(o)")
        guard o != open else { return }
        let wasOpen = open
        open = o
        let f = panel.frame
        let size = o ? NSSize(width: W, height: H) : NSSize(width: collapsedWidth, height: h)
        let to = PetChatLayout.targetFrame(current: f, wasOpen: wasOpen, willOpen: o, size: size,
                                           visible: panel.screen?.visibleFrame)
        panel.hasShadow = o
        ring.layer?.borderWidth = o ? 1 : 0
        if !o { inputScroll.isHidden = true; status.isHidden = true; chatGlass.isHidden = true }
        else { chatGlass.isHidden = false }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.22; c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(to, display: true)
        }, completionHandler: { [weak self] in self?.lay() })
        if o {
            lay()
            NSApp.activate(ignoringOtherApps: true)   // otherwise typing keeps going to whatever app was in front (Terminal, after a send)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
        }
    }

    // click away with nothing typed: fold back up
    func windowDidResignKey(_ n: Notification) {
        if open && !field.stringValue.isEmpty { diary("bar resigned key") }
        if field.stringValue.isEmpty && !sending { setOpen(false) }
    }

    func makeBubble() {
        bubble = Panel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 60),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble.level = .floating
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubble.backgroundColor = .clear; bubble.isOpaque = false; bubble.hasShadow = true

        let ring = NSView(); ring.wantsLayer = true; ring.layer?.cornerRadius = 15
        ring.layer?.borderWidth = 1; ring.layer?.borderColor = NSColor(white: 0, alpha: 0.45).cgColor
        bubble.contentView = ring

        let glass = NSVisualEffectView(frame: ring.bounds.insetBy(dx: 1, dy: 1)); glass.autoresizingMask = [.width, .height]
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 14; glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1; glass.layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        ring.addSubview(glass)
        let tint = NSView(frame: glass.bounds); tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true; tint.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.62).cgColor
        glass.addSubview(tint)

        bubbleProject = NSTextField(labelWithString: "")
        bubbleProject.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        bubbleProject.textColor = NSColor(red: 0.5, green: 0.9, blue: 1, alpha: 0.9)
        glass.addSubview(bubbleProject)

        bubbleText = NSTextField(wrappingLabelWithString: "")
        bubbleText.font = .systemFont(ofSize: 13); bubbleText.textColor = NSColor(white: 1, alpha: 0.92)
        bubbleText.maximumNumberOfLines = 0; bubbleText.cell?.wraps = true
        glass.addSubview(bubbleText)

        // long replies come in pages: arrows on the sides, and "2/5" up top
        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium); pageLabel.textColor = NSColor(white: 1, alpha: 0.5)
        glass.addSubview(pageLabel)
        func arrow(_ t: String, _ a: Selector) -> Tap {
            let b = Tap(frame: .zero); b.isBordered = false; b.target = self; b.action = a
            b.attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: NSColor(white: 1, alpha: 0.8)])
            glass.addSubview(b); return b
        }
        prevBtn = arrow("‹", #selector(prevPage)); nextBtn = arrow("›", #selector(nextPage))

        // click to dismiss (not on the arrows)
        let click = NSClickGestureRecognizer(target: self, action: #selector(hideBubble)); click.delegate = self
        ring.addGestureRecognizer(click)
    }

    func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: lastFile.path))?[.modificationDate] as? Date
    }

    func checkReply() {
        if provider == .codex { checkTodosAndNudge(); return }
        // thinking: a prompt went in after the last reply came out (and not too long ago)
        let wm = (try? FileManager.default.attributesOfItem(atPath: workFile.path))?[.modificationDate] as? Date
        let lm = modified()
        dot.thinking = wm != nil && (lm == nil || wm! > lm!) && Date().timeIntervalSince(wm!) < 1800
        let newest = (wm ?? .distantPast) > (lm ?? .distantPast) ? workFile : lastFile
        if let d = try? Data(contentsOf: newest), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let p = (j["project"] as? String)?.lowercased() {
            _ = p; dot.colors = mochiGoo
            fx.color = dot.colors.body
        }
        mini.bobbing = !open && mini.stringValue == "Eden" && !dot.sleeping

        // the meter: how long Claude has been at it, and how many tokens it has written this turn
        var prog: [String: Any] = [:]
        if dot.thinking, let d = try? Data(contentsOf: progressFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { prog = j }
        var mt = ""
        if dot.thinking, let w = wm {
            let secs = max(0, Int(Date().timeIntervalSince(w)))
            mt = String(format: "%d:%02d", secs / 60, secs % 60)
            if let tk = prog["tokens"] as? Int, tk > 0 { mt += " · " + (tk >= 1000 ? String(format: "%.1fk", Double(tk) / 1000) : "\(tk)") }
        }
        if mt != meterText { meterText = mt; meter.stringValue = mt; if !open { fitCollapsed() }; lay() }
        // the step Claude is on
        var step = ""
        if dot.thinking, let w = wm, let d = try? Data(contentsOf: doingFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let t = j["text"] as? String, (j["time"] as? Double ?? 0) >= w.timeIntervalSince1970 - 1 { step = t }
        if step != nowText { nowText = step; showStep(step) }
        // what Claude says while it works (not just when it's done)
        if let said = prog["text"] as? String, !said.isEmpty, said != progressSeen {
            progressSeen = said
            if qPanel?.isVisible != true { showBubble(said, project: (prog["project"] as? String ?? "") + " · working", react: false, full: said); dot.hop() }
        }

        // a question from Claude
        if let d = try? Data(contentsOf: questionFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["id"] as? String {
            if id != qShownId { qShownId = id; qData = j; qIndex = 0; showQuestion() }
        } else if qPanel?.isVisible == true { hideQuestion() }

        checkTodosAndNudge()

        guard let m = lm, m != lastSeen else { return }
        lastSeen = m
        guard let data = try? Data(contentsOf: lastFile),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = j["text"] as? String, !text.isEmpty else { return }
        progressSeen = ""
        showBubble(text, project: j["project"] as? String ?? "", full: j["full"] as? String)
    }

    func checkTodosAndNudge() {
        // the to-do list changed on disk (Claude may have added something)
        let tm = (try? FileManager.default.attributesOfItem(atPath: todoFile.path))?[.modificationDate] as? Date
        if tm != todoMTime { reloadTodos(announce: true) }

        // good morning: once a day, how many things are on the list
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, open_ = todos.filter { $0.done == nil }.count
        if dot.hour >= 6 && dot.hour < 12 && open_ > 0 && !dot.sleeping && UserDefaults.standard.double(forKey: "nudgeDay") != today && bubble?.isVisible != true && qPanel?.isVisible != true {
            UserDefaults.standard.set(today, forKey: "nudgeDay")
            showBubble("good morning! ☕ \(open_) thing\(open_ == 1 ? "" : "s") on your to-do list. Click the checklist to see.", project: "to-do", react: false); dot.hop()
        }

    }

    func showBubble(_ text: String, project: String, react: Bool = true, full: String? = nil) {
        note("bubble shown")
        // the goo reacts: a proud double hop with sparkles when something went live, otherwise a hop
        if react {
            if text.range(of: #"\b(live|pushed|deployed|shipped|published)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { dot.proud() } else { dot.hop() }
        }
        let body = (full?.count ?? 0) > text.count ? full! : text
        bubbleProject.stringValue = "Eden · " + project
        bubbleProject.sizeToFit()
        pages = paginate(body, width: 352 - 28, maxH: 88)
        if pages.count > 1 { pages = paginate(body, width: 392 - 68, maxH: 88) }   // narrower, to make room for the arrows
        page = 0
        renderPage()

        hideWork?.cancel()
        bubble.alphaValue = 0
        bubble.orderFrontRegardless()
        let to = bubble.frame
        bubble.setFrame(to.offsetBy(dx: 0, dy: -6), display: false)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.25
            bubble.animator().alphaValue = 1
            bubble.animator().setFrame(to, display: true)
        }
        armHide(pages.count > 1 ? 16 : 5 + Double(body.count) / 25)
    }

    // hide after a while, but never while the mouse is resting on it
    func armHide(_ secs: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSMouseInRect(NSEvent.mouseLocation, self.bubble.frame, false) { self.armHide(3) } else { self.hideBubble() }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w)
    }

    // split a long reply into pages that fit, breaking after a sentence where one ends late enough on the page
    func paginate(_ s: String, width: CGFloat, maxH: CGFloat) -> [String] {
        let m = NSTextField(wrappingLabelWithString: ""); m.font = bubbleText.font
        func h(_ t: String) -> CGFloat { m.stringValue = t; return m.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000)).height }
        var toks: [String] = []
        for (i, line) in s.components(separatedBy: "\n").enumerated() { if i > 0 { toks.append("\n") }; toks += line.split(separator: " ").map(String.init) }
        func join(_ ts: ArraySlice<String>) -> String {
            var out = ""
            for t in ts { if t == "\n" { out += "\n" } else { out += (out.isEmpty || out.hasSuffix("\n") ? "" : " ") + t } }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [String] = [], i = 0
        while i < toks.count {
            var j = i
            while j < toks.count && (j == i || h(join(toks[i...j])) <= maxH) { j += 1 }
            var end = j
            if j < toks.count, let k = (i..<j).reversed().first(where: { k in
                let t = toks[k]; return (t == "\n" || t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?") || t.hasSuffix(":")) && k - i >= (j - i) / 2 }) { end = k + 1 }
            let p = join(toks[i..<end]); if !p.isEmpty { out.append(p) }
            i = end
        }
        return out.isEmpty ? [s] : out
    }

    func renderPage() {
        let multi = pages.count > 1, W: CGFloat = multi ? 392 : 352, pad: CGFloat = 14, side: CGFloat = multi ? 34 : pad, tw = W - side * 2
        let m = NSTextField(wrappingLabelWithString: ""); m.font = bubbleText.font
        func h(_ t: String) -> CGFloat { m.stringValue = t; return ceil(m.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: tw, height: 10000)).height) }
        let th = h(pages[page]), maxTh = multi ? pages.map(h).max()! : th   // same height on every page
        let H = pad + maxTh + 6 + 14 + pad
        bubbleText.stringValue = pages[page]
        bubbleText.frame = NSRect(x: side, y: pad + maxTh - th, width: tw, height: th)
        bubbleProject.frame.origin = NSPoint(x: side, y: pad + maxTh + 6)
        pageLabel.stringValue = multi ? "\(page + 1)/\(pages.count)" : ""
        pageLabel.sizeToFit(); pageLabel.frame.origin = NSPoint(x: W - 2 - side - pageLabel.frame.width, y: pad + maxTh + 6)
        for (b, ok, x) in [(prevBtn!, page > 0, CGFloat(4)), (nextBtn!, page < pages.count - 1, W - 2 - 30)] {
            b.isHidden = !multi; b.isEnabled = ok; b.alphaValue = ok ? 1 : 0.25
            b.frame = NSRect(x: x, y: pad, width: 26, height: maxTh)
        }
        placeBubble(NSSize(width: W, height: H))
    }
    @objc func prevPage() { if page > 0 { page -= 1; renderPage(); armHide(16) } }
    @objc func nextPage() { if page < pages.count - 1 { page += 1; renderPage(); armHide(16) } }

    // clicks on the bubble's own buttons aren't "click to dismiss"
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith e: NSEvent) -> Bool {
        guard let v = g.view else { return true }
        let pt = v.convert(e.locationInWindow, from: nil)
        return !(v.hitTest(pt) is NSButton)
    }

    // sits just above the bar, centred on it, kept on screen. A question sits right on the bar; the others stack above it
    func placeAbove(_ p: NSWindow, _ size: NSSize) {
        let f = panel.frame
        var y = f.maxY + 10
        if p !== nowPanel, let n = nowPanel, n.isVisible, n.alphaValue > 0 { y = n.frame.maxY + 6 }
        if p !== qPanel, p !== nowPanel, let q = qPanel, q.isVisible { y = q.frame.maxY + 8 }
        var r = NSRect(x: f.midX - size.width/2, y: y, width: size.width, height: size.height)
        if let v = panel.screen?.visibleFrame {
            r.origin.x = min(max(r.minX, v.minX + 8), v.maxX - size.width - 8)
            if r.maxY > v.maxY { r.origin.y = f.minY - 10 - size.height }   // no room above: go below
        }
        p.setFrame(r, display: true)
    }
    func placeBubble(_ size: NSSize? = nil) { placeAbove(bubble, size ?? bubble.frame.size) }

    @objc func hideBubble() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.3; bubble.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.bubble.orderOut(nil) })
    }

    // the bubble follows the bar when it's dragged or resized
    func windowDidMove(_ n: Notification) {
        repositionPanels()
        // flung: the goo stretches behind and jiggles
        let now = CACurrentMediaTime(), mx = panel.frame.midX, dt = now - lastMoveT
        if dt > 0, dt < 0.1, !NSAnimationContext.current.allowsImplicitAnimation {
            let vx = Double(mx - lastMidX) / dt
            if abs(vx) > 250 { dot.fling(vx) }
        }
        lastMidX = mx; lastMoveT = now
    }
    func windowDidResize(_ n: Notification) { repositionPanels() }
    func repositionPanels() {
        if let n = nowPanel, n.isVisible { placeAbove(n, n.frame.size) }
        if let q = qPanel, q.isVisible { placeAbove(q, q.frame.size) }
        if bubble?.isVisible == true { placeBubble() }
        if let t = todoPanel, t.isVisible { placeAbove(t, t.frame.size) }
    }

    // Return runs the command; Shift-Return inserts a line break. Escape closes the chat.
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else { send() }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if guidedMessage.isActive { cancelGuidedMessage() }
            setOpen(false); panel.resignKey(); lastApp?.activate(); return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) { field.needsDisplay = true }

    // a short note in whichever label is showing
    func flash(_ s: String, _ ok: Bool = true) {
        let c = ok ? NSColor(red: 0.5, green: 0.9, blue: 1, alpha: 0.9) : NSColor(red: 1, green: 0.55, blue: 0.55, alpha: 0.95)
        status.stringValue = s; status.textColor = c
        mini.stringValue = s; mini.textColor = c; mini.sizeToFit(); fitCollapsed(); lay(); mini.needsDisplay = true
        if !open, bubble != nil { showBubble(s, project: "Eden", react: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.status.stringValue = self.destinationLabel(); self.status.textColor = NSColor(white: 1, alpha: 0.6)
            self.mini.stringValue = "Eden"; self.mini.textColor = NSColor(white: 1, alpha: 0.85); self.mini.sizeToFit(); self.fitCollapsed(); self.lay()
        }
    }

    @objc func toggleLogin(_ it: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item: \(error)") }
        it.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: sending

    private func safeCodexStatus(_ status: String) -> String {
        ["notLoaded", "idle", "active", "systemError"].contains(status) ? status : "unsupported"
    }

    private func recordCodexReadStatus(_ status: String, afterRejection: Bool = false) {
        guard var diagnostic = codexSendDiagnostic else { return }
        if afterRejection { diagnostic.readStatusAfterRejection = safeCodexStatus(status) }
        else { diagnostic.readStatusBeforeResume = safeCodexStatus(status) }
        codexSendDiagnostic = diagnostic
    }

    private func markCodexDiagnostic(stage: String, method: String? = nil, summary: String? = nil,
                                     attempted: Bool? = nil, delivery: String? = nil) {
        guard var diagnostic = codexSendDiagnostic else { return }
        diagnostic.stage = stage
        if let method { diagnostic.method = method }
        if let summary { diagnostic.summary = summary }
        if let attempted { diagnostic.turnStartAttempted = attempted }
        if let delivery { diagnostic.delivery = delivery }
        codexSendDiagnostic = diagnostic
    }

    private func failCodexDiagnostic(stage: String, method: String, error: Error?,
                                     summary: String, delivery: String) {
        guard var diagnostic = codexSendDiagnostic else { return }
        diagnostic.stage = stage; diagnostic.method = method; diagnostic.delivery = delivery
        if let failure = error as? CodexHistoryClient.Failure {
            diagnostic.code = failure.rpcCode
            diagnostic.summary = failure.safeSummary
        } else { diagnostic.summary = summary }
        codexSendDiagnostic = diagnostic
    }

    private func codexTransportFailed(_ failure: CodexHistoryClient.Failure) {
        guard var diagnostic = codexSendDiagnostic else { return }
        switch failure {
        case .timeout(let method): diagnostic.transport = "timeout during \(method)"
        case .exited(let status): diagnostic.transport = "process exited (status \(status))"
        default: diagnostic.transport = "connection closed or protocol error"
        }
        if diagnostic.delivery == "pending acknowledgment" {
            diagnostic.delivery = "uncertain"; diagnostic.summary = failure.safeSummary
        } else if diagnostic.delivery == "acknowledged" {
            diagnostic.stage = "response stream"; diagnostic.method = "turn/completed"
            diagnostic.delivery = "acknowledged; completion unknown"
            diagnostic.summary = failure.safeSummary
        }
        codexSendDiagnostic = diagnostic
    }

    private func codexIsSelected(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread) -> Bool {
        provider == .codex && codexRoute == .desktop && historyClient === client &&
            selectedCodexThread?.id == thread.id && selectedCodexThread?.cwd == thread.cwd
    }

    private func verifyCodexAccount(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread,
                                    _ done: @escaping (Result<Void, Error>) -> Void) {
        client.request("account/read", ["refreshToken": false]) { [weak self, weak client] result in
            guard let self, let client, self.codexIsSelected(client, thread) else { return }
            switch result {
            case .failure(let error): done(.failure(error))
            case .success(let value):
                guard let expected = self.selectedCodexAccount, CodexAccountContext(value) == expected else {
                    done(.failure(CodexHistoryClient.Failure.validation("Codex account context changed; reselect the conversation")))
                    return
                }
                done(.success(()))
            }
        }
    }

    private func verifyCodexThread(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread,
                                   method: String, _ done: @escaping (Result<Void, Error>) -> Void) {
        let params: [String: Any] = method == "thread/resume"
            ? ["threadId": thread.id, "excludeTurns": true] : ["threadId": thread.id]
        client.request(method, params) { [weak self, weak client] result in
            guard let self, let client, self.codexIsSelected(client, thread) else { return }
            switch result {
            case .failure(let error): done(.failure(error))
            case .success(let value):
                guard let metadata = value["thread"] as? [String: Any],
                      let current = CodexHistoryClient.Thread(metadata) else {
                    done(.failure(CodexHistoryClient.Failure.validation("Unsupported thread metadata; no message was sent")))
                    return
                }
                if method == "thread/read", codexSendDiagnostic?.stage == "thread before resume" {
                    recordCodexReadStatus(current.status)
                }
                guard current.id == thread.id else {
                    done(.failure(CodexHistoryClient.Failure.validation("Thread ID changed; no message was sent"))); return
                }
                guard current.cwd == thread.cwd,
                      method != "thread/resume" || value["cwd"] as? String == thread.cwd else {
                    done(.failure(CodexHistoryClient.Failure.validation("Thread working directory changed; no message was sent"))); return
                }
                guard current.projectID == thread.projectID, current.modelProvider == thread.modelProvider,
                      current.local else {
                    done(.failure(CodexHistoryClient.Failure.validation("Thread project, model provider or locality changed; no message was sent"))); return
                }
                guard current.status == "idle" || current.status == "notLoaded" else {
                    let state = ["active", "systemError"].contains(current.status) ? current.status : "unsupported"
                    done(.failure(CodexHistoryClient.Failure.validation("Thread status in this App Server is \(state); no message was sent")))
                    return
                }
                done(.success(()))
            }
        }
    }

    private func sendToCodexDesktop(_ text: String) {
        if UserDefaults.standard.bool(forKey: "codexSendDiagnosticsEnabled") {
            codexSendDiagnostic = CodexSendDiagnostic()
        }
        guard !codexStarting && codexTurnID == nil else {
            failCodexDiagnostic(stage: "turn status", method: "none", error: nil,
                                summary: "A turn is already in progress", delivery: "not sent")
            flash("Codex is already working; draft kept", false); return
        }
        guard let client = historyClient, let thread = selectedCodexThread,
              selectedCodexAccount != nil, thread.local else {
            failCodexDiagnostic(stage: "destination selection", method: "none", error: nil,
                                summary: "No verified selected destination or connection", delivery: "not sent")
            flash("Codex Desktop destination unavailable; reselect it", false); return
        }
        if var diagnostic = codexSendDiagnostic {
            diagnostic.listStatusAtSelection = safeCodexStatus(thread.status)
            codexSendDiagnostic = diagnostic
        }
        codexStarting = true; sending = true; codexActivity = "checking Codex…"
        codexQueuedEvents = []; codexQueuedRequests = []; codexFinalText = ""; codexFileChangePreviews = [:]
        updateDestinationDisplay()
        markCodexDiagnostic(stage: "account before resume", method: "account/read",
                            summary: "Checking account context")
        verifyCodexAccount(client, thread) { [weak self, weak client] account in
            guard let self, let client, self.codexIsSelected(client, thread) else { return }
            if case .failure(let error) = account {
                self.codexStartFailed(error.localizedDescription, stage: "account before resume",
                                      method: "account/read", error: error); return
            }
            self.markCodexDiagnostic(stage: "thread before resume", method: "thread/read",
                                     summary: "Checking selected thread metadata and status")
            self.verifyCodexThread(client, thread, method: "thread/read") { [weak self, weak client] read in
                guard let self, let client, self.codexIsSelected(client, thread) else { return }
                if case .failure(let error) = read {
                    self.codexStartFailed(error.localizedDescription, stage: "thread before resume",
                                          method: "thread/read", error: error); return
                }
                self.markCodexDiagnostic(stage: "resume selected thread", method: "thread/resume",
                                         summary: "Resuming the explicitly selected thread")
                self.verifyCodexThread(client, thread, method: "thread/resume") { [weak self, weak client] resumed in
                    guard let self, let client, self.codexIsSelected(client, thread) else { return }
                    if case .failure(let error) = resumed {
                        let activeWork = (error as? CodexHistoryClient.Failure)?.activeWorkCategory
                        let message = activeWork == nil ? error.localizedDescription :
                            "Codex reports active work or another writer; draft kept"
                        self.codexStartFailed(message, stage: "resume selected thread",
                                              method: "thread/resume", error: error)
                        if let activeWork { self.inspectBlockedCodexResume(client, thread, category: activeWork) }
                        return
                    }
                    self.markCodexDiagnostic(stage: "account after resume", method: "account/read",
                                             summary: "Rechecking account context")
                    self.verifyCodexAccount(client, thread) { [weak self, weak client] accountAgain in
                        guard let self, let client, self.codexIsSelected(client, thread) else { return }
                        if case .failure(let error) = accountAgain {
                            self.codexStartFailed(error.localizedDescription, stage: "account after resume",
                                                  method: "account/read", error: error); return
                        }
                        self.markCodexDiagnostic(stage: "thread after resume", method: "thread/read",
                                                 summary: "Rechecking selected thread metadata and status")
                        self.verifyCodexThread(client, thread, method: "thread/read") { [weak self, weak client] ready in
                            guard let self, let client, self.codexIsSelected(client, thread) else { return }
                            if case .failure(let error) = ready {
                                self.codexStartFailed(error.localizedDescription, stage: "thread after resume",
                                                      method: "thread/read", error: error); return
                            }
                            self.startCodexTurn(client, thread, text: text)
                        }
                    }
                }
            }
        }
    }

    private func startCodexTurn(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread, text: String) {
        guard codexIsSelected(client, thread), codexStarting else { return }
        codexAwaitingTurnAck = true
        markCodexDiagnostic(stage: "turn start", method: "turn/start",
                            summary: "Waiting for turn acknowledgment", attempted: true,
                            delivery: "pending acknowledgment")
        // No cwd, model, sandbox or approval-policy override: retain this thread's settings.
        client.request("turn/start", ["threadId": thread.id, "input": [["type": "text", "text": text]]],
                       timeout: 20) { [weak self, weak client] result in
            guard let self, let client, self.codexIsSelected(client, thread) else { return }
            switch result {
            case .failure(let error):
                let rejected = (error as? CodexHistoryClient.Failure).map { failure in
                    if case .rejected = failure { return true }
                    return false
                } ?? false
                self.codexStartFailed("Send \(rejected ? "rejected" : "status uncertain"): \(error.localizedDescription). Check Codex before retrying.",
                                      stage: "turn start", method: "turn/start", error: error,
                                      delivery: rejected ? "rejected" : "uncertain")
            case .success(let value):
                guard let turn = value["turn"] as? [String: Any],
                      let id = turn["id"] as? String, !id.isEmpty,
                      let status = turn["status"] as? String,
                      ["inProgress", "completed", "failed", "interrupted"].contains(status) else {
                    self.codexStartFailed("Send acknowledgment was invalid. Check Codex before retrying.",
                                          stage: "turn acknowledgment", method: "turn/start",
                                          error: CodexHistoryClient.Failure.validation("Invalid turn/start response"),
                                          delivery: "uncertain")
                    return
                }
                self.markCodexDiagnostic(stage: "turn acknowledged", method: "turn/start",
                                         summary: "App Server accepted this turn", delivery: "acknowledged")
                self.codexTurnID = id; self.codexStarting = false; self.codexAwaitingTurnAck = false
                self.codexActivity = "Codex working…"
                self.dot.thinking = true
                // A new draft typed while App Server was responding belongs to the next turn.
                if self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    self.field.stringValue = ""
                }
                self.updateDestinationDisplay()
                self.celebrateSend()
                let queued = self.codexQueuedEvents; self.codexQueuedEvents = []
                for (method, params) in queued { self.codexNotification(method, params, client: client) }
                let requests = self.codexQueuedRequests; self.codexQueuedRequests = []
                for (requestID, method, params) in requests {
                    self.codexServerRequest(requestID, method, params, client: client)
                }
                if status != "inProgress" && self.codexTurnID == id {
                    self.finishCodexTurn(status: status, error: nil, thread: thread)
                }
            }
        }
    }

    private func codexStartFailed(_ message: String, stage: String, method: String,
                                  error: Error? = nil, delivery: String = "not sent") {
        failCodexDiagnostic(stage: stage, method: method, error: error,
                            summary: "Send stopped before turn/start", delivery: delivery)
        if let client = historyClient {
            for (id, method, _) in codexQueuedRequests { declineCodexRequest(id, method, client: client) }
        }
        codexStarting = false; codexAwaitingTurnAck = false; sending = false
        codexQueuedEvents = []; codexQueuedRequests = []; codexFileChangePreviews = [:]
        codexActivity = "Codex failed"; dot.thinking = false; dot.worry(); updateDestinationDisplay()
        flash(message, false) // Draft remains in the field.
    }

    private func inspectBlockedCodexResume(_ client: CodexHistoryClient, _ thread: CodexHistoryClient.Thread,
                                           category: String) {
        guard codexIsSelected(client, thread) else { return }
        // Read-only checks on this connection. They do not reveal Codex Desktop's process state.
        client.request("thread/read", ["threadId": thread.id]) { [weak self, weak client] read in
            guard let self, let client, self.codexIsSelected(client, thread) else { return }
            if case .success(let result) = read,
               let value = result["thread"] as? [String: Any],
               value["id"] as? String == thread.id,
               let status = value["status"] as? [String: Any],
               let type = status["type"] as? String {
                self.recordCodexReadStatus(type, afterRejection: true)
            } else if var diagnostic = self.codexSendDiagnostic {
                diagnostic.readStatusAfterRejection = "unavailable"
                self.codexSendDiagnostic = diagnostic
            }
            client.request("thread/loaded/list", [:]) { [weak self, weak client] loaded in
                guard let self, let client, self.codexIsSelected(client, thread) else { return }
                if var diagnostic = self.codexSendDiagnostic {
                    if case .success(let result) = loaded, let ids = result["data"] as? [String] {
                        diagnostic.loadedInKatescapeServer = ids.contains(thread.id) ? "yes" :
                            (result["nextCursor"] as? String == nil ? "no" : "not in first page")
                    } else { diagnostic.loadedInKatescapeServer = "unavailable" }
                    self.codexSendDiagnostic = diagnostic
                }
                self.showBlockedCodexResume(thread, category: category)
            }
        }
    }

    private func showBlockedCodexResume(_ thread: CodexHistoryClient.Thread, category: String) {
        guard selectedCodexThread?.id == thread.id, provider == .codex, codexRoute == .desktop else { return }
        let alert = NSAlert()
        alert.messageText = "Codex cannot resume this conversation now"
        let writerConflict = category.contains("writer") || category.contains("rollout path")
        alert.informativeText = writerConflict
            ? "Another Codex process holds this conversation's writer. An idle status in Eden's separate App Server does not release that ownership. Eden did not send the draft. Continue in Codex; Eden will not retry automatically."
            : "App Server reports active work or another owner. Eden did not send the draft. Its status checks cannot establish whether Codex Desktop owns a running turn. Continue in Codex; Eden will not retry automatically."
        alert.addButton(withTitle: "Open in Codex")
        alert.addButton(withTitle: "Keep draft")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            guard thread.local, let url = URL(string: "codex://threads/\(thread.id)"),
                  NSWorkspace.shared.open(url) else {
                flash("Could not open Codex; draft kept", false); return
            }
        }
    }

    private func codexNotification(_ method: String, _ params: [String: Any], client: CodexHistoryClient) {
        guard let thread = selectedCodexThread, codexIsSelected(client, thread),
              params["threadId"] as? String == thread.id else { return }
        if codexAwaitingTurnAck && codexTurnID == nil {
            if codexQueuedEvents.count < 100 { codexQueuedEvents.append((method, params)) }
            return
        }
        if method == "thread/status/changed", codexTurnID != nil,
           let status = params["status"] as? [String: Any],
           status["type"] as? String == "active",
           let flags = status["activeFlags"] as? [String], flags.contains("waitingOnApproval") {
            codexActivity = "Codex needs approval…"; updateDestinationDisplay()
            return
        }
        guard let activeID = codexTurnID else { return }
        if method == "item/started", params["turnId"] as? String == activeID,
           let item = params["item"] as? [String: Any], item["type"] as? String == "fileChange",
           let itemID = item["id"] as? String,
           let changes = item["changes"] as? [[String: Any]] {
            let preview = changes.map { change in
                "\(change["path"] as? String ?? "Unknown file")\n\(change["diff"] as? String ?? "Diff unavailable")"
            }.joined(separator: "\n\n")
            if !preview.isEmpty && preview.count <= 6_000 { codexFileChangePreviews[itemID] = preview }
        } else if method == "item/completed", params["turnId"] as? String == activeID,
           let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage",
           let text = item["text"] as? String, !text.isEmpty,
           (item["phase"] as? String == "final_answer" || item["phase"] == nil) {
            codexFinalText = String(text.prefix(20_000))
        } else if method == "turn/completed",
                  let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == activeID,
                  let status = turn["status"] as? String {
            if codexFinalText.isEmpty, let items = turn["items"] as? [[String: Any]] {
                let messages = items.filter { $0["type"] as? String == "agentMessage" &&
                    ($0["phase"] as? String == "final_answer" || $0["phase"] == nil) }
                if let text = messages.last?["text"] as? String {
                    codexFinalText = String(text.prefix(20_000))
                }
            }
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            finishCodexTurn(status: status, error: error, thread: thread)
        }
    }

    private func finishCodexTurn(status: String, error: String?, thread: CodexHistoryClient.Thread) {
        guard provider == .codex, codexRoute == .desktop,
              selectedCodexThread?.id == thread.id, codexTurnID != nil else { return }
        codexTurnID = nil; sending = false; dot.thinking = false
        if status == "completed" {
            markCodexDiagnostic(stage: "turn completed", method: "turn/completed",
                                summary: "App Server reported completed", delivery: "completed")
            codexActivity = "Codex completed"
            updateDestinationDisplay()
            if !codexFinalText.isEmpty {
                showBubble(codexFinalText, project: thread.title, react: false)
            } else { flash("Codex completed; view reply in Codex") }
        } else {
            markCodexDiagnostic(stage: "turn completed", method: "turn/completed",
                                summary: status == "failed" ? "App Server reported failed" : "App Server reported interrupted",
                                delivery: "acknowledged; \(status)")
            codexActivity = status == "failed" ? "Codex failed" : "Codex interrupted"
            updateDestinationDisplay()
            flash(String((error ?? codexActivity).prefix(180)), false)
        }
        codexFinalText = ""; codexFileChangePreviews = [:]
    }

    private func codexDisconnected(_ reason: CodexHistoryClient.Failure) {
        guard provider == .codex, codexRoute == .desktop else { return }
        codexTransportFailed(reason)
        historyClient = nil; codexStarting = false; codexAwaitingTurnAck = false; codexTurnID = nil
        codexQueuedEvents = []; codexQueuedRequests = []; codexFileChangePreviews = [:]; sending = false
        dot.thinking = false; dot.worry()
        codexActivity = "Codex disconnected"
        updateDestinationDisplay()
        flash("Codex disconnected; check Codex before retrying", false)
    }

    private func declineCodexRequest(_ id: Any, _ method: String, client: CodexHistoryClient) {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            client.respond(to: id, result: ["decision": "decline"])
        case "item/permissions/requestApproval":
            client.respond(to: id, result: ["permissions": [:], "scope": "turn"])
        default: client.reject(to: id, message: "Eden does not support this interactive request")
        }
    }

    private func codexServerRequest(_ id: Any, _ method: String, _ params: [String: Any],
                                    client: CodexHistoryClient) {
        guard let thread = selectedCodexThread, codexIsSelected(client, thread),
              params["threadId"] as? String == thread.id else {
            client.reject(to: id, message: "No matching selected Codex thread"); return
        }
        if codexAwaitingTurnAck && codexTurnID == nil {
            if codexQueuedRequests.count < 10 { codexQueuedRequests.append((id, method, params)) }
            else { declineCodexRequest(id, method, client: client) }
            return
        }
        guard let activeID = codexTurnID, params["turnId"] as? String == activeID else {
            declineCodexRequest(id, method, client: client); return
        }
        let alert = NSAlert()
        alert.messageText = "Codex requests approval"
        let reason = (params["reason"] as? String) ?? ""
        codexActivity = "Codex needs approval…"; updateDestinationDisplay()
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"] as? String
            let cwd = (params["cwd"] as? String) ?? thread.cwd
            let canApprove: Bool
            if let network = params["networkApprovalContext"] as? [String: Any],
               let host = network["host"] as? String,
               let scheme = network["protocol"] as? String {
                alert.informativeText = "Thread: \(thread.title)\nNetwork access: \(scheme)://\(host)\n\(String(reason.prefix(500)))"
                alert.addButton(withTitle: "Approve once")
                canApprove = true
            } else if let command, !command.isEmpty, command.count <= 1_500 {
                alert.informativeText = "Thread: \(thread.title)\nDirectory: \(cwd)\nCommand: \(String(command.prefix(1_500)))\n\(String(reason.prefix(500)))"
                alert.addButton(withTitle: "Approve once")
                canApprove = true
            } else {
                alert.informativeText = "Codex did not provide enough command details to review. This request can only be declined here."
                canApprove = false
            }
            alert.addButton(withTitle: "Decline")
            NSApp.activate(ignoringOtherApps: true)
            let choice = alert.runModal()
            let approved = canApprove && choice == .alertFirstButtonReturn &&
                codexIsSelected(client, thread) && codexTurnID == activeID
            client.respond(to: id, result: ["decision": approved ? "accept" : "decline"])
        case "item/fileChange/requestApproval":
            let root = (params["grantRoot"] as? String) ?? thread.cwd
            let preview = (params["itemId"] as? String).flatMap { codexFileChangePreviews.removeValue(forKey: $0) }
            alert.informativeText = "Thread: \(thread.title)\nRequested file root: \(root)\n\(String(reason.prefix(500)))"
            if let preview {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 280))
                scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
                let view = NSTextView(frame: scroll.bounds)
                view.string = preview; view.isEditable = false; view.isSelectable = true
                view.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                scroll.documentView = view; alert.accessoryView = scroll
                alert.addButton(withTitle: "Approve once")
            } else { alert.informativeText += "\nNo complete change preview is available here; decline and review in Codex." }
            alert.addButton(withTitle: "Decline")
            NSApp.activate(ignoringOtherApps: true)
            let choice = alert.runModal()
            let approved = preview != nil && choice == .alertFirstButtonReturn &&
                codexIsSelected(client, thread) && codexTurnID == activeID
            client.respond(to: id, result: ["decision": approved ? "accept" : "decline"])
        case "item/permissions/requestApproval":
            guard let requested = params["permissions"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: requested, options: [.prettyPrinted]),
                  data.count < 2_500, let details = String(data: data, encoding: .utf8) else {
                declineCodexRequest(id, method, client: client)
                flash("Codex permission request too large to review; denied", false)
                return
            }
            alert.informativeText = "Thread: \(thread.title)\nRequested access:\n\(details)\n\(String(reason.prefix(500)))"
            alert.addButton(withTitle: "Grant once")
            alert.addButton(withTitle: "Deny")
            NSApp.activate(ignoringOtherApps: true)
            let approved = alert.runModal() == .alertFirstButtonReturn &&
                codexIsSelected(client, thread) && codexTurnID == activeID
            client.respond(to: id, result: ["permissions": approved ? requested : [:], "scope": "turn"])
        default:
            client.reject(to: id, message: "Eden cannot handle \(method); open Codex")
            flash("Codex needs an unsupported interaction; open Codex", false)
        }
        if codexTurnID == activeID, codexIsSelected(client, thread) {
            codexActivity = "Codex working…"; updateDestinationDisplay()
        }
    }

    func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !launcherInProgress else { return }
        if let destination = GuidedMessageIntentParser().parse(text) {
            let previousDraft = guidedMessage.draft
            guidedMessage.start(destination)
            field.stringValue = previousDraft ?? ""
            resetPlaceholder("Your message for \(destination.name)…")
            showBubble(previousDraft == nil ? "What would you like to say?" :
                "Switched to \(destination.name). Your draft is ready to edit or review.",
                project: destination.name, react: false)
            return
        }
        if guidedMessage.isActive {
            if text.lowercased() == "cancel" || text.lowercased() == "never mind" {
                cancelGuidedMessage()
                showBubble("Okay, message cancelled.", project: "Eden", react: false)
                return
            }
            guard guidedMessage.capture(field.stringValue) else { return }
            confirmGuidedMessage()
            return
        }
        switch LauncherCommandParser().parse(text) {
        case .message: break
        case .browseCodexThreads:
            showBubble("Looking for your Codex conversations…", project: "apps", react: false)
            browseCodexThreads()
            return
        case .open(let names):
            openLauncherApps(names, draft: text)
            return
        case .invalidAppReference:
            dot.worry()
            showBubble("Use an installed app name, not a path or link. Your message is still here.",
                       project: "apps", react: false)
            return
        }
        if answeringOther && provider == .claude { answer(nil, other: text); return }
        if handleTodo(text) { return }
        showBubble("I can open installed apps and show your Codex conversations. For CLI messages, use Advanced → Send Draft to Terminal.",
                   project: "Eden", react: false)
    }

    private func cancelGuidedMessage() {
        guidedMessage.cancel()
        field.stringValue = ""
        resetPlaceholder()
    }

    private func confirmGuidedMessage() {
        guard case .confirming(let destination, let draft) = guidedMessage.state else { return }
        let alert = NSAlert()
        alert.messageText = "Message \(destination.name)"
        let preview = draft.count > 280 ? String(draft.prefix(280)) + "…" : draft
        alert.informativeText = "Copy this message and open \(destination.name)? Choose a conversation, then paste and send it yourself.\n\n\(preview)"
        alert.addButton(withTitle: "Continue — Copy & Open")
        alert.addButton(withTitle: "Edit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: copyAndOpenGuidedMessage(destination, draft: draft)
        case .alertSecondButtonReturn:
            guidedMessage.edit()
            field.stringValue = draft
            showBubble("Edit your draft, then press Return to review it.", project: destination.name, react: false)
            panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field)
        default:
            cancelGuidedMessage()
            showBubble("Okay, message cancelled.", project: "Eden", react: false)
        }
    }

    private func copyAndOpenGuidedMessage(_ destination: GuidedMessageDestination, draft: String) {
        let pasteboard = NSPasteboard.general
        let previousItems = clipboardItems(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(draft, forType: .string) else {
            restoreClipboard(pasteboard, items: previousItems, ifUnchanged: pasteboard.changeCount)
            showBubble("Clipboard unavailable. Your draft is still here.", project: destination.name, react: false)
            return
        }
        sending = true
        let finish: (Bool, String) -> Void = { [weak self] opened, place in
            guard let self else { return }
            self.sending = false
            if opened {
                self.guidedMessage.cancel()
                self.field.stringValue = ""
                self.resetPlaceholder()
                self.setOpen(false)
                self.showBubble("Copied. \(place) Choose your conversation, then paste and send.",
                                project: destination.name, react: false)
            } else {
                self.field.stringValue = draft
                self.showBubble("I couldn't open \(destination.name) or its website. Your draft is still here.",
                                project: destination.name, react: false)
            }
        }
        let openWebsite: () -> Void = {
            let opened = NSWorkspace.shared.open(destination.website)
            finish(opened, opened ? "Opened \(destination.name) in your browser." : "")
        }
        guard let app = GuidedMessageAppResolver.verifiedApp(
            for: destination, at: NSWorkspace.shared.urlForApplication(withBundleIdentifier: destination.bundleID)) else {
            openWebsite(); return
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier == destination.bundleID &&
                $0.bundleURL.map { LauncherAppDiscovery.sameLocation($0, app.url) } == true
        }) {
            if running.activate(options: [.activateAllWindows]) { finish(true, "Opened \(destination.name).") }
            else { openWebsite() }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { launched, error in
            DispatchQueue.main.async {
                let verified = error == nil && launched?.bundleIdentifier == destination.bundleID &&
                    launched?.bundleURL.map { LauncherAppDiscovery.sameLocation($0, app.url) } == true
                if verified { finish(true, "Opened \(destination.name).") }
                else { openWebsite() }
            }
        }
    }

    // CLI messaging requires an explicit Advanced menu action. Return in the
    // universal field never falls through to provider sending.
    @objc private func sendAdvancedMessage() {
        guard !guidedMessage.isActive else {
            showBubble("Finish or cancel your guided message first. Nothing was sent.",
                       project: "Eden", react: false)
            return
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !launcherInProgress else {
            if text.isEmpty { showBubble("Type a message first, then choose Advanced → Send Draft to Terminal.", project: "Eden", react: false) }
            return
        }
        guard provider != .codex || codexRoute == .terminal else {
            showBubble("Choose Codex CLI in Terminal under Advanced before sending. Your draft is still here.",
                       project: "Eden", react: false)
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Send to \(provider.adapter.name) in Terminal?"
        confirmation.informativeText = "Eden will use an existing verified Terminal session. Your draft stays if you cancel."
        confirmation.addButton(withTitle: "Continue")
        confirmation.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        guard AXIsProcessTrusted() else {
            let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
            showBubble("Allow Accessibility for Eden, then retry Advanced sending. Your draft is still here.",
                       project: "Eden", react: false)
            return
        }
        sendToSelectedTerminal(text)
    }

    private func sendToSelectedTerminal(_ text: String) {
        sending = true
        let selected = provider
        let adapter = selected.adapter
        // A GUI app may have a smaller PATH than Terminal. An existing session is still usable
        // when the executable is not visible from Mochi's PATH.
        let live = providerTTYs(selected)
        let tabs = terminalTTYs()
        guard let availableTabs = tabs else { sendFailure("Cannot inspect Terminal tabs. Allow Automation for Eden."); return }
        let candidates = live.intersection(availableTabs)
        if candidates.isEmpty {
            if executablePath(for: adapter) == nil { sendFailure("\(adapter.name) CLI not found"); return }
            sendFailure("No active \(adapter.name) session in Terminal; start one there first"); return
        }
        if selected == .codex {
            guard executablePath(for: adapter) != nil else { sendFailure("Codex CLI executable unavailable to Eden; draft kept"); return }
            guard codexAuthenticated() else { sendFailure("Codex sign-in unavailable; run codex login in Terminal"); return }
        }
        let front = run("""
        if application "Terminal" is not running then return ""
        tell application "Terminal"
            if (count of windows) = 0 then return ""
            return tty of selected tab of front window
        end tell
        """)
        if let e = front.err { failed(e); return }
        let tty: String
        if candidates.contains(front.out) { tty = front.out }
        else if candidates.count == 1 { tty = candidates.first! }
        else {
            guard let choice = chooseSession(candidates.sorted(), provider: adapter.name) else { sending = false; return }
            tty = choice
        }
        guard provider == selected, providerTTYs(selected).contains(tty), terminalTTYs()?.contains(tty) == true else {
            sendFailure("\(adapter.name) session changed; try again"); return
        }
        if let e = focusTTY(tty) { failed(e); return }
        paste(text, to: tty, provider: selected)
    }

    private func openLauncherApps(_ names: [String], draft: String) {
        launcherInProgress = true
        sending = true
        showBubble("Finding installed apps…", project: "apps", react: false)
        // A fresh discovery for every command includes newly installed apps.
        LauncherAppDiscovery.discover(names: names) { [weak self] catalog in
            self?.launchRequestedApps(names, catalog: catalog, draft: draft, index: 0,
                                      results: [], allSucceeded: true)
        }
    }

    private func launchRequestedApps(_ names: [String], catalog: [InstalledApplication], draft: String,
                                     index: Int, results: [String], allSucceeded: Bool) {
        guard index < names.count else {
            sending = false
            launcherInProgress = false
            if allSucceeded && field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == draft {
                field.stringValue = ""
            }
            if !allSucceeded { dot.worry() }
            showBubble(results.joined(separator: "; ") + (allSucceeded ? "." : ". Draft kept."),
                       project: "apps", react: false)
            return
        }
        let name = names[index]
        let resolution = LauncherAppResolver.resolve(name, in: catalog)
        let matches: [InstalledApplication]
        let approximate: Bool
        switch resolution {
        case .missing:
            launchRequestedApps(names, catalog: catalog, draft: draft, index: index + 1,
                                results: results + ["Couldn't find \(name)"], allSucceeded: false)
            return
        case .exact(let apps), .alias(let apps): matches = apps; approximate = false
        case .suggestions(let apps): matches = apps; approximate = true
        }
        let chosen: InstalledApplication?
        if matches.count == 1 && !approximate { chosen = matches[0] }
        else { chosen = chooseLauncherApp(matches, for: name, approximate: approximate) }
        guard let app = chosen else {
            launchRequestedApps(names, catalog: catalog, draft: draft, index: index + 1,
                                results: results + ["Skipped \(name)"], allSucceeded: false)
            return
        }
        launchInstalledApp(app) { [weak self] success, description in
            self?.launchRequestedApps(names, catalog: catalog, draft: draft, index: index + 1,
                                      results: results + [description], allSucceeded: allSucceeded && success)
        }
    }

    private func chooseLauncherApp(_ apps: [InstalledApplication], for name: String,
                                   approximate: Bool) -> InstalledApplication? {
        let alert = NSAlert()
        alert.messageText = approximate ? "Choose an app for \(name)" : "Several apps match \(name)"
        alert.informativeText = approximate
            ? "No exact app matched. Choose explicitly; Eden won't guess."
            : "Choose which installed copy to open."
        alert.addButton(withTitle: "Open selected")
        alert.addButton(withTitle: "Skip")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28), pullsDown: false)
        picker.addItems(withTitles: apps.map { "\($0.displayName) · \($0.url.path)" })
        for (index, app) in apps.enumerated() { picker.item(at: index)?.toolTip = "\(app.bundleID)\n\(app.url.path)" }
        alert.accessoryView = picker
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              apps.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return apps[picker.indexOfSelectedItem]
    }

    private func launchInstalledApp(_ app: InstalledApplication,
                                    completion: @escaping (Bool, String) -> Void) {
        guard let current = InstalledApplication(url: app.url), current.bundleID == app.bundleID else {
            completion(false, "\(app.displayName) changed or is no longer available")
            return
        }
        let running = NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleIdentifier == app.bundleID &&
                $0.bundleURL.map { LauncherAppDiscovery.sameLocation($0, app.url) } == true
        }
        if let running {
            let activated = running.activate(options: [.activateAllWindows])
            completion(activated, activated ? "Switched to \(app.displayName)" : "Couldn't switch to \(app.displayName)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { launched, error in
            DispatchQueue.main.async {
                let verified = error == nil && launched?.bundleIdentifier == app.bundleID &&
                    launched?.bundleURL.map { LauncherAppDiscovery.sameLocation($0, app.url) } == true
                completion(verified, verified ? "Opened \(app.displayName)" : "Couldn't verify opening \(app.displayName)")
            }
        }
    }

    func chooseSession(_ ttys: [String], provider name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Choose a \(name) Terminal session"
        alert.informativeText = "Several sessions are running. Run tty in a tab if you need to identify it. Your draft stays in Eden if you cancel."
        alert.addButton(withTitle: "Send to selected session")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        picker.addItems(withTitles: ttys)
        alert.accessoryView = picker
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? picker.titleOfSelectedItem : nil
    }

    // bring the Terminal tab on a given tty to the front
    @discardableResult func focusTTY(_ tty: String) -> NSDictionary? {
        guard !tty.isEmpty else { return nil }
        return run("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                    end if
                end repeat
            end repeat
        end tell
        """).err
    }

    func resetPlaceholder(_ s: String = "Ask Eden to do something…") {
        field.placeholderAttributedString = NSAttributedString(string: s, attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.62), .font: NSFont.systemFont(ofSize: 14)])
    }

    // MARK: to-do list

    // "todo: buy matcha", "mochi add buy matcha to my to-do list", "what's on my list", "done matcha" (or "done 2")
    func handleTodo(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^(?i)(hey|hi|ok|okay)[,!]?\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)(?:eden|mochi)[,!:]?\s+"#, with: "", options: .regularExpression)
        let T = #"(?:to-?\s?do|todo)"#
        func grab(_ pat: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
                  let x = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), x.numberOfRanges > 1, let g = Range(x.range(at: 1), in: s) else { return nil }
            let v = String(s[g]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'.!")))
            return v.isEmpty ? nil : v
        }
        func matches(_ pat: String) -> Bool { s.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil }
        let done = { self.field.stringValue = ""; self.setOpen(false); self.panel.resignKey(); self.lastApp?.activate() }

        if let item = grab("^" + T + #"\s*[:\-–]\s*(.+)$"#)
            ?? grab(#"^(?:please\s+|can you\s+)*add\s+(.+?)\s+to\s+(?:my\s+|the\s+)?"# + T + #"(?:\s+list)?[.!?]*$"#)
            ?? grab(#"^(?:put|stick|write)\s+(.+?)\s+on\s+(?:my\s+|the\s+)?"# + T + #"(?:\s+list)?[.!?]*$"#) {
            todos.append(Todo(id: UUID().uuidString, text: String(item.prefix(200)), added: Date().timeIntervalSince1970, done: nil))
            saveTodosNow()
            done(); dot.hop(); dot.sparkT = dot.t
            showBubble("added ✓  " + item, project: "to-do", react: false)
            return true
        }
        if matches(#"^(?:what'?s|whats|show(?: me)?|open|see)\s+(?:on\s+)?(?:my\s+|the\s+)?(?:"# + T + #"\s*)?list\??$"#)
            || matches(#"^what'?s\s+on\s+my\s+"# + T + #"(?:\s+list)?\??$"#) || matches("^(?:my\\s+)?" + T + #"(?:\s+list)?\??$"#) {
            done(); showTodoList(); return true
        }
        if let what = grab(#"^(?:done|check off|cross off|finished|completed?)\s*[:\-]?\s+(.+)$"#) {
            let openList = todos.enumerated().filter { $0.element.done == nil }
            let hit = Int(what).flatMap { n in n >= 1 && n <= openList.count ? openList[n - 1].offset : nil }
                ?? openList.first { $0.element.text.lowercased().contains(what.lowercased()) }?.offset
            guard let i = hit else { return false }   // not on the list: send it to the selected provider
            todos[i].done = Date().timeIntervalSince1970; saveTodosNow()
            done(); dot.proud()
            showBubble("checked off ✓  " + todos[i].text, project: "to-do", react: false)
            return true
        }
        return false
    }

    func saveTodosNow() {
        saveTodos(todos)
        todoMTime = (try? FileManager.default.attributesOfItem(atPath: todoFile.path))?[.modificationDate] as? Date
        todosChanged()
    }
    func reloadTodos(announce: Bool) {
        let fresh = loadTodos(), had = Set(todos.map(\.id))
        todoMTime = (try? FileManager.default.attributesOfItem(atPath: todoFile.path))?[.modificationDate] as? Date
        if announce, let a = fresh.first(where: { !had.contains($0.id) && $0.done == nil }) {
            showBubble("added to your to-do list: " + a.text, project: "to-do", react: false); dot.hop()
        }
        todos = fresh; todosChanged()
    }
    func todosChanged() {
        todoBadge.n = todos.filter { $0.done == nil }.count
        if !open { fitCollapsed() }; lay()
        if todoPanel?.isVisible == true { showTodoList() }
    }

    func toggleTodoList() { if todoPanel?.isVisible == true { hideTodoList() } else { showTodoList() } }

    func showTodoList() {
        note("todo list")
        if todoPanel == nil { let (p, b) = glassPanel(NSSize(width: 300, height: 100)); todoPanel = p; todoBox = b }
        guard let p = todoPanel, let box = todoBox else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        let W: CGFloat = 300, pad: CGFloat = 14, iw = W - 2 - pad * 2
        let openN = todos.filter { $0.done == nil }.count
        var views: [NSView] = [label("Eden · to-do" + (openN > 0 ? "   \(openN) open" : ""), size: 10, weight: .medium, color: cyanText, mono: true)]
        let close = Tap(frame: NSRect(x: 0, y: 0, width: 20, height: 18)); close.isBordered = false; close.target = self; close.action = #selector(closeTodoList)
        close.attributedTitle = NSAttributedString(string: "×", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(white: 1, alpha: 0.55)])
        close.toolTip = "Close"
        let list = todos.sorted { ($0.done == nil ? 0 : 1, $0.added) < ($1.done == nil ? 0 : 1, $1.added) }
        if list.isEmpty {
            views.append(label("All clear ✨  Tell Eden “todo: …” to add something.", size: 12, color: NSColor(white: 1, alpha: 0.7), wrap: iw))
            // nothing left (and no badge to click): close on its own in a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in if self?.todos.isEmpty == true { self?.hideTodoList() } }
        }
        for t in list.prefix(14) { views.append(todoRow(t, width: iw)) }
        if list.contains(where: { $0.done != nil }) {
            let c = Tap(frame: .zero); c.isBordered = false; c.target = self; c.action = #selector(clearDone)
            c.attributedTitle = NSAttributedString(string: "clear done", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: cyanText])
            c.sizeToFit(); views.append(c)
        }
        var y = pad
        for v in views.reversed() { v.frame.origin = NSPoint(x: pad, y: y); box.addSubview(v); y += v.frame.height + 8 }
        let size = NSSize(width: W, height: y - 8 + pad)
        close.frame.origin = NSPoint(x: W - 2 - 8 - close.frame.width, y: size.height - 2 - 6 - close.frame.height); box.addSubview(close)
        hideBubble()
        if !p.isVisible || p.alphaValue < 1 { p.alphaValue = 0; placeAbove(p, size); p.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; p.animator().alphaValue = 1 } }
        else { placeAbove(p, size) }
        // close on a click anywhere else: in other apps, and in Mochi's own windows (other than the list)
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.hideTodoList() }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
                if let self, e.window !== self.todoPanel, e.window !== self.panel { self.hideTodoList() }
                return e
            }
        }
    }

    func todoRow(_ t: Todo, width: CGFloat) -> NSView {
        let done = t.done != nil
        let box = Tap(frame: NSRect(x: 0, y: 0, width: 20, height: 20)); box.isBordered = false; box.title = ""
        box.image = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : "circle", accessibilityDescription: done ? "Done" : "Not done")
        box.contentTintColor = done ? hex("#7ad3a3") : NSColor(white: 1, alpha: 0.7)
        box.identifier = NSUserInterfaceItemIdentifier(t.id); box.target = self; box.action = #selector(toggleTodo(_:))
        let del = Tap(frame: NSRect(x: 0, y: 0, width: 16, height: 20)); del.isBordered = false
        del.attributedTitle = NSAttributedString(string: "×", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 1, alpha: 0.35)])
        del.identifier = NSUserInterfaceItemIdentifier(t.id); del.target = self; del.action = #selector(deleteTodo(_:)); del.toolTip = "Remove"
        let age = label(ago(t.done ?? t.added), size: 10, color: NSColor(white: 1, alpha: 0.45), mono: true)
        let tw = width - 26 - age.frame.width - 6 - 18
        let tl = label(t.text, size: 13, color: NSColor(white: 1, alpha: done ? 0.45 : 0.92), wrap: tw)
        if done { tl.attributedStringValue = NSAttributedString(string: t.text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 1, alpha: 0.45), .strikethroughStyle: NSUnderlineStyle.single.rawValue]) }
        let h = max(20, tl.frame.height)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        box.frame.origin = NSPoint(x: 0, y: h - 20)
        tl.frame.origin = NSPoint(x: 26, y: h - tl.frame.height - 1)
        age.frame.origin = NSPoint(x: width - 18 - age.frame.width, y: h - 17)
        del.frame.origin = NSPoint(x: width - 16, y: h - 20)
        [box, tl, age, del].forEach(v.addSubview)
        return v
    }

    @objc func toggleTodo(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let i = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[i].done = todos[i].done == nil ? Date().timeIntervalSince1970 : nil
        if todos[i].done != nil { dot.hop(); dot.sparkT = dot.t }
        saveTodosNow()
    }
    @objc func deleteTodo(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        todos.removeAll { $0.id == id }; saveTodosNow()
    }
    @objc func clearDone() { todos.removeAll { $0.done != nil }; saveTodosNow() }

    @objc func closeTodoList() { hideTodoList() }
    func hideTodoList() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        guard let p = todoPanel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    // MARK: questions from Claude

    func showQuestion() {
        note("question")
        guard let j = qData, let qs = j["questions"] as? [[String: Any]], qIndex < qs.count else { hideQuestion(); return }
        let q = qs[qIndex], opts = q["options"] as? [[String: Any]] ?? [], multi = q["multiSelect"] as? Bool ?? false
        if qPanel == nil { let (p, b) = glassPanel(NSSize(width: 360, height: 100)); qPanel = p; qBox = b }
        guard let p = qPanel, let box = qBox else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        let W: CGFloat = 360, pad: CGFloat = 14, iw = W - 2 - pad * 2
        var views: [NSView] = [
            label("Eden · claude is asking" + (qs.count > 1 ? "   \(qIndex + 1) of \(qs.count)" : ""), size: 10, weight: .medium, color: cyanText, mono: true),
            label(q["question"] as? String ?? "", size: 13.5, weight: .semibold, wrap: iw)]
        if multi { views.append(label("This one takes several picks, so answer it in Terminal.", size: 11.5, color: NSColor(white: 1, alpha: 0.6), wrap: iw)) }
        for (i, o) in opts.enumerated() { views.append(option(o["label"] as? String ?? "", o["description"] as? String ?? "", width: iw, tag: i, enabled: !multi)) }
        if !multi { views.append(option("Other…", "Type your own answer in Eden", width: iw, tag: 1000, enabled: true)) }
        let go = Tap(frame: .zero); go.isBordered = false; go.target = self; go.action = #selector(openQuestionTab)
        go.attributedTitle = NSAttributedString(string: "Open in Terminal ↗", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: cyanText])
        go.sizeToFit(); views.append(go)
        var y = pad
        for v in views.reversed() { v.frame.origin = NSPoint(x: pad, y: y); box.addSubview(v); y += v.frame.height + 7 }
        let size = NSSize(width: W, height: y - 7 + pad)
        hideBubble()
        if !p.isVisible { p.alphaValue = 0; placeAbove(p, size); p.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.25; p.animator().alphaValue = 1 } }
        else { placeAbove(p, size) }
        repositionPanels()
        dot.asking = true; dot.hop(); dot.lookTo = 0; dot.lookY = 1
    }

    func option(_ title: String, _ desc: String, width: CGFloat, tag: Int, enabled: Bool) -> NSView {
        let tl = label(title, size: 13, weight: .semibold, wrap: width - 20)
        let dl = desc.isEmpty ? nil : label(desc, size: 11.5, color: NSColor(white: 1, alpha: 0.62), wrap: width - 20)
        let h = 8 + tl.frame.height + (dl.map { 2 + $0.frame.height } ?? 0) + 8
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h)); v.wantsLayer = true
        v.layer?.cornerRadius = 10; v.layer?.backgroundColor = NSColor(white: 1, alpha: enabled ? 0.09 : 0.04).cgColor
        v.layer?.borderWidth = 1; v.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        var y: CGFloat = 8
        if let d = dl { d.frame.origin = NSPoint(x: 10, y: y); v.addSubview(d); y += d.frame.height + 2 }
        tl.frame.origin = NSPoint(x: 10, y: y); v.addSubview(tl)
        if enabled {
            let b = Tap(frame: v.bounds); b.title = ""; b.isBordered = false; b.isTransparent = true
            b.tag = tag; b.target = self; b.action = #selector(pickOption(_:)); v.addSubview(b)
        }
        return v
    }

    @objc func pickOption(_ b: NSButton) {
        if b.tag == 1000 { answeringOther = true; resetPlaceholder("Your answer for Claude…"); setOpen(true); return }
        answer(b.tag)
    }

    @objc func openQuestionTab() {
        guard provider == .claude, let tty = qData?["tty"] as? String,
              providerTTYs(.claude).contains(tty), terminalTTYs()?.contains(tty) == true else {
            sendFailure("Claude session unavailable; question left open"); return
        }
        if let e = focusTTY(tty) { failed(e); return }
        _ = run("tell application \"Terminal\" to activate")
    }

    // answer in Claude's Terminal tab: arrow down to the option and press Return ("Other" sits after the options, then the typed answer)
    func answer(_ i: Int?, other: String? = nil) {
        guard provider == .claude, let j = qData, let tty = j["tty"] as? String,
              providerTTYs(.claude).contains(tty), terminalTTYs()?.contains(tty) == true,
              let qs = j["questions"] as? [[String: Any]], qIndex < qs.count else {
            sendFailure("Claude question session unavailable; answer kept"); return
        }
        let n = (qs[qIndex]["options"] as? [[String: Any]])?.count ?? 0
        let back = lastApp
        if let e = focusTTY(tty) { failed(e); return }
        let pb = NSPasteboard.general, saved = other == nil ? [] : clipboardItems(pb)
        if let o = other {
            pb.clearContents()
            guard pb.setString(o, forType: .string) else {
                restoreClipboard(pb, items: saved, ifUnchanged: pb.changeCount)
                sendFailure("Clipboard unavailable; answer kept"); return
            }
        }
        let mine = pb.changeCount
        // Claude's question menu is numbered: typing the option's number picks it ("Other" is the number after the options)
        var sc = "tell application \"Terminal\" to activate\ndelay 0.2\ntell application \"Terminal\"\nif (tty of selected tab of front window) is not \"\(tty)\" then error \"Terminal tab changed\" number -10000\nend tell\ntell application \"System Events\"\nif not (frontmost of process \"Terminal\") then error \"Terminal is not frontmost\" number -10000\n"
        sc += "keystroke \"\((i ?? n) + 1)\"\n"
        if other != nil { sc += "delay 0.35\nkeystroke \"v\" using command down\ndelay 0.25\nkey code 36\n" }
        sc += "end tell"
        let r = run(sc)
        if let e = r.err {
            if other != nil { restoreClipboard(pb, items: saved, ifUnchanged: mine) }
            failed(e); return
        }
        if other != nil { answeringOther = false; resetPlaceholder(); field.stringValue = ""; setOpen(false) }
        let t0 = Date()
        qIndex += 1
        if qIndex < qs.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showQuestion() }
        } else {
            if qs.count > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { _ = self.run("tell application \"System Events\" to key code 36") } }   // the "submit answers" step
            hideQuestion(); flash("answered ✓"); dot.proud()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if other != nil { self.restoreClipboard(pb, items: saved, ifUnchanged: mine) }
            self.handBack(back, since: t0)
        }
    }

    func showStep(_ t: String) {
        if t.isEmpty { if let p = nowPanel, p.isVisible { NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { [weak self] in p.orderOut(nil); self?.repositionPanels() }) }; return }
        if nowPanel == nil {
            let (p, box) = glassPanel(NSSize(width: 200, height: 24), radius: 12)
            let l = NSTextField(labelWithString: ""); l.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium); l.textColor = NSColor(white: 1, alpha: 0.82)
            l.lineBreakMode = .byTruncatingTail; box.addSubview(l); nowPanel = p; nowLabel = l
        }
        guard let p = nowPanel, let l = nowLabel else { return }
        l.attributedStringValue = NSAttributedString(string: "› " + t, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.82)])
        l.sizeToFit()
        let w = min(420, l.frame.width + 24)
        l.frame = NSRect(x: 11, y: (24 - 2 - l.frame.height) / 2, width: w - 24, height: l.frame.height)
        let fresh = !p.isVisible || p.alphaValue < 1
        placeAbove(p, NSSize(width: w, height: 24))
        if fresh { p.alphaValue = 0; p.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; p.animator().alphaValue = 1 } }
        repositionPanels()
    }

    // go back to the app you were in, unless you've typed or clicked since (then you've moved on, so Mochi leaves you be)
    func handBack(_ app: NSRunningApplication?, since t0: Date) {
        note("handBack \(app?.localizedName ?? "-")")
        guard let b = app, b.bundleIdentifier != "com.apple.Terminal",
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" else { return }   // you already went somewhere yourself
        let elapsed = Date().timeIntervalSince(t0)
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        if key < elapsed - 0.85 || click < elapsed { return }   // Mochi's own last keys land in the first moments
        b.activate()
    }

    func hideQuestion() {
        dot.asking = false
        guard let p = qPanel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { [weak self] in p.orderOut(nil); self?.repositionPanels() })
    }

    // Only foreground CLI jobs are valid destinations; a stopped/background process
    // sharing the TTY must not make a different prompt look safe.
    func providerTTYs(_ id: ProviderID) -> Set<String> {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "tty=,stat=,command="]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        var ttys = Set<String>()
        for line in out.split(separator: "\n") {
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3, parts[0].hasPrefix("ttys"), parts[1].contains("+") else { continue }
            let cmd = parts[2].trimmingCharacters(in: .whitespaces)
            if id.adapter.matchesProcess(cmd) { ttys.insert("/dev/" + parts[0]) }
        }
        return ttys
    }

    func terminalTTYs() -> Set<String>? {
        let r = run("""
        if application "Terminal" is not running then return ""
        set outText to ""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    set outText to outText & (tty of t) & linefeed
                end repeat
            end repeat
        end tell
        return outText
        """)
        guard r.err == nil else { return nil }
        return Set(r.out.split(separator: "\n").map(String.init))
    }

    func executablePath(for adapter: ProviderAdapter) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            + [home + "/.local/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        var candidates = directories.map { ($0 as NSString).appendingPathComponent(adapter.executable) }
        if adapter.executable == "codex" {
            // Finder-launched apps often lack Terminal's PATH. ChatGPT Desktop ships a CLI
            // that supports standalone commands, including login status and app-server.
            let relative = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            candidates += ["/Applications/ChatGPT.app/" + relative,
                           home + "/Applications/ChatGPT.app/" + relative]
        }
        for candidate in candidates {
            let path = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard path.hasPrefix("/"),
                  let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType,
                  type == .typeRegular,
                  FileManager.default.isExecutableFile(atPath: path) else { continue }
            return path
        }
        return nil
    }

    func codexAuthenticated() -> Bool {
        guard let path = executablePath(for: CodexProvider()) else { return false }
        let p = Process(), signal = DispatchSemaphore(value: 0)
        p.executableURL = URL(fileURLWithPath: path); p.arguments = ["login", "status"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        p.terminationHandler = { _ in signal.signal() }
        guard (try? p.run()) != nil else { return false }
        if signal.wait(timeout: .now() + 3) == .timedOut { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    func run(_ source: String) -> (out: String, err: NSDictionary?) {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return (r?.stringValue ?? "", err)
    }

    func sendFailure(_ message: String) {
        sending = false; field.isEditable = true; dot.worry(); flash(message, false)
    }

    func clipboardItems(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    func restoreClipboard(_ pb: NSPasteboard, items: [NSPasteboardItem], ifUnchanged count: Int) {
        guard pb.changeCount == count else { return }
        pb.clearContents()
        if !items.isEmpty { _ = pb.writeObjects(items) }
    }

    // Paste only into the verified tab. Keep the draft until AppleScript reports success.
    func paste(_ text: String, to tty: String, provider id: ProviderID) {
        note("paste")
        guard provider == id, providerTTYs(id).contains(tty), terminalTTYs()?.contains(tty) == true else {
            sendFailure("\(id.adapter.name) session changed; draft kept"); return
        }
        let back = lastApp
        let pb = NSPasteboard.general
        let saved = clipboardItems(pb)
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            restoreClipboard(pb, items: saved, ifUnchanged: pb.changeCount)
            sendFailure("Clipboard unavailable; draft kept"); return
        }
        let mine = pb.changeCount
        let r = run("""
        tell application "Terminal" to activate
        delay 0.25
        tell application "Terminal"
            if (count of windows) = 0 then error "Terminal session closed" number -10000
            if (tty of selected tab of front window) is not "\(tty)" then error "Terminal tab changed" number -10000
        end tell
        tell application "System Events"
            if not (frontmost of process "Terminal") then error "Terminal is not frontmost" number -10000
            keystroke "v" using command down
            delay 0.25
            key code 36
        end tell
        """)
        if let e = r.err { restoreClipboard(pb, items: saved, ifUnchanged: mine); failed(e); return }
        // Restore the clipboard only if no other app or user has changed it.
        let t0 = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.handBack(back, since: t0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.restoreClipboard(pb, items: saved, ifUnchanged: mine) }
        field.stringValue = ""
        celebrateSend()
    }

    // say which permission is missing, and keep the details in ~/Library/Logs/Mochi.log
    func failed(_ e: NSDictionary) {
        sending = false
        let code = e[NSAppleScript.errorNumber] as? Int ?? 0
        let line = "\(Date()) \(code) \(e[NSAppleScript.errorMessage] ?? "")\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mochi.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        field.isEditable = true; dot.worry()
        flash(code == -1743 ? "allow Terminal Automation; draft kept" :
              (code == -1719 || code == 1002 || code == -25211) ? "allow Accessibility; draft kept" :
              code == -10000 ? "Terminal session changed; draft kept" : "send failed (\(code)); draft kept", false)
    }

    func celebrateSend() {
        flash("sent ✓")
        // a snack for the goo (a little rounder each message, back to normal tomorrow)
        let d = UserDefaults.standard, today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        if d.double(forKey: "fedDay") != today { d.set(today, forKey: "fedDay"); d.set(0, forKey: "fed") }
        d.set(d.integer(forKey: "fed") + 1, forKey: "fed"); dot.fed = d.integer(forKey: "fed")
        // the goo springs up and throws a paper plane across the bar to "→ Terminal", then lands with a splat
        dot.throwIt()
        sending = true
        let from = NSPoint(x: dot.frame.minX + 16, y: dot.frame.midY + 4)
        let to = NSPoint(x: status.frame.minX + 30, y: status.frame.midY - 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.fx.launch(from: from, to: to, color: self.dot.colors.body) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { self.sending = false; self.setOpen(false) }
    }
}

let app = NSApplication.shared
let bar = Bar()
app.delegate = bar
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()

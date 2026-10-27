// Mochi: a little pixel goo that floats at the bottom of your screen and talks to a selected CLI in Terminal.
// Type into her to send a message; Claude Code also supplies replies, questions and progress through its hooks.
// Type, press Return, and the message is sent to a verified Terminal tab for the selected provider,
// then you're put back in the app you were using. Right-click the bar to quit.
import Cocoa
import ServiceManagement

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Field: NSTextField {
    var onSend: ((String) -> Void)?
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
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layer?.cornerRadius = s.height/2 }
}
final class PillGlass: NSVisualEffectView {
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layer?.cornerRadius = s.height/2 }
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

// Read-only Codex history connection. Never sends a turn or resumes a thread.
private final class CodexHistoryClient {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
    }

    struct Thread {
        let id: String, title: String, cwd: String, source: String, status: String
        let local: Bool

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String, let cwd = value["cwd"] as? String,
                  let status = value["status"] as? [String: Any], let state = status["type"] as? String else { return nil }
            self.id = id; self.cwd = cwd; self.status = state
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
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.failAll("Codex App Server exited. Its local state or permissions may be unavailable.") }
        }
        do { try process.run() } catch {
            stop(); done(.failure(Failure.unavailable("Could not start Codex App Server: \(error.localizedDescription)"))); return
        }
        request("initialize", ["clientInfo": ["name": "katescape_history", "title": "Katescape History", "version": "0.1"]]) { [weak self] result in
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
            callback(.failure(Failure.unavailable("Codex App Server timed out during \(method)")))
            self.stop()
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else {
            failAll("Could not encode Codex protocol request"); return
        }
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { failAll("Could not write to Codex App Server") }
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty { failAll("Codex App Server closed its output"); return }
        buffer.append(data)
        guard buffer.count <= 4_000_000 else { failAll("Codex App Server response exceeded the size limit"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failAll("Codex App Server returned malformed JSON"); return
            }
            if value["id"] == nil { continue } // documented notifications
            guard let id = value["id"] as? Int else {
                failAll("Codex App Server returned an invalid response ID"); return
            }
            guard let callback = pending.removeValue(forKey: id) else { continue }
            if let error = value["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown protocol error"
                callback(.failure(Failure.unavailable("Codex App Server: \(String(message.prefix(200)))")))
            } else if let result = value["result"] as? [String: Any] {
                callback(.success(result))
            } else {
                callback(.failure(Failure.unavailable("Codex App Server returned an invalid response")))
            }
        }
    }

    private func failAll(_ message: String) {
        guard !stopped else { return }
        let callbacks = pending.values; pending.removeAll()
        stop()
        for callback in callbacks { callback(.failure(Failure.unavailable(message))) }
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
    var look = 0.0, lookTo = 0.0, lookY = 0, nextLook = 4.0, greetUntil = -10.0
    var lastActive = 0.0, sleepSince: Double? = nil
    var hoverSince: Double? = nil
    var timer: Timer?

    // for testing the outfits: PB_HOUR=8 or PB_WEEKDAY=6 (Friday) in the environment
    let env = ProcessInfo.processInfo.environment

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

        // eyes follow the cursor when it's near, otherwise glance around now and then
        let m = NSEvent.mouseLocation
        var near = false, over = false
        if let w = window {
            let c = w.convertPoint(toScreen: convert(NSPoint(x: bounds.midX - 4, y: bounds.midY), to: nil))
            let dx = m.x - c.x, dy = m.y - c.y
            near = dx * dx + dy * dy < 260 * 260
            if near && t > greetUntil { lookTo = max(-1, min(1, dx / 70)); lookY = dy > 40 ? 1 : dy < -40 ? -1 : 0 }
            over = abs(dx) < 15 && abs(dy) < 14
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

    override func draw(_ r: NSRect) {
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
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

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
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
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

final class Bar: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate, NSGestureRecognizerDelegate, NSMenuDelegate {
    var provider = ProviderID(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .claude
    var pillProviderMenu: NSMenu?
    private var historyClient: CodexHistoryClient?
    private var discoveredThreads: [CodexHistoryClient.Thread] = []
    var panel: Panel!
    var field: Field!
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

    // sizes: a small "Mochi" pill when collapsed, the full bar when open
    let W: CGFloat = 560, H: CGFloat = 48
    let w: CGFloat = 120, h: CGFloat = 34

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
        panel = Panel(contentRect: NSRect(x: scr.midX - w/2, y: scr.minY + 18, width: w, height: h),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        // smoked glass pill: always dark, with a dark outer ring (reads on light screens) and a light inner ring (reads on dark ones)
        ring = Pill(frame: NSRect(x: 0, y: 0, width: w, height: h))
        ring.wantsLayer = true; ring.layer?.cornerRadius = h/2
        ring.layer?.borderWidth = 1; ring.layer?.borderColor = NSColor(white: 0, alpha: 0.45).cgColor
        panel.contentView = ring

        let glass = PillGlass(frame: NSRect(x: 1, y: 1, width: w - 2, height: h - 2))
        glass.autoresizingMask = [.width, .height]
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = (h - 2)/2; glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1; glass.layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        ring.addSubview(glass)

        // tint so the pill stays dark whatever is behind it
        let tint = NSView(frame: glass.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true; tint.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.62).cgColor
        glass.addSubview(tint)

        dot = Goo(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
        glass.addSubview(dot)
        let d = UserDefaults.standard, today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        dot.fed = d.double(forKey: "fedDay") == today ? d.integer(forKey: "fed") : 0
        visitors = Visitors(frame: NSRect(x: 0, y: 0, width: 80, height: 12))
        glass.addSubview(visitors)
        social = Social(frame: NSRect(x: 0, y: 0, width: 60, height: 14))
        glass.addSubview(social)
        todoBadge = TodoBadge(frame: NSRect(x: 0, y: 0, width: 40, height: 14))
        glass.addSubview(todoBadge)
        meter = NSTextField(labelWithString: "")
        meter.font = .monospacedSystemFont(ofSize: 10, weight: .medium); meter.textColor = cyanText
        glass.addSubview(meter)

        // collapsed label
        mini = Wave("Mochi")
        mini.font = .systemFont(ofSize: 13, weight: .medium)
        mini.textColor = NSColor(white: 1, alpha: 0.85)
        glass.addSubview(mini)

        field = Field(frame: NSRect(x: 46, y: (H - 2 - 22)/2, width: W - 46 - 160, height: 22))
        field.placeholderAttributedString = NSAttributedString(string: "Message Mochi…",
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.62), .font: NSFont.systemFont(ofSize: 14)])
        field.font = .systemFont(ofSize: 14); field.textColor = .white
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true; field.cell?.wraps = false
        field.delegate = self
        glass.addSubview(field)

        status = NSTextField(labelWithString: "→ \(provider.adapter.name)")
        status.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        status.textColor = NSColor(white: 1, alpha: 0.6); status.alignment = .right
        status.frame = NSRect(x: W - 2 - 152, y: (H - 2 - 14)/2, width: 132, height: 14)
        glass.addSubview(status)

        // on top of everything: the paper plane
        fx = Fx(frame: glass.bounds); fx.autoresizingMask = [.width, .height]
        glass.addSubview(fx)

        // click the collapsed pill to open it (a drag still moves it)
        ring.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped(_:))))

        let menu = NSMenu()
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = makeProviderMenu()
        providerItem.submenu = providerMenu; pillProviderMenu = providerMenu
        menu.addItem(providerItem)
        let browse = NSMenuItem(title: "Browse Codex Threads…", action: #selector(browseCodexThreads), keyEquivalent: "")
        browse.target = self; menu.addItem(browse)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login); menu.addItem(.separator())
        let paint = NSMenuItem(title: "Change Mochi's Color…", action: #selector(pickColor(_:)), keyEquivalent: "")
        paint.target = self; menu.addItem(paint); menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mochi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // open at login: switched on once, the first time; after that the menu item decides
        if !UserDefaults.standard.bool(forKey: "loginSet") {
            UserDefaults.standard.set(true, forKey: "loginSet")
            do { try SMAppService.mainApp.register(); login.state = .on } catch { NSLog("login item: \(error)") }
        }
        ring.menu = menu; glass.menu = menu

        lay()
        panel.orderFrontRegardless()
        makeStatusItem()

        // ask macOS for Accessibility up front (it adds the bar to the list and shows its own prompt)
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)

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

    // MARK: the menu bar goo

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // a 9×8 pixel goo (a template image, so it follows the menu bar's light or dark look)
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
        statusItem.button?.toolTip = "Mochi"
        let m = NSMenu(); m.delegate = self; statusItem.menu = m
    }

    // the menu is rebuilt each time it opens, so the to-do count and Show/Hide are current
    func menuNeedsUpdate(_ m: NSMenu) {
        guard m === statusItem?.menu else { return }
        m.removeAllItems()
        func item(_ t: String, _ a: Selector) { let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; m.addItem(i) }
        item("Find Mochi", #selector(findMochi))
        item("Message Mochi…", #selector(messageMochi))
        let n = todos.filter { $0.done == nil }.count
        item(n > 0 ? "To-do list (\(n))" : "To-do list", #selector(openTodoFromMenu))
        item(panel.isVisible ? "Hide Mochi" : "Show Mochi", #selector(toggleShown))
        m.addItem(.separator())
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        providerItem.submenu = makeProviderMenu(); m.addItem(providerItem)
        item("Browse Codex Threads…", #selector(browseCodexThreads))
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off; m.addItem(login)
        m.addItem(withTitle: "Quit Mochi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    @objc func selectProvider(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let next = ProviderID(rawValue: raw), next != provider else { return }
        provider = next
        UserDefaults.standard.set(next.rawValue, forKey: "provider")
        pillProviderMenu?.items.forEach { $0.state = ($0.representedObject as? String) == next.rawValue ? .on : .off }
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
        status.stringValue = "→ \(next.adapter.name)"
        if !open { fitCollapsed() }; lay()
    }

    // A separate, consented history surface. It never changes the Terminal destination.
    @objc func browseCodexThreads() {
        if !UserDefaults.standard.bool(forKey: "codexHistoryConsent") {
            let alert = NSAlert()
            alert.messageText = "Browse local Codex threads?"
            alert.informativeText = "Katescape will start its own local Codex App Server connection and read thread titles, directories and selected transcript text. It will not resume a thread or send a message. Thread data stays in memory."
            alert.addButton(withTitle: "Allow browsing")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: "codexHistoryConsent")
        }
        historyClient?.stop(); historyClient = nil; discoveredThreads = []
        guard let executable = executablePath(for: CodexProvider()) else {
            historyError("Codex CLI is unavailable. Install it separately before browsing threads."); return
        }
        let client = CodexHistoryClient(executable: executable)
        historyClient = client
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
                    } else { self.loadCodexThreads(client, cursor: nil, page: 0, seen: []) }
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
                    self.historyError("Codex returned thread metadata Katescape cannot safely display."); return
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
        alert.informativeText = "Showing up to 100 local threads. Choose one to read its latest 8 turns."
        let picker = CodexThreadPickerView(threads: discoveredThreads)
        alert.accessoryView = picker
        alert.addButton(withTitle: "View selected")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            guard let selected = picker.selected else { historyError("No thread was selected."); return }
            readCodexThread(client, selected)
        } else { client.stop(); historyClient = nil; discoveredThreads = [] }
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

    private func historyError(_ message: String) {
        historyClient?.stop(); historyClient = nil; discoveredThreads = []
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
        ring.toolTip = tooltipText()
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
        ring.toolTip = tooltipText()
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

    // the collapsed pill's width: goo, label, visitors and social badges
    var collapsedWidth: CGFloat {
        mini.sizeToFit()
        meter.sizeToFit()
        return 41 + mini.frame.width + (meterText.isEmpty ? 0 : 8 + meter.frame.width) + (visitors.tints.isEmpty ? 0 : 8 + visitors.width)
            + (social.counts.isEmpty ? 0 : 10 + social.width) + (todoBadge.n == 0 ? 0 : 10 + todoBadge.width) + 12
    }

    func fitCollapsed() {
        guard !open else { return }
        let W2 = collapsedWidth, f = panel.frame
        if abs(f.width - W2) > 0.5 { panel.setFrame(NSRect(x: f.midX - W2/2, y: f.minY, width: W2, height: f.height), display: true) }
    }

    // place the dot and labels for the current state
    func lay() {
        let gh = (open ? H : h) - 2
        dot.frame.origin = NSPoint(x: open ? 10 : 7, y: ((gh - 28)/2).rounded())
        mini.sizeToFit()
        mini.frame.origin = NSPoint(x: 41, y: (gh - mini.frame.height)/2)
        mini.isHidden = open
        mini.bobbing = mini.stringValue == "Mochi" && !dot.sleeping
        meter.sizeToFit()
        meter.frame.origin = NSPoint(x: mini.frame.maxX + 8, y: ((gh - meter.frame.height)/2).rounded())
        meter.isHidden = open || meterText.isEmpty
        var x = meterText.isEmpty ? mini.frame.maxX : meter.frame.maxX
        visitors.frame = NSRect(x: x + 8, y: ((gh - 10)/2).rounded(), width: max(visitors.width, 1), height: 12)
        visitors.isHidden = open || visitors.tints.isEmpty
        if !visitors.tints.isEmpty { x = visitors.frame.maxX }
        social.frame = NSRect(x: x + 10, y: ((gh - 14)/2).rounded(), width: max(social.width, 1), height: 14)
        social.isHidden = open || social.counts.isEmpty
        if !social.counts.isEmpty { x = social.frame.maxX }
        todoBadge.frame = NSRect(x: x + 10, y: ((gh - 14)/2).rounded(), width: max(todoBadge.width, 1), height: 14)
        todoBadge.isHidden = open || todoBadge.n == 0
        field.isHidden = !open
        status.isHidden = !open
    }

    @objc func tapped(_ g: NSClickGestureRecognizer) {
        guard !open else { return }
        if todoPanel?.isVisible == true && (todoPanel?.alphaValue ?? 0) > 0.5 { hideTodoList(); return }
        // the checklist badge opens the to-do list
        if !todoBadge.isHidden, todoBadge.bounds.insetBy(dx: -5, dy: -8).contains(g.location(in: todoBadge)) { toggleTodoList(); return }
        // a click on a social badge jumps to that tab; anywhere else opens the bar
        if !social.isHidden, let s = social.site(at: g.location(in: social)), social.bounds.contains(g.location(in: social)) { openSocial(s); return }
        setOpen(true)
    }

    // grow or shrink around the bar's current bottom centre
    func setOpen(_ o: Bool) {
        note("setOpen \(o)")
        guard o != open else { return }
        open = o
        let f = panel.frame
        let size = o ? NSSize(width: W, height: H) : NSSize(width: collapsedWidth, height: h)
        var to = NSRect(x: f.midX - size.width/2, y: f.minY, width: size.width, height: size.height)
        if let s = panel.screen?.visibleFrame { to.origin.x = min(max(to.minX, s.minX + 8), s.maxX - size.width - 8) }
        if !o { field.isHidden = true; status.isHidden = true }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.22; c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(to, display: true)
        }, completionHandler: { [weak self] in self?.lay() })
        if o {
            // show the field now (not after the animation) so it can take typing straight away
            mini.isHidden = true; visitors.isHidden = true; social.isHidden = true; todoBadge.isHidden = true; meter.isHidden = true; field.isHidden = false; status.isHidden = false
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
        mini.bobbing = !open && mini.stringValue == "Mochi" && !dot.sleeping

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
        note("bubble: " + String(text.prefix(30)))
        // the goo reacts: a proud double hop with sparkles when something went live, otherwise a hop
        if react {
            if text.range(of: #"\b(live|pushed|deployed|shipped|published)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { dot.proud() } else { dot.hop() }
        }
        let body = (full?.count ?? 0) > text.count ? full! : text
        bubbleProject.stringValue = "mochi · " + project
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

    // Return sends, Esc clears and folds up
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { send(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { field.stringValue = ""; setOpen(false); panel.resignKey(); lastApp?.activate(); return true }
        return false
    }

    // a short note in whichever label is showing
    func flash(_ s: String, _ ok: Bool = true) {
        let c = ok ? NSColor(red: 0.5, green: 0.9, blue: 1, alpha: 0.9) : NSColor(red: 1, green: 0.55, blue: 0.55, alpha: 0.95)
        status.stringValue = s; status.textColor = c
        mini.stringValue = s; mini.textColor = c; mini.sizeToFit(); fitCollapsed(); lay(); mini.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.status.stringValue = "→ \(self.provider.adapter.name)"; self.status.textColor = NSColor(white: 1, alpha: 0.6)
            self.mini.stringValue = "Mochi"; self.mini.textColor = NSColor(white: 1, alpha: 0.85); self.mini.sizeToFit(); self.fitCollapsed(); self.lay()
        }
    }

    @objc func toggleLogin(_ it: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item: \(error)") }
        it.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: sending

    func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        if answeringOther && provider == .claude { answer(nil, other: text); return }
        if handleTodo(text) { return }
        sending = true
        let selected = provider
        let adapter = selected.adapter
        // A GUI app may have a smaller PATH than Terminal. An existing session is still usable
        // when the executable is not visible from Mochi's PATH.
        let live = providerTTYs(selected)
        let tabs = terminalTTYs()
        guard let availableTabs = tabs else { sendFailure("Cannot inspect Terminal tabs. Allow Automation for Mochi."); return }
        let candidates = live.intersection(availableTabs)
        if candidates.isEmpty {
            if executablePath(for: adapter) == nil { sendFailure("\(adapter.name) CLI not found"); return }
            sendFailure("No active \(adapter.name) session in Terminal; start one there first"); return
        }
        if selected == .codex {
            guard executablePath(for: adapter) != nil else { sendFailure("Codex CLI executable unavailable to Katescape; draft kept"); return }
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

    func chooseSession(_ ttys: [String], provider name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Choose a \(name) Terminal session"
        alert.informativeText = "Several sessions are running. Run tty in a tab if you need to identify it. Your draft stays in Mochi if you cancel."
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

    func resetPlaceholder(_ s: String = "Message Mochi…") {
        field.placeholderAttributedString = NSAttributedString(string: s, attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.62), .font: NSFont.systemFont(ofSize: 14)])
    }

    // MARK: to-do list

    // "todo: buy matcha", "mochi add buy matcha to my to-do list", "what's on my list", "done matcha" (or "done 2")
    func handleTodo(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^(?i)(hey|hi|ok|okay)[,!]?\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)mochi[,!:]?\s+"#, with: "", options: .regularExpression)
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
        var views: [NSView] = [label("mochi · to-do" + (openN > 0 ? "   \(openN) open" : ""), size: 10, weight: .medium, color: cyanText, mono: true)]
        let close = Tap(frame: NSRect(x: 0, y: 0, width: 20, height: 18)); close.isBordered = false; close.target = self; close.action = #selector(closeTodoList)
        close.attributedTitle = NSAttributedString(string: "×", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(white: 1, alpha: 0.55)])
        close.toolTip = "Close"
        let list = todos.sorted { ($0.done == nil ? 0 : 1, $0.added) < ($1.done == nil ? 0 : 1, $1.added) }
        if list.isEmpty {
            views.append(label("All clear ✨  Tell Mochi “todo: …” to add something.", size: 12, color: NSColor(white: 1, alpha: 0.7), wrap: iw))
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
            label("mochi · claude is asking" + (qs.count > 1 ? "   \(qIndex + 1) of \(qs.count)" : ""), size: 10, weight: .medium, color: cyanText, mono: true),
            label(q["question"] as? String ?? "", size: 13.5, weight: .semibold, wrap: iw)]
        if multi { views.append(label("This one takes several picks, so answer it in Terminal.", size: 11.5, color: NSColor(white: 1, alpha: 0.6), wrap: iw)) }
        for (i, o) in opts.enumerated() { views.append(option(o["label"] as? String ?? "", o["description"] as? String ?? "", width: iw, tag: i, enabled: !multi)) }
        if !multi { views.append(option("Other…", "Type your own answer in Mochi", width: iw, tag: 1000, enabled: true)) }
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

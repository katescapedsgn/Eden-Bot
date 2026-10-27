import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func makeApp(in root: URL, file: String, display: String, bundleName: String, id: String) -> URL {
    let app = root.appendingPathComponent(file + ".app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL",
                                  "CFBundleName": bundleName, "CFBundleDisplayName": display]
    let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try! data.write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("katescape-launcher-tests-\(UUID().uuidString)")
let standard = scratch.appendingPathComponent("Applications")
let outside = scratch.appendingPathComponent("Elsewhere")
try! FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

let spotifyURL = makeApp(in: standard, file: "Spotify", display: "Spotify", bundleName: "Spotify", id: "com.spotify.client")
_ = makeApp(in: standard, file: "Discord", display: "Discord", bundleName: "Discord", id: "com.hnc.Discord")
_ = makeApp(in: standard, file: "Godot", display: "Godot Engine", bundleName: "Godot", id: "org.godotengine.godot")
_ = makeApp(in: standard, file: "Photos", display: "Photos", bundleName: "Photos", id: "com.apple.Photos")
_ = makeApp(in: standard, file: "Visual Studio Code", display: "Visual Studio Code", bundleName: "Code", id: "com.microsoft.VSCode")
_ = makeApp(in: standard, file: "Adobe Photoshop 2026", display: "Adobe Photoshop 2026", bundleName: "Adobe Photoshop 2026", id: "com.adobe.Photoshop.2026")
let safariURL = makeApp(in: outside, file: "Safari", display: "Safari", bundleName: "Safari", id: "com.apple.Safari")

let parser = LauncherCommandParser()
check(parser.parse("Open Photoshop") == .open(["Photoshop"]), "open parser")
check(parser.parse("Launch Godot") == .open(["Godot"]), "launch parser")
check(parser.parse("Open Spotify and Discord") == .open(["Spotify", "Discord"]), "multiple apps")
check(parser.parse("Switch to Safari") == .open(["Safari"]), "switch parser")
check(parser.parse("Open VS Code") == .open(["VS Code"]), "multiword alias")
check(parser.parse("Open Photos") == .open(["Photos"]), "photos parser")
check(parser.parse("Open Spotify and Spotify") == .open(["Spotify"]), "duplicate names")
check(parser.parse("Show my Codex conversations") == .browseCodexThreads, "Codex browser route")
check(parser.parse("What is this code doing?") == .message, "ordinary message")
check(parser.parse("Start writing") == .message, "ordinary start message")
check(parser.parse("Open the project") == .message, "ordinary open message")
check(parser.parse("Open /Applications/Spotify.app") == .invalidAppReference, "path rejected")
check(parser.parse("Open https://example.com") == .invalidAppReference, "URL rejected")

let apps = LauncherAppDiscovery.catalog(roots: [standard], registeredURLs: [safariURL])
check(apps.count == 7, "validated app bundle discovery")
check(LauncherAppResolver.resolve("Spotify", in: apps) == .exact(apps.filter { $0.bundleID == "com.spotify.client" }), "exact app name")
check(LauncherAppResolver.resolve("com.apple.Photos", in: apps) == .exact(apps.filter { $0.bundleID == "com.apple.Photos" }), "bundle ID")
check(LauncherAppResolver.resolve("VS Code", in: apps) == .alias(apps.filter { $0.bundleID == "com.microsoft.VSCode" }), "alias resolution")
check(LauncherAppResolver.resolve("Godot", in: apps) == .exact(apps.filter { $0.bundleID == "org.godotengine.godot" }), "bundle name exact match")
check(LauncherAppResolver.resolve("Photoshop", in: apps) == .alias(apps.filter { $0.bundleID == "com.adobe.Photoshop.2026" }), "Photoshop alias")
check(LauncherAppResolver.resolve("Safari", in: apps) == .exact(apps.filter { $0.url == safariURL }), "registered app outside Applications")
check(LauncherAppResolver.resolve("NoSuchApp", in: apps) == .missing, "missing app")
if case .suggestions(let choices) = LauncherAppResolver.resolve("Spotfy", in: apps) {
    check(choices.contains(where: { $0.bundleID == "com.spotify.client" }), "fuzzy suggestion")
} else { check(false, "approximate match must require choice") }

let duplicateRoot = scratch.appendingPathComponent("SecondApplications")
_ = makeApp(in: duplicateRoot, file: "Spotify", display: "Spotify", bundleName: "Spotify", id: "com.spotify.client")
let duplicates = LauncherAppDiscovery.catalog(roots: [standard, duplicateRoot], registeredURLs: [])
if case .exact(let choices) = LauncherAppResolver.resolve("Spotify", in: duplicates) {
    check(choices.count == 2, "ambiguous exact names require a choice")
} else { check(false, "ambiguous exact resolution") }

let priorityRoot = scratch.appendingPathComponent("PriorityApplications")
_ = makeApp(in: priorityRoot, file: "Codex", display: "Codex", bundleName: "Codex", id: "example.codex")
_ = makeApp(in: priorityRoot, file: "ChatGPT", display: "ChatGPT", bundleName: "ChatGPT", id: "com.openai.codex")
let priorityApps = LauncherAppDiscovery.catalog(roots: [priorityRoot], registeredURLs: [])
check(LauncherAppResolver.resolve("Codex", in: priorityApps) == .exact(priorityApps.filter { $0.bundleID == "example.codex" }),
      "exact name takes precedence over alias")

_ = makeApp(in: duplicateRoot, file: "Adobe Photoshop 2025", display: "Adobe Photoshop 2025", bundleName: "Adobe Photoshop 2025", id: "com.adobe.Photoshop.2025")
let versions = LauncherAppDiscovery.catalog(roots: [standard, duplicateRoot], registeredURLs: [])
if case .alias(let choices) = LauncherAppResolver.resolve("Photoshop", in: versions) {
    check(choices.count == 2, "ambiguous alias requires a choice")
} else { check(false, "ambiguous alias resolution") }

let nestedRoot = scratch.appendingPathComponent("NestedApplications")
let utilities = nestedRoot.appendingPathComponent("Utilities")
_ = makeApp(in: utilities, file: "写真", display: "写真", bundleName: "写真", id: "example.photos.ja")
let nestedApps = LauncherAppDiscovery.catalog(roots: [nestedRoot], registeredURLs: [])
if case .exact(let choices) = LauncherAppResolver.resolve("写真", in: nestedApps) {
    check(choices.count == 1, "nested Unicode app name")
} else { check(false, "nested Unicode discovery") }

let freshRoot = scratch.appendingPathComponent("NewApplications")
try! FileManager.default.createDirectory(at: freshRoot, withIntermediateDirectories: true)
check(LauncherAppResolver.resolve("Newly Installed", in: LauncherAppDiscovery.catalog(roots: [freshRoot], registeredURLs: [])) == .missing,
      "not installed yet")
_ = makeApp(in: freshRoot, file: "Newly Installed", display: "Newly Installed", bundleName: "Newly Installed", id: "example.newlyinstalled")
if case .exact(let choices) = LauncherAppResolver.resolve("Newly Installed", in: LauncherAppDiscovery.catalog(roots: [freshRoot], registeredURLs: [])) {
    check(choices.count == 1, "newly installed app found on refresh")
} else { check(false, "new app refresh") }

check(LauncherAppDiscovery.sameLocation(spotifyURL, spotifyURL), "running app path match")
check(!LauncherAppDiscovery.sameLocation(spotifyURL, safariURL), "different running app must not match")

try! FileManager.default.removeItem(at: scratch)
print("Launcher parser and resolver tests passed")

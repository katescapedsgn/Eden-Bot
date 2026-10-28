import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func catFrame(_ time: Double = 0, sleepAge: Double? = nil, thinking: Bool = false,
              asking: Bool = false, petting: Bool = false, worried: Bool = false,
              happyAge: Double = -1, blinkAge: Double = -1,
              waveAge: Double = -1, pettingAge: Double = -1, confusedAge: Double = -1) -> EdenAnimation.Frame {
    EdenAnimation.select(catTime: time, sleepAge: sleepAge, thinking: thinking, asking: asking,
                         petting: petting, worried: worried, happyAge: happyAge, blinkAge: blinkAge,
                         waveAge: waveAge, pettingAge: pettingAge, confusedAge: confusedAge)
}

check(catFrame() == .init(kind: .idle, index: 0), "Eden defaults to idle")
check(catFrame(0.46) == .init(kind: .idle, index: 1), "idle advances at 0.45 seconds")
check(catFrame(1.81) == .init(kind: .idle, index: 0), "idle loops after four frames")
for index in 0..<4 {
    check(catFrame(blinkAge: Double(index) / 12) == .init(kind: .blink, index: index),
          "blink frame \(index) at 12 fps")
    check(catFrame(Double(index) * 0.3, thinking: true) == .init(kind: .thinking, index: index),
          "thinking frame \(index)")
    check(catFrame(happyAge: Double(index) * 0.2) == .init(kind: .happy, index: index),
          "happy frame \(index)")
}
check(catFrame(blinkAge: 0.34).kind == .idle, "blink returns to idle")
check(catFrame(happyAge: 0.8).kind == .idle, "happy finishes before returning to idle")
check(catFrame(sleepAge: 0).index == 0 && catFrame(sleepAge: 1.2).index == 2 &&
      catFrame(sleepAge: 7.3).index == 1, "sleep breathes and occasionally twitches ears")
check(catFrame(sleepAge: 0, thinking: true, happyAge: 0, blinkAge: 0).kind == .sleeping,
      "sleep takes priority")
check(catFrame(thinking: true, happyAge: 0, blinkAge: 0).kind == .thinking,
      "thinking takes priority over happy and blink")
check(catFrame(thinking: true, asking: true).kind == .idle &&
      catFrame(worried: true, happyAge: 0).kind == .idle, "question and error use neutral Eden")
check(catFrame(petting: true, blinkAge: 0).kind == .idle, "petting keeps neutral frame")
check(catFrame(waveAge: 0).kind == .idle && catFrame(waveAge: 0.2).kind == .wave &&
      catFrame(waveAge: 0.6).kind == .idle && catFrame(waveAge: 0.8).kind == .idle,
      "wave plays one idle-wave-idle sequence")
check(catFrame(petting: true, pettingAge: 0).kind == .idle &&
      catFrame(petting: true, pettingAge: 0.2) == .init(kind: .petting, index: 0) &&
      catFrame(petting: true, pettingAge: 0.4) == .init(kind: .petting, index: 1) &&
      catFrame(petting: true, pettingAge: 0.6) == .init(kind: .petting, index: 0) &&
      catFrame(petting: true, pettingAge: 0.8).kind == .idle &&
      catFrame(petting: false, pettingAge: 0.4).kind == .idle,
      "petting loops while active and stops when petting ends")
check(catFrame(confusedAge: 0).kind == .idle &&
      catFrame(confusedAge: 0.2).kind == .confused &&
      catFrame(confusedAge: 0.8).kind == .idle &&
      catFrame(confusedAge: 1.0).kind == .idle,
      "confused plays one idle-confused-idle sequence")
check(catFrame(sleepAge: 0, waveAge: 0.3, confusedAge: 0.3).kind == .sleeping &&
      catFrame(thinking: true, waveAge: 0.3).kind == .thinking &&
      catFrame(petting: true, waveAge: 0.3, pettingAge: 0.3).kind == .wave &&
      catFrame(thinking: true, waveAge: 0.3, confusedAge: 0.3).kind == .confused,
      "sleep and error priorities prevent conflicting animations")
check(EdenAnimation.overlays(for: catFrame(), asking: false, petting: false, worried: false).isEmpty,
      "idle has no legacy effects")
check(EdenAnimation.overlays(for: catFrame(blinkAge: 0), asking: false, petting: false, worried: false).isEmpty,
      "blink has no legacy effects")
check(EdenAnimation.overlays(for: catFrame(sleepAge: 2), asking: false, petting: false, worried: false).isEmpty,
      "sleep sprite has no Zzz overlay")
check(EdenAnimation.overlays(for: catFrame(thinking: true), asking: false, petting: false, worried: false).isEmpty,
      "thinking sprite has no dots overlay")
check(EdenAnimation.overlays(for: catFrame(happyAge: 0), asking: false, petting: false, worried: false).isEmpty,
      "happy sprite has no sparkles overlay")
check(EdenAnimation.overlays(for: catFrame(petting: true), asking: false, petting: true, worried: false) == [.heart],
      "heart appears only while petting")
check(EdenAnimation.overlays(for: catFrame(asking: true), asking: true, petting: false, worried: false) == [.question],
      "question indicator remains")
check(EdenAnimation.overlays(for: catFrame(worried: true), asking: false, petting: false, worried: true) == [.warning],
      "warning indicator remains")
check(EdenAnimation.overlays(for: catFrame(), asking: false, petting: false, worried: false).isEmpty,
      "effects stop when their state ends")
check(CatSprites.neutral == nil && CatSprites.image(for: catFrame()) == nil,
      "missing artwork stays missing in an unbundled test executable")
check(CatSprites.loadIssues.count == 23 && CatSprites.loadIssues.allSatisfy { $0.contains("missing from app bundle") },
      "unbundled artwork reports each missing frame with a reason")
if let path = ProcessInfo.processInfo.environment["EDEN_TEST_APP_BUNDLE"] {
    guard let bundle = Bundle(url: URL(fileURLWithPath: path)) else {
        fputs("FAIL: EDEN_TEST_APP_BUNDLE is not an app bundle\n", stderr); exit(1)
    }
    let specs: [(String, String, Int, NSSize)] = [
        ("idle", "idle", 4, NSSize(width: 288, height: 288)),
        ("blink", "blink", 4, NSSize(width: 288, height: 288)),
        ("sleep", "sleeping", 3, NSSize(width: 288, height: 256)),
        ("thinking", "thinking", 4, NSSize(width: 288, height: 288)),
        ("happy", "happy", 4, NSSize(width: 320, height: 320)),
        ("wave", "wave", 1, NSSize(width: 288, height: 288)),
        ("pet", "petting", 2, NSSize(width: 288, height: 288)),
        ("confused", "confused", 1, NSSize(width: 288, height: 288))
    ]
    var loadedCount = 0
    for (name, folder, count, size) in specs {
        let result = CatSprites.load(name, in: folder, count: count, size: size, bundle: bundle)
        check(result.issues.isEmpty, "\(folder) sprites load: \(result.issues.joined(separator: "; "))")
        check(result.frames.count == count && result.frames.allSatisfy { $0?.size == size },
              "\(folder) sprites retain the expected point canvas")
        loadedCount += result.frames.compactMap { $0 }.count
    }
    check(loadedCount == 23, "all 23 bundled sprites decode with Eden's loader")
}
check(LauncherCommandParser.isExplicitDesktopCommand("Open a file") &&
      LauncherCommandParser.isExplicitDesktopCommand("Copy something") &&
      !LauncherCommandParser.isExplicitDesktopCommand("Hello, Eden"),
      "only explicit desktop command wording requests confused feedback")

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

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("eden-launcher-tests-\(UUID().uuidString)")
let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
let petFrame = NSRect(x: 100, y: 20, width: 96, height: 96)
let chatSize = NSSize(width: 340, height: 168)
let chatFrame = PetChatLayout.chatFrame(pet: petFrame, size: chatSize, visible: screen)
check(chatFrame.width == 340 && chatFrame.height == 168, "compact chat dimensions")
check(chatFrame.minX == petFrame.maxX + 8 && chatFrame.minY == petFrame.minY,
      "chat opens beside the stationary pet")
for _ in 0..<100 {
    check(PetChatLayout.chatFrame(pet: petFrame, size: chatSize, visible: screen) == chatFrame,
          "repeated chat toggles do not accumulate position drift")
}
check(PetChatLayout.petFrame(petFrame, visible: screen) == petFrame,
      "existing pet position is preserved")
let edgePets = [NSRect(x: 8, y: 200, width: 96, height: 96),
                NSRect(x: 696, y: 200, width: 96, height: 96),
                NSRect(x: 300, y: 8, width: 96, height: 96),
                NSRect(x: 300, y: 496, width: 96, height: 96)]
for pet in edgePets {
    let chat = PetChatLayout.chatFrame(pet: pet, size: chatSize, visible: screen)
    check(chat.minX >= screen.minX + 8 && chat.maxX <= screen.maxX - 8 &&
          chat.minY >= screen.minY + 8 && chat.maxY <= screen.maxY - 8,
          "chat fits near every screen edge without moving the pet")
}
check(PetChatLayout.chatFrame(pet: edgePets[1], size: chatSize, visible: screen).maxX == edgePets[1].minX - 8,
      "chat flips to the left at the right edge")
let narrow = NSRect(x: 0, y: 0, width: 420, height: 600)
check(PetChatLayout.chatFrame(pet: NSRect(x: 160, y: 180, width: 96, height: 96),
                              size: chatSize, visible: narrow).minY == 284,
      "chat moves above the pet when neither side fits")
check(PetChatLayout.chatFrame(pet: NSRect(x: 160, y: 450, width: 96, height: 96),
                              size: chatSize, visible: narrow).maxY == 442,
      "chat moves below the pet when above does not fit")
let secondScreen = NSRect(x: 800, y: -200, width: 1200, height: 900)
let secondPet = NSRect(x: 950, y: -180, width: 96, height: 96)
let secondChat = PetChatLayout.chatFrame(pet: secondPet, size: chatSize, visible: secondScreen)
check(secondChat.minX >= secondScreen.minX + 8 && secondChat.maxX <= secondScreen.maxX - 8 &&
      secondChat.minY >= secondScreen.minY + 8 && secondChat.maxY <= secondScreen.maxY - 8,
      "chat uses the second display's point coordinates")
let smallVisible = NSRect(x: 0, y: 0, width: 420, height: 300)
let quickHeight: CGFloat = min(QuickChatLayout.height(for: .selecting(.open), hasBadges: false),
                               max(168, smallVisible.height - 16))
let smallPet = NSRect(x: 160, y: 100, width: 96, height: 96)
let quickChat = PetChatLayout.chatFrame(pet: smallPet,
    size: NSSize(width: 340, height: quickHeight), visible: smallVisible)
check(quickChat.width == 340 && quickChat.height == 284 &&
      quickChat.minY >= 8 && quickChat.maxY <= smallVisible.maxY - 8,
      "Quick Actions chat is height-clamped on a small screen")
check(smallPet == NSRect(x: 160, y: 100, width: 96, height: 96),
      "Quick Actions height does not move the pet")
let homeHeight = QuickChatLayout.height(for: .home, hasBadges: false)
let homeHeading = QuickChatLayout.headingY(height: homeHeight, hasBadges: false)
let homeButtons = QuickChatLayout.scrollFrame(height: homeHeight, hasBadges: false)
check(homeHeight == 275 && homeButtons.height == 100 && homeButtons.width == 308,
      "Quick Actions home fits the compact chat")
check(homeHeight - 31 - (homeHeading + 17) == 16 &&
      homeHeading - homeButtons.maxY == 12 &&
      QuickChatLayout.buttonRowGap == 8 &&
      QuickChatLayout.buttonsBottom - QuickChatLayout.input.maxY == 16 &&
      QuickChatLayout.input.minY == 16,
      "Quick Actions vertical spacing matches the compact layout")
check(QuickChatLayout.height(for: .selecting(.copy), hasBadges: false) == 262 &&
      QuickChatLayout.height(for: .selecting(.open), hasBadges: false) == 390 &&
      QuickChatLayout.height(for: .home, hasBadges: true) == 295,
      "guided actions and badges retain enough vertical space")
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
let guidedParser = GuidedMessageIntentParser()
check(guidedParser.parse("Message ChatGPT") == .chatGPT, "ChatGPT guided intent")
check(guidedParser.parse("I want to send a message to ChatGPT") == .chatGPT, "ChatGPT full intent")
check(guidedParser.parse("Send a message to Claude") == .claude, "Claude guided intent")
check(guidedParser.parse("Message Claude") == .claude, "Claude short intent")
check(guidedParser.parse("Open Claude") == nil, "app launcher remains separate")
check(guidedParser.parse("Message Claude Code") == nil, "Claude Code remains separate")
check(guidedParser.parse("Message Codex Desktop") == nil, "Codex Desktop remains separate")
check(guidedParser.parse("What is ChatGPT?") == nil, "ordinary text is not a guided intent")
var guided = GuidedMessageFlow()
guided.start(.chatGPT)
check(guided.state == .composing(.chatGPT), "begin composition")
guided.cancel()
check(guided.state == .idle, "cancel during composition")
guided.start(.claude)
check(guided.capture("Hello Claude"), "capture draft")
check(guided.state == .confirming(.claude, "Hello Claude"), "confirmation state")
guided.edit()
check(guided.state == .editing(.claude, "Hello Claude"), "edit preserves draft")
guided.start(.chatGPT)
check(guided.state == .editing(.chatGPT, "Hello Claude"), "change destination preserves draft")
check(guided.capture("Revised message"), "capture edited draft")
check(guided.state == .confirming(.chatGPT, "Revised message"), "edited confirmation")
guided.cancel()
check(guided.state == .idle, "cancel confirmation")
var quick = QuickActionFlow()
check(quick.state == .home, "quick actions start at home")
for action in QuickActionFlow.Action.allCases {
    quick.begin(action)
    check(quick.state == .selecting(action), "quick action selects \(action.title)")
    quick.back()
    check(quick.state == .home, "Back returns from \(action.title)")
    quick.begin(action)
    quick.cancel()
    check(quick.state == .home, "Cancel returns from \(action.title)")
}
check(QuickActionFlow.Action.open.appAction != nil && QuickActionFlow.Action.copy.appAction == nil,
      "quick actions separate app and non-app operations")
check(parser.parse("Open Photoshop") == .open(["Photoshop"]), "open parser")
check(parser.parse("Launch Godot") == .open(["Godot"]), "launch parser")
check(parser.parse("Open Spotify and Discord") == .open(["Spotify", "Discord"]), "multiple apps")
check(parser.parse("Switch to Safari") == .switchTo(["Safari"]), "switch parser")
check(parser.parse("Hide Safari") == .hide(["Safari"]), "hide parser")
check(parser.parse("Quit Figma") == .quit(["Figma"]), "quit parser")
check(parser.parse("Close Spotify") == .message, "close is not confused with quit")
check(parser.parse("Hide Spotify and Discord") == .hide(["Spotify", "Discord"]), "multiple hide targets")
check(parser.parse("Open Desktop") == .folder(.desktop), "Desktop folder")
check(parser.parse("Open Documents") == .folder(.documents), "Documents folder")
check(parser.parse("Open Downloads") == .folder(.downloads), "Downloads folder")
check(parser.parse("Open Applications") == .folder(.applications), "Applications folder")
check(parser.parse("Open Eden Bot project folder") == .folder(.edenProject), "configured project folder")
check(parser.parse("Open YouTube") == .website(.youtube), "YouTube allowlist")
check(parser.parse("Open Google") == .website(.google), "Google allowlist")
check(parser.parse("Open Wikipedia") == .website(.wikipedia), "Wikipedia allowlist")
check(parser.parse("Open GitHub") == .website(.github), "GitHub allowlist")
check(DesktopWebsite.youtube.url.scheme == "https", "allowlisted sites use HTTPS")
check(parser.parse("Show Desktop") == .showDesktopUnavailable, "unsupported Show Desktop is explicit")
check(parser.parse("Copy text: Hello, Eden!") == .copy("Hello, Eden!"), "explicit clipboard text")
check(parser.parse("Copy hello to clipboard") == .copy("hello"), "clipboard suffix")
check(parser.parse("Copy text: https://example.com") == .copy("https://example.com"), "clipboard text is data")
check(parser.parse("Copy") == .message, "copy without text is not executed")
check(parser.parse("Open example.com") == .open(["example.com"]), "unknown site is not opened as a URL")
check(parser.parse("Open https://example.com") == .invalidAppReference, "arbitrary website is rejected")
let projectHome = scratch.appendingPathComponent("home", isDirectory: true)
let projectPath = projectHome.appendingPathComponent("Documents/GitHub/Eden Bot", isDirectory: true)
try! FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
check(EdenProjectLocation.resolve(configured: nil, home: projectHome) == projectPath,
      "existing Eden project fallback")
check(EdenProjectLocation.resolve(configured: "/missing/eden-project", home: projectHome) == nil,
      "missing configured project does not open a different folder")
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
check(GuidedMessageAppResolver.verifiedApp(for: .chatGPT, at: nil) == nil, "missing ChatGPT app uses website")
let misleadingChatGPT = makeApp(in: priorityRoot, file: "ChatGPT Copy", display: "ChatGPT", bundleName: "ChatGPT", id: "com.openai.codex")
check(GuidedMessageAppResolver.verifiedApp(for: .chatGPT, at: misleadingChatGPT) == nil,
      "Codex Desktop must not be mistaken for ChatGPT")
let verifiedChatGPT = makeApp(in: priorityRoot, file: "ChatGPT Verified", display: "ChatGPT", bundleName: "ChatGPT", id: "com.openai.chat")
check(GuidedMessageAppResolver.verifiedApp(for: .chatGPT, at: verifiedChatGPT)?.bundleID == "com.openai.chat",
      "verified ChatGPT desktop app")
let verifiedClaude = makeApp(in: priorityRoot, file: "Claude", display: "Claude", bundleName: "Claude", id: "com.anthropic.claudefordesktop")
check(GuidedMessageAppResolver.verifiedApp(for: .claude, at: verifiedClaude)?.bundleID == "com.anthropic.claudefordesktop",
      "verified Claude desktop app")
check(GuidedMessageDestination.chatGPT.website.absoluteString == "https://chatgpt.com/", "ChatGPT browser fallback")
check(GuidedMessageDestination.claude.website.absoluteString == "https://claude.ai/", "Claude browser fallback")

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
print("Launcher, resolver and Eden animation tests passed")

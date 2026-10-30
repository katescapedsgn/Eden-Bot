import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let idleResource = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EDEN_DIALOGUE_SOURCE"] ?? "")
guard let idleDialogue = IdleThoughtsDialogue.load(from: idleResource) else {
    fputs("FAIL: Idle Thoughts dialogue resource\n", stderr); exit(1)
}
check(idleDialogue.categories.count == 5 && idleDialogue.categories.allSatisfy { (10...15).contains($0.lines.count) },
      "five dialogue categories with 10–15 lines each")
check(IdleThoughtsDialogue.load(from: nil) == nil, "missing dialogue fails safely")
let badDialogue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
try! Data(#"{"categories":[{"id":"a","lines":["same","same"]}]}"#.utf8).write(to: badDialogue)
check(IdleThoughtsDialogue.load(from: badDialogue) == nil, "duplicate dialogue rejected")
try! FileManager.default.removeItem(at: badDialogue)
let start = Date(timeIntervalSince1970: 1_000_000)
let pettingResource = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EDEN_PETTING_SOURCE"] ?? "")
guard let pettingLines = PettingDialogue.load(from: pettingResource) else {
    fputs("FAIL: Petting Dialogue resource\n", stderr); exit(1)
}
check((12...16).contains(pettingLines.lines.count) && Set(pettingLines.lines).count == pettingLines.lines.count,
      "petting dialogue count and uniqueness")
let idleLines = Set(idleDialogue.categories.flatMap(\.lines))
check(pettingLines.lines.allSatisfy { !idleLines.contains($0) }, "petting lines do not copy idle thoughts")
check(PettingDialogue.load(from: nil) == nil, "missing petting dialogue fails safely")
let badPetting = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
try! Data(#"{"lines":["same","same"]}"#.utf8).write(to: badPetting)
check(PettingDialogue.load(from: badPetting) == nil, "duplicate petting dialogue rejected")
try! Data(#"{"lines":[" "]}"#.utf8).write(to: badPetting)
check(PettingDialogue.load(from: badPetting) == nil, "blank petting dialogue rejected")
try! Data(#"{"lines": ["broken""#.utf8).write(to: badPetting)
check(PettingDialogue.load(from: badPetting) == nil, "malformed petting dialogue rejected")
try! FileManager.default.removeItem(at: badPetting)
check((0..<500).allSatisfy { _ in (30...60).contains(PettingDialogueScheduler.randomCooldown()) },
      "petting cooldown is 30–60 seconds")
var pettingScheduler = PettingDialogueScheduler(dialogue: pettingLines)
check(pettingScheduler.observe(now: start, hoverStart: 1, hoverAge: 0.6,
                               enabled: true, eligible: true) == nil,
      "petting sprite threshold does not immediately trigger dialogue")
check(pettingScheduler.observe(now: start, hoverStart: 1, hoverAge: 2.19,
                               enabled: true, eligible: true) == nil,
      "sustained petting must reach 2.2 seconds")
let firstPet = pettingScheduler.observe(now: start, hoverStart: 1, hoverAge: 2.2,
                                        enabled: true, eligible: true, cooldown: { 30 }, choose: { _ in 0 })
check(firstPet != nil && pettingScheduler.nextAllowed == start.addingTimeInterval(30),
      "sustained petting shows one line and arms cooldown")
check(pettingScheduler.observe(now: start.addingTimeInterval(31), hoverStart: 1, hoverAge: 33,
                               enabled: true, eligible: true) == nil,
      "continuous hover never retriggers dialogue")
_ = pettingScheduler.observe(now: start, hoverStart: nil, hoverAge: 0, enabled: true, eligible: true)
check(pettingScheduler.observe(now: start.addingTimeInterval(20), hoverStart: 2, hoverAge: 2.2,
                               enabled: true, eligible: true) == nil,
      "new hover during cooldown has no dialogue")
check(pettingScheduler.observe(now: start.addingTimeInterval(31), hoverStart: 2, hoverAge: 13,
                               enabled: true, eligible: true) == nil,
      "cooldown expiry does not queue dialogue within a blocked hover")
var chosenPets: [String] = [firstPet!]
for index in 3...9 {
    _ = pettingScheduler.observe(now: start, hoverStart: nil, hoverAge: 0, enabled: true, eligible: true)
    let line = pettingScheduler.observe(now: start.addingTimeInterval(Double(index * 61)),
                                        hoverStart: Double(index), hoverAge: 2.2,
                                        enabled: true, eligible: true, cooldown: { 30 }, choose: { _ in 0 })
    check(line != nil && !chosenPets.suffix(5).contains(line!), "previous five petting lines do not repeat")
    chosenPets.append(line!)
}
_ = pettingScheduler.observe(now: start, hoverStart: nil, hoverAge: 0, enabled: true, eligible: true)
check(pettingScheduler.observe(now: start.addingTimeInterval(1000), hoverStart: 10, hoverAge: 2.2,
                               enabled: false, eligible: true) == nil &&
      pettingScheduler.observe(now: start.addingTimeInterval(1001), hoverStart: 10, hoverAge: 3.2,
                               enabled: true, eligible: true) == nil,
      "disabled petting dialogue cannot appear later in the same hover")
_ = pettingScheduler.observe(now: start, hoverStart: nil, hoverAge: 0, enabled: true, eligible: true)
check(pettingScheduler.observe(now: start.addingTimeInterval(1100), hoverStart: 11, hoverAge: 2.2,
                               enabled: true, eligible: false) == nil,
      "chat, quick actions, sleep and important bubbles suppress casual dialogue")
var disabledIdleScheduler = IdleThoughtsScheduler(dialogue: idleDialogue)
var independentPetting = PettingDialogueScheduler(dialogue: pettingLines)
check(disabledIdleScheduler.tick(at: start, eligible: false) == nil &&
      independentPetting.observe(now: start, hoverStart: 12, hoverAge: 2.2,
                                 enabled: true, eligible: true) != nil,
      "petting dialogue remains available when Idle Thoughts are disabled")
var bubbles = BubbleCoordinator()
let petGeneration = bubbles.offer(.petting)!
check(bubbles.offer(.idleThought) == nil && bubbles.generation == petGeneration,
      "idle thought cannot replace petting dialogue")
let feedbackGeneration = bubbles.offer(.feedback)!
check(bubbles.offer(.petting) == nil && bubbles.offer(.idleThought) == nil,
      "petting and idle thoughts cannot replace command feedback")
check(bubbles.dismiss(ifGeneration: petGeneration) == nil && bubbles.generation == feedbackGeneration,
      "stale petting dismissal cannot close command feedback")
let providerGeneration = bubbles.offer(.provider)!
check(providerGeneration > feedbackGeneration && bubbles.offer(.petting) == nil,
      "provider response supersedes earlier feedback and blocks petting")
let fadedGeneration = bubbles.dismiss(ifGeneration: providerGeneration)!
let newerGeneration = bubbles.offer(.feedback)!
check(fadedGeneration != newerGeneration && bubbles.dismiss(ifGeneration: providerGeneration) == nil &&
      bubbles.priority == .feedback,
      "stale fade completion cannot close a newer bubble")
var idleScheduler = IdleThoughtsScheduler(dialogue: idleDialogue)
check(IdleThoughtsScheduler.displayDuration == 4, "thought bubble duration remains four seconds")
check((0..<500).allSatisfy { _ in (120...240).contains(IdleThoughtsScheduler.randomFirstDelay()) &&
      (360...540).contains(IdleThoughtsScheduler.randomSecondDelay()) },
      "first and second thoughts stay within their two to four and six to nine minute windows")
check(idleScheduler.tick(at: start, eligible: true, firstDelay: { 120 }, secondDelay: { 360 }) == nil &&
      idleScheduler.nextDue == start.addingTimeInterval(120) &&
      idleScheduler.secondDue == start.addingTimeInterval(360),
      "one eligible cycle schedules two separated thoughts")
check(idleScheduler.tick(at: start.addingTimeInterval(119), eligible: true) == nil,
      "first thought stays hidden before its due time")
let firstCycleLine = idleScheduler.tick(at: start.addingTimeInterval(120), eligible: true)
idleScheduler.completeDisplay()
check(firstCycleLine != nil && idleScheduler.thoughtsShown == 1 &&
      idleScheduler.tick(at: start.addingTimeInterval(359), eligible: true) == nil,
      "first thought displays once and the second remains separated")
let secondCycleLine = idleScheduler.tick(at: start.addingTimeInterval(360), eligible: true)
idleScheduler.completeDisplay()
check(secondCycleLine != nil && secondCycleLine != firstCycleLine && idleScheduler.thoughtsShown == 2 &&
      idleScheduler.tick(at: start.addingTimeInterval(600), eligible: true) == nil,
      "exactly two distinct thoughts appear in one ten-minute cycle")
var displayed: [String] = []
var categories: [String] = []
for index in 0..<20 {
    idleScheduler.restartAfterInteraction()
    let cycleStart = start.addingTimeInterval(Double(index * 700 + 1000))
    _ = idleScheduler.tick(at: cycleStart, eligible: true, firstDelay: { 120 }, secondDelay: { 360 })
    for offset in [120.0, 360.0] {
        guard let line = idleScheduler.tick(at: cycleStart.addingTimeInterval(offset), eligible: true) else {
            fputs("FAIL: due idle thought missing\n", stderr); exit(1)
        }
        check(!displayed.suffix(10).contains(line), "previous ten thoughts are not repeated")
        displayed.append(line)
        categories.append(idleScheduler.lastCategory ?? "")
        idleScheduler.completeDisplay()
    }
}
check(zip(categories, categories.dropFirst()).allSatisfy { $0 != $1 },
      "consecutive thoughts use different categories")
idleScheduler.pause()
check(idleScheduler.nextDue == nil &&
      idleScheduler.tick(at: start.addingTimeInterval(20_000), eligible: false) == nil &&
      idleScheduler.tick(at: start.addingTimeInterval(20_001), eligible: true,
                         firstDelay: { 240 }, secondDelay: { 540 }) == nil &&
      idleScheduler.nextDue == start.addingTimeInterval(20_241),
      "sleep or interaction restarts a fresh two-thought cycle")

for night in [false, true] {
    var cycle = IdleThoughtsScheduler(dialogue: idleDialogue)
    check(cycle.tick(at: start, eligible: true, firstDelay: { 240 }, secondDelay: { 540 }) == nil,
          "two thoughts arm at four and nine minutes")
    let threshold = EdenAutoSleep.threshold(night: night)
    check(threshold == (night ? 60 : 300), "original day and night sleep thresholds")
    let beforeFirst = start.addingTimeInterval(night ? 61 : 239)
    check(!EdenAutoSleep.shouldSleep(inactiveFor: night ? 61 : 239, night: night, now: beforeFirst,
                                    deferredUntil: cycle.sleepDeferralDeadline(at: beforeFirst,
                                                                              enabled: true, eligible: true)),
          "pending first thought defers automatic sleep")
    let firstTime = start.addingTimeInterval(240)
    check(cycle.tick(at: firstTime, eligible: true) != nil, "first thought appears")
    cycle.completeDisplay()
    let between = start.addingTimeInterval(301)
    check(!EdenAutoSleep.shouldSleep(inactiveFor: 301, night: night, now: between,
                                    deferredUntil: cycle.sleepDeferralDeadline(at: between,
                                                                              enabled: true, eligible: true)),
          "sleep remains deferred between the two thoughts")
    let secondTime = start.addingTimeInterval(540)
    check(cycle.tick(at: secondTime, eligible: true) != nil, "second thought appears")
    let duringBubble = secondTime.addingTimeInterval(3)
    check(cycle.sleepDeferralDeadline(at: duringBubble, enabled: true, eligible: true) ==
          secondTime.addingTimeInterval(5), "second thought remains visible for four seconds")
    cycle.completeDisplay()
    check(cycle.sleepDeferralDeadline(at: secondTime.addingTimeInterval(4),
                                      enabled: true, eligible: true) == nil &&
          EdenAutoSleep.shouldSleep(inactiveFor: 544, night: night,
                                    now: secondTime.addingTimeInterval(4), deferredUntil: nil),
          "sleep resumes after the second thought closes")
    check(cycle.sleepDeferralDeadline(at: secondTime.addingTimeInterval(4),
                                      enabled: false, eligible: true) == nil,
          "disabling thoughts never defers sleep")
    cycle.restartAfterInteraction()
    check(cycle.thoughtsShown == 0 && cycle.nextDue == nil && cycle.displayDeadline == nil &&
          !EdenAutoSleep.shouldSleep(inactiveFor: 0, night: night,
                                     now: secondTime, deferredUntil: nil),
          "interaction cancels the pending sleep transition")
}
var interruptedCycle = IdleThoughtsScheduler(dialogue: idleDialogue)
_ = interruptedCycle.tick(at: start, eligible: true, firstDelay: { 120 }, secondDelay: { 360 })
check(interruptedCycle.sleepDeferralDeadline(at: start.addingTimeInterval(1),
                                             enabled: true, eligible: false) == nil,
      "ineligible state releases sleep deferral")
check(interruptedCycle.tick(at: start.addingTimeInterval(129), eligible: true) == nil &&
      interruptedCycle.sleepDeferralDeadline(at: start.addingTimeInterval(129),
                                             enabled: true, eligible: true) == nil,
      "missed thoughts do not queue or defer sleep indefinitely")
check(EdenAutoSleep.shouldSleep(inactiveFor: 301, night: false, now: start, deferredUntil: nil) &&
      EdenAutoSleep.shouldSleep(inactiveFor: 61, night: true, now: start, deferredUntil: nil),
      "disabled or missing dialogue preserves original automatic sleep")

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
var thoughtVisual = IdleThoughtThinking()
thoughtVisual.setVisible(true, at: 10)
check(thoughtVisual.isVisible && thoughtVisual.frameAge(at: 10) == 0 &&
      EdenAnimation.select(catTime: 10, sleepAge: nil, thinking: true, asking: false,
                           petting: false, worried: false, happyAge: -1, blinkAge: -1,
                           thinkingAge: thoughtVisual.frameAge(at: 10)) == .init(kind: .thinking, index: 0),
      "an Idle Thought begins on the first Thinking frame")
check(EdenAnimation.select(catTime: 10.35, sleepAge: nil, thinking: true, asking: false,
                           petting: false, worried: false, happyAge: -1, blinkAge: -1,
                           thinkingAge: thoughtVisual.frameAge(at: 10.35)) == .init(kind: .thinking, index: 1),
      "Idle Thought Thinking loops using existing frames")
thoughtVisual.setVisible(false, at: 10.5)
check(!thoughtVisual.isVisible && thoughtVisual.frameAge(at: 10.5) == 0,
      "dismissing or replacing a thought stops its visual state")
thoughtVisual.setVisible(true, at: 12)
check(thoughtVisual.frameAge(at: 12) == 0 &&
      catFrame(12, sleepAge: 0, thinking: true).kind == .sleeping &&
      catFrame(12, thinking: true, asking: true).kind == .idle &&
      catFrame(12, thinking: true, confusedAge: 0.3).kind == .confused,
      "each thought restarts Thinking without overriding sleep, questions or errors")
check(thoughtVisual.shouldRender(realProcessing: false, canDraw: true, petting: false,
                                 waveAge: 10, happyAge: 10) &&
      !thoughtVisual.shouldRender(realProcessing: true, canDraw: true, petting: false,
                                  waveAge: 10, happyAge: 10) &&
      !thoughtVisual.shouldRender(realProcessing: false, canDraw: true, petting: true,
                                  waveAge: 10, happyAge: 10) &&
      !thoughtVisual.shouldRender(realProcessing: false, canDraw: true, petting: false,
                                  waveAge: 0.2, happyAge: 10) &&
      !thoughtVisual.shouldRender(realProcessing: false, canDraw: true, petting: false,
                                  waveAge: 10, happyAge: 0.2),
      "real processing, petting, wave and happy take priority over thought Thinking")
thoughtVisual.setVisible(false, at: 12.5)
check(!thoughtVisual.shouldRender(realProcessing: false, canDraw: true, petting: false,
                                  waveAge: 10, happyAge: 10),
      "dismissed thoughts cannot leave a Thinking frame behind")
check(DesktopActionOutcome.succeeded.combined(with: .succeeded) == .succeeded &&
      DesktopActionOutcome.succeeded.combined(with: .cancelled) == .cancelled &&
      DesktopActionOutcome.cancelled.combined(with: .failed) == .failed,
      "app outcomes keep cancellation separate from failure")
var thinkingHold = ThinkingVisibility()
check(thinkingHold.update(now: 1, phaseTime: 7, requested: true, canDraw: true) &&
      thinkingHold.frameAge(at: 7) == 0,
      "a new processing session begins with the first Thinking frame")
check(thinkingHold.update(now: 1.3, phaseTime: 7.3, requested: false, canDraw: true) &&
      thinkingHold.isHolding(at: 1.3),
      "completed asynchronous work retains visible Thinking briefly")
check(EdenAnimation.select(catTime: 7.31, sleepAge: nil, thinking: true, asking: false,
                           petting: false, worried: false, happyAge: -1, blinkAge: -1,
                           thinkingAge: thinkingHold.frameAge(at: 7.31)) == .init(kind: .thinking, index: 1),
      "Thinking frame clock resets independently of the global animation clock")
check(!thinkingHold.update(now: 1.6, phaseTime: 7.6, requested: false, canDraw: true) &&
      catFrame(7.6, happyAge: 0).kind == .happy,
      "Thinking hold ends before Happy plays")
check(thinkingHold.update(now: 2, phaseTime: 9, requested: true, canDraw: true) &&
      !thinkingHold.update(now: 2.1, phaseTime: 9.1, requested: false, canDraw: false) &&
      !thinkingHold.isHolding(at: 2.1),
      "failure or cancellation clears stale Thinking")
check(catFrame(9.1, thinking: true, confusedAge: 0.3).kind == .confused,
      "Confused supersedes processing on genuine failure")
thinkingHold.reset()
check(!thinkingHold.update(now: 3, phaseTime: 10, requested: false, canDraw: true) &&
      catFrame(10, happyAge: 0).kind == .happy,
      "instant operations can show Happy without a synthetic Thinking delay")
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

func makeApp(in root: URL, file: String, display: String, bundleName: String, id: String,
             flags: [String: Any] = [:], executable: Bool = true) -> URL {
    let app = root.appendingPathComponent(file + ".app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL",
                               "CFBundleName": bundleName, "CFBundleDisplayName": display,
                               "CFBundleExecutable": file]
    flags.forEach { info[$0.key] = $0.value }
    let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try! data.write(to: contents.appendingPathComponent("Info.plist"))
    if executable {
        let bin = contents.appendingPathComponent("MacOS", isDirectory: true)
        try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fileURL = bin.appendingPathComponent(file)
        try! Data("fixture".utf8).write(to: fileURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
    }
    return app
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("eden-launcher-tests-\(UUID().uuidString)")
let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
let petFrame = NSRect(x: 100, y: 20, width: 96, height: 96)
let chatSize = NSSize(width: 340, height: 168)
let defaultPet = PetChatLayout.spawnFrame(size: petFrame.size, primaryVisible: screen,
    savedOrigin: nil, visibleFrames: [screen])
check(defaultPet == NSRect(x: 684, y: 20, width: 96, height: 96),
      "default pet is 20 points from the primary display's visible right and bottom edges")
check(PetChatLayout.chatFrame(pet: defaultPet, size: chatSize, visible: screen).maxX == defaultPet.minX - 8,
      "default chat opens to the left without moving the pet")
check(PetChatLayout.spawnFrame(size: petFrame.size, primaryVisible: screen,
    savedOrigin: petFrame.origin, visibleFrames: [screen]) == petFrame,
      "saved pet position is restored")
check(PetChatLayout.spawnFrame(size: petFrame.size, primaryVisible: screen,
    savedOrigin: NSPoint(x: 900, y: 0), visibleFrames: [screen]) == defaultPet,
      "saved position on a disconnected display uses the primary default")
check(PetChatLayout.spawnFrame(size: petFrame.size, primaryVisible: screen,
    savedOrigin: NSPoint(x: CGFloat.nan, y: 0), visibleFrames: [screen]) == defaultPet,
      "invalid saved coordinates use the primary default")
let dockVisible = NSRect(x: 12, y: 64, width: 760, height: 500)
check(PetChatLayout.spawnFrame(size: petFrame.size, primaryVisible: dockVisible,
    savedOrigin: nil, visibleFrames: [dockVisible]) == NSRect(x: 656, y: 84, width: 96, height: 96),
      "default spawn respects an offset visible frame for Dock and menu bar")
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
check(PetChatLayout.spawnFrame(size: petFrame.size, primaryVisible: screen,
    savedOrigin: secondPet.origin, visibleFrames: [screen, secondScreen]) == secondPet,
      "saved position on another connected display is restored")
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
      QuickChatLayout.height(for: .selecting(.open), hasBadges: false) == 520 &&
      QuickChatLayout.height(for: .home, hasBadges: true) == 295,
      "guided actions and badges retain enough vertical space")
check(QuickChatLayout.appRowHeight == 46 && QuickChatLayout.appRowGap == 6,
      "application picker rows have a consistent compact size and gap")
check(QuickChatLayout.gridColumns == 4 && QuickChatLayout.gridTileSize == NSSize(width: 67, height: 104) &&
      QuickChatLayout.gridRows(for: 9) == 3, "Open picker uses four compact columns")
let firstGridTile = QuickChatLayout.gridTileFrame(index: 0, firstTop: 400)
let fourthGridTile = QuickChatLayout.gridTileFrame(index: 3, firstTop: 400)
let fifthGridTile = QuickChatLayout.gridTileFrame(index: 4, firstTop: 400)
check(firstGridTile.minX == 8 && fourthGridTile.maxX == 300 &&
      fifthGridTile.minX == 8 && firstGridTile.minY - fifthGridTile.minY == 112,
      "Open grid fits the chat width and spaces rows consistently")
let longTileTitle = QuickAppTile.twoLineTitle("Adobe Photoshop Very Long Application Name")
check(longTileTitle.split(separator: "\n").count == 2 && longTileTitle.hasSuffix("…"),
      "long application labels use two word-aware lines and an ellipsis")
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
let spotifyApp = InstalledApplication(url: spotifyURL)!
let safariApp = InstalledApplication(url: safariURL)!
let helperURL = makeApp(in: standard, file: "Sync Agent", display: "Sync Agent", bundleName: "Sync Agent",
                        id: "example.sync", flags: ["LSUIElement": true])
let missingBinaryURL = makeApp(in: standard, file: "Broken App", display: "Broken App", bundleName: "Broken App",
                               id: "example.broken", executable: false)
let helperApp = InstalledApplication(url: helperURL)!
let missingBinaryApp = InstalledApplication(url: missingBinaryURL)!
check(spotifyApp.isLaunchable && spotifyApp.isDefaultGridApp && !helperApp.isDefaultGridApp &&
      !missingBinaryApp.isLaunchable, "Open filter uses executable and bundle metadata")
check(InstalledApplication.isSystemUtilityPath("/System/Applications/Utilities/Terminal.app") &&
      !InstalledApplication.isSystemUtilityPath("/System/Applications/Photos.app") &&
      !InstalledApplication.isSystemUtilityPath(safariURL.path),
      "system utilities are distinct from normal and outside-Applications apps")
let gridRunning: [(app: InstalledApplication, pid: pid_t)] = [(spotifyApp, 101), (safariApp, 102)]
let openGrid = QuickAppGridData.targets(for: .open,
    installed: [spotifyApp, safariApp, helperApp, missingBinaryApp],
    running: gridRunning, recentPIDs: [102], search: "")
check(openGrid.count == 2 && openGrid.allSatisfy { $0.pid == nil } &&
      openGrid.map { $0.app.displayName } == ["Safari", "Spotify"],
      "Open grid uses the installed catalog and alphabetical order")
let systemGrid = QuickAppGridData.targets(for: .open,
    installed: [spotifyApp, helperApp, missingBinaryApp], running: [], recentPIDs: [], search: "",
    showSystemApps: true)
check(systemGrid.map { $0.app.displayName } == ["Spotify", "Sync Agent"],
      "Show System Apps reveals launchable helpers but keeps broken bundles hidden")
let switchGrid = QuickAppGridData.targets(for: .switchTo, installed: [spotifyApp, safariApp],
    running: [(spotifyApp, 101)], recentPIDs: [101], search: "")
check(switchGrid.count == 1 && switchGrid[0].app == spotifyApp && switchGrid[0].pid == 101,
      "Switch grid uses running apps only and keeps the destination PID")
check(QuickAppGridData.targets(for: .switchTo, installed: [], running: gridRunning,
    recentPIDs: [102], search: "").map { $0.app.displayName } == ["Safari", "Spotify"],
      "Switch grid uses observed activation order")
check(QuickAppGridData.targets(for: .open, installed: [spotifyApp, safariApp], running: [],
    recentPIDs: [], search: "spot").map { $0.app.displayName } == ["Spotify"],
      "grid search filters the selected data source")

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
quick.begin(.switchTo)
quick.selectWindow()
check(quick.state == .selectingWindow, "Switch can advance to window selection")
quick.back()
check(quick.state == .selecting(.switchTo), "Back from windows returns to running apps")
quick.selectWindow()
quick.cancel()
check(quick.state == .home, "Cancel from windows returns home")
quick.begin(.open)
quick.selectWindow()
check(quick.state == .selecting(.open), "other Quick Actions cannot enter window selection")
check(QuickWindowSwitcher.label("", index: 1, minimized: false) == "Untitled window 2" &&
      QuickWindowSwitcher.label("  Report  ", index: 0, minimized: true) == "Report · Minimized",
      "window labels handle untitled and minimised windows without PIDs")
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
check(apps.count == 9, "validated app bundle discovery remains unchanged by the Open grid filter")
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

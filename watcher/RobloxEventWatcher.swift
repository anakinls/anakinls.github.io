import Foundation
import Vision
import ScreenCaptureKit
import CoreGraphics
import AppKit
import Dispatch

// ============================================================
// CONFIG
// ============================================================

// Gelesen wird nur die Event-Zeile oben - sie ist die einzige, die
// sich nicht ausrechnen lässt.
//
// Die Werte passen zu einem vergrößerten HUD: Name und Zeit liegen
// dann bei y 0.863-0.894, die Junkyard-Zeile beginnt bei 0.903.
// Der Crop ist bewusst großzügiger als nötig - ein hineinragender
// Streifen der Zeile darunter stört nicht, weil dort "35m 44s"
// steht und nur das M:SS-Format akzeptiert wird. Ein abgeschnittener
// Name kostet dagegen den Namen.
//
// Zum Nachjustieren ohne Neubau:
//   WATCHER_CROP="0.86,0.845,0.14,0.068"   (x, y, Breite, Höhe)
let cropValues: [CGFloat]? = {

    guard let raw =
        ProcessInfo.processInfo.environment["WATCHER_CROP"]
    else {
        return nil
    }

    var values: [CGFloat] = []

    for part in raw.split(separator: ",") {

        let trimmed = part.trimmingCharacters(in: .whitespaces)

        guard let number = Double(trimmed) else {
            return nil
        }

        values.append(CGFloat(number))
    }

    return values.count == 4 ? values : nil
}()

let cropXFraction: CGFloat = cropValues?[0] ?? 0.86
let cropYFraction: CGFloat = cropValues?[1] ?? 0.845
let cropWidthFraction: CGFloat = cropValues?[2] ?? 0.14
let cropHeightFraction: CGFloat = cropValues?[3] ?? 0.068

// Junkyard und Blitz spawnen jede Stunde zur selben Minute, :15 und
// :45. Das ist Rechnen, kein Lesen - und nichts, was OCR falsch
// machen könnte.
let junkyardMinute = 15
let blitzMinute = 45

// Die HUD-Schrift ist klein - Vision liest sie deutlich besser,
// wenn der Ausschnitt vorher hochskaliert wird.
let ocrUpscale = 6

// Takt der Hauptschleife. Daran hängt, wie schnell die Discord-
// Nachricht nachgezogen wird - nicht, wie oft OCR läuft.
let tickSeconds: UInt64 = 1

// OCR-Abgleich. Zwischen zwei Lesungen zählt die lokale Uhr
// weiter, deshalb reicht ein Abgleich alle paar Sekunden.
let syncInterval: TimeInterval = 10

// Kurz vor Ablauf dichter prüfen, damit der Wechsel auf das
// nächste Event schnell auffällt.
let syncIntervalNearEnd: TimeInterval = 3
let nearEndSeconds = 20

// Höchstens alle fünf Sekunden editieren. Die angezeigte Zahl
// hinkt damit bis zu fünf Sekunden hinterher, dafür bleibt die
// Zahl der Webhook-Edits pro Zyklus niedrig.
let editGap: TimeInterval = 5

// Weicht die OCR-Lesung um mehr als das vom lokal gezählten Wert
// ab, gilt die Lesung.
let resyncToleranceSeconds = 2

// Ab dieser Abweichung im Ablaufzeitpunkt ist es ein neuer Zyklus
// und damit ein neues Event - auch wenn es wieder dasselbe heißt.
let newCycleToleranceSeconds: TimeInterval = 10

// Rolle, die gepingt wird. Leer lassen = kein Ping.
let pingRoleID = "1555684515140341903"

// Jeder Zyklus bekommt eine eigene Nachricht. Gepingt wird aber
// nur bei diesen Events - alles andere wird still gepostet.
// Alle Namen eintragen = jedes Mal ein Ping.
let alertEvents: Set<String> = [
    "SECRET",
    "OG",
    "MYTHIC",
    "LEGENDARY",
    "RAINBOW"
]

// Auch pingen, wenn der Name nicht lesbar war.
let alertUnknownEvent = true

// Das Spiel läuft auf Deutsch und übersetzt einen Teil der Namen
// ("Mythisch"), einen Teil nicht ("Rainbow"). Links der kanonische
// Name, rechts alles, was im HUD stehen kann.
let eventAliases: [String: [String]] = [
    "ROADWAY":   ["ROADWAY", "FAHRBAHN"],
    "DRAGRACE":  ["DRAGRACE", "DRAG RACE", "DRAGRENNEN"],
    "GOLD":      ["GOLD", "GOLDEN"],
    "DIAMOND":   ["DIAMOND", "DIAMANT"],
    "RAINBOW":   ["RAINBOW", "REGENBOGEN"],
    "MYTHIC":    ["MYTHIC", "MYTHISCH"],
    "LEGENDARY": ["LEGENDARY", "LEGENDÄR", "LEGENDAER", "LEGENDAR"],
    "SECRET":    ["SECRET", "GEHEIM", "GEHEIMNIS"],
    "OG":        ["OG"]
]

// Alle Schreibweisen, längste zuerst: so gewinnt "GOLDEN" vor
// "GOLD" und "OG" kann nicht in einem längeren Wort zuschlagen.
//
// Ausgeschrieben statt als flatMap/map-Kette: der Type-Checker
// braucht für die Kette mit benannten Tupeln zu lange und bricht ab.
let eventSpellings: [(canonical: String, spelling: String)] = {

    var pairs: [(canonical: String, spelling: String)] = []

    for (canonical, spellings) in eventAliases {
        for spelling in spellings {
            pairs.append((canonical: canonical, spelling: spelling))
        }
    }

    pairs.sort { lhs, rhs in

        if lhs.spelling.count != rhs.spelling.count {
            return lhs.spelling.count > rhs.spelling.count
        }

        return lhs.spelling < rhs.spelling
    }

    return pairs
}()

// Landet auf dem Schreibtisch, damit man es ohne Umweg über den
// Finder findet und weiterschicken kann.
let debugScreenshotPath =
    (NSHomeDirectory() as NSString)
        .appendingPathComponent("Desktop/roblox-debug.png")

// ============================================================
// CORE GRAPHICS / APP
// ============================================================

_ = CGMainDisplayID()

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let debugEnabled =
    ProcessInfo.processInfo
        .environment["WATCHER_DEBUG"] == "1"

// Beim Start einmal an Discord schicken, um den Webhook zu prüfen.
let testEnabled =
    ProcessInfo.processInfo
        .environment["WATCHER_TEST"] == "1"

// ============================================================
// DISCORD CONFIG
// ============================================================

// Der Webhook wird aus der Umgebungsvariable DISCORD_WEBHOOK_URL
// gelesen, damit er NIE in diesem öffentlichen Repository landet.
//
//   export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
//   swift watcher/RobloxEventWatcher.swift
let webhookURLString =
    ProcessInfo.processInfo
        .environment["DISCORD_WEBHOOK_URL"] ?? ""

guard !webhookURLString.isEmpty,
      let webhookURL = URL(string: webhookURLString),
      webhookURL.host == "discord.com"
else {
    print("❌ Discord Webhook URL ist ungültig oder nicht gesetzt.")
    print("➡️ export DISCORD_WEBHOOK_URL=\"https://discord.com/api/webhooks/...\"")
    exit(1)
}

// ============================================================
// STATE
// ============================================================

// Die laufende Discord-Nachricht. Eine pro Event-Zyklus.
final class LiveMessage {
    let id: String
    let cycleDeadline: Date

    var event: String?
    var lastShownSeconds: Int
    var lastEditAt: Date
    var finished: Bool

    var title: String {
        event ?? "EVENT (Name nicht lesbar)"
    }

    init(
        id: String,
        cycleDeadline: Date,
        event: String?,
        lastShownSeconds: Int
    ) {
        self.id = id
        self.cycleDeadline = cycleDeadline
        self.event = event
        self.lastShownSeconds = lastShownSeconds
        self.lastEditAt = Date()
        self.finished = false
    }
}

final class WatcherState {
    var live: LiveMessage?

    // Ablaufzeitpunkt des laufenden Events. Die Restzeit kommt
    // danach aus der Uhr, nicht aus dem nächsten Screenshot.
    var deadline: Date?
    var event: String?

    var nextSync = Date()

    // Nach einem 429 vor diesem Zeitpunkt nichts mehr senden.
    var discordBlockedUntil: Date?

    var remaining: Int {

        guard let deadline else {
            return 0
        }

        return max(0, Int(deadline.timeIntervalSinceNow.rounded()))
    }
}

let state = WatcherState()

// ============================================================
// DARSTELLUNG
// ============================================================

func emoji(for event: String?) -> String {

    switch event {
    case "RAINBOW":   return "🌈"
    case "DIAMOND":   return "💎"
    case "GOLD":      return "🪙"
    case "MYTHIC":    return "🔮"
    case "LEGENDARY": return "🏆"
    case "SECRET":    return "🔴"
    case "OG":        return "👑"
    case "ROADWAY":   return "🛣️"
    case "DRAGRACE":  return "🏁"
    default:          return "🚨"
    }
}

func title(for event: String?) -> String {
    event ?? "EVENT (Name nicht lesbar)"
}

// Wie im Spiel: M:SS, auch unter einer Minute.
func formatTimer(_ totalSeconds: Int) -> String {

    let safe = max(0, totalSeconds)

    return String(
        format: "%d:%02d",
        safe / 60,
        safe % 60
    )
}

// Der Blitz steht im Spiel als "42m 47s" da, nicht als Uhrzeit.
func formatUnits(_ totalSeconds: Int) -> String {

    let safe = max(0, totalSeconds)

    let hours = safe / 3600
    let minutes = (safe % 3600) / 60
    let seconds = safe % 60

    if hours > 0 {
        return "\(hours)h \(minutes)m \(seconds)s"
    }

    if minutes > 0 {
        return "\(minutes)m \(seconds)s"
    }

    return "\(seconds)s"
}

// Untereinander, eine Zeile pro Sache - Symbol, Name, Zeit:
//
//   @Rolle
//   🏁 DRAGRACE in 1:02
//   ⛏️ Junkyard in 46m 2s
//   ⚡ Blitz in 16m 2s
func discordContent(
    event: String?,
    seconds: Int,
    junkyardSeconds: Int?,
    blitzSeconds: Int?,
    mention: Bool
) -> String {

    var lines: [String] = []

    if mention, !pingRoleID.isEmpty {
        lines.append("<@&\(pingRoleID)>")
    }

    if seconds <= 0 {
        lines.append(
            "\(emoji(for: event)) **\(title(for: event)) ist jetzt da!**"
        )
    } else {
        lines.append(
            "\(emoji(for: event)) **\(title(for: event)) in \(formatTimer(seconds))**"
        )
    }

    if let junkyardSeconds {
        lines.append("⛏️ Junkyard **in \(formatUnits(junkyardSeconds))**")
    }

    if let blitzSeconds {
        lines.append("⚡ Blitz **in \(formatUnits(blitzSeconds))**")
    }

    return lines.joined(separator: "\n")
}

// ============================================================
// DISCORD RATE LIMIT
// ============================================================

func discordIsBlocked() -> Bool {

    guard let blockedUntil = state.discordBlockedUntil else {
        return false
    }

    if Date() < blockedUntil {
        return true
    }

    state.discordBlockedUntil = nil

    return false
}

func applyRateLimit(
    data: Data,
    fallbackSeconds: Double
) {

    var retryAfter = fallbackSeconds

    if let json = try? JSONSerialization.jsonObject(
        with: data,
        options: []
    ) as? [String: Any],
       let value = json["retry_after"] as? Double {

        retryAfter = value
    }

    state.discordBlockedUntil =
        Date().addingTimeInterval(retryAfter)

    print(
        "⏸️ Discord Rate-Limit: pausiere "
        + String(format: "%.1f", retryAfter)
        + "s"
    )
}

// ============================================================
// DISCORD SEND
// ============================================================

func sendDiscordMessage(content: String) async -> String? {

    if discordIsBlocked() {
        print("⏸️ Discord pausiert - Nachricht übersprungen.")
        return nil
    }

    // Nur die konfigurierte Rolle darf benachrichtigt werden,
    // ausdrücklich nicht @everyone.
    let allowedMentions: [String: Any] =
        pingRoleID.isEmpty
            ? ["parse": []]
            : ["parse": [], "roles": [pingRoleID]]

    let payload: [String: Any] = [
        "username": "Roblox Event Watcher",
        "content": content,
        "allowed_mentions": allowedMentions
    ]

    guard let body = try? JSONSerialization.data(
        withJSONObject: payload,
        options: []
    ) else {

        print("❌ Discord JSON Fehler.")
        return nil
    }

    guard var components = URLComponents(
        url: webhookURL,
        resolvingAgainstBaseURL: false
    ) else {

        print("❌ Discord Webhook URL ungültig.")
        return nil
    }

    var queryItems = components.queryItems ?? []

    queryItems.append(
        URLQueryItem(name: "wait", value: "true")
    )

    components.queryItems = queryItems

    guard let requestURL = components.url else {
        print("❌ Discord Request-URL ungültig.")
        return nil
    }

    var request = URLRequest(url: requestURL)

    request.httpMethod = "POST"

    request.setValue(
        "application/json",
        forHTTPHeaderField: "Content-Type"
    )

    request.timeoutInterval = 15
    request.httpBody = body

    do {

        let (data, response) =
            try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse
        else {
            print("❌ Ungültige Discord-Antwort.")
            return nil
        }

        if httpResponse.statusCode == 429 {
            applyRateLimit(data: data, fallbackSeconds: 5)
            return nil
        }

        guard (200...299).contains(httpResponse.statusCode) else {

            print("❌ Discord HTTP \(httpResponse.statusCode)")

            if let responseText = String(data: data, encoding: .utf8) {
                print("Discord Antwort: \(responseText)")
            }

            return nil
        }

        guard
            let json = try? JSONSerialization.jsonObject(
                with: data,
                options: []
            ) as? [String: Any],
            let messageID = json["id"] as? String
        else {
            print("❌ Discord Message-ID konnte nicht gelesen werden.")
            return nil
        }

        return messageID

    } catch {

        print("❌ Discord Fehler: \(error.localizedDescription)")
        return nil
    }
}

// ============================================================
// DISCORD UPDATE
// ============================================================

func updateDiscordMessage(
    messageID: String,
    content: String
) async -> Bool {

    if discordIsBlocked() {
        return false
    }

    let payload: [String: Any] = [
        "content": content,
        "allowed_mentions": ["parse": []]
    ]

    guard let body = try? JSONSerialization.data(
        withJSONObject: payload,
        options: []
    ) else {
        print("❌ Countdown JSON Fehler.")
        return false
    }

    guard let messageURL = URL(
        string:
            webhookURL.absoluteString
            + "/messages/"
            + messageID
    ) else {
        print("❌ Discord Message-URL ungültig.")
        return false
    }

    var request = URLRequest(url: messageURL)

    request.httpMethod = "PATCH"

    request.setValue(
        "application/json",
        forHTTPHeaderField: "Content-Type"
    )

    request.timeoutInterval = 15
    request.httpBody = body

    do {

        let (data, response) =
            try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse
        else {
            print("❌ Ungültige Discord Countdown-Antwort.")
            return false
        }

        if httpResponse.statusCode == 429 {
            applyRateLimit(data: data, fallbackSeconds: 2)
            return false
        }

        if (200...299).contains(httpResponse.statusCode) {
            return true
        }

        print("❌ Discord Countdown HTTP \(httpResponse.statusCode)")

        if let responseText = String(data: data, encoding: .utf8) {
            print("Discord Antwort: \(responseText)")
        }

        return false

    } catch {

        print("❌ Discord Countdown Fehler: \(error.localizedDescription)")
        return false
    }
}

// ============================================================
// FIND ROBLOX WINDOW
// ============================================================

func findRobloxWindow() async throws -> SCWindow? {

    let content =
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

    // 1. Priorität: normale Haupt-Roblox-Instanz.
    if let mainRoblox = content.windows.first(where: { window in

        let bundleID =
            window.owningApplication?.bundleIdentifier ?? ""

        return bundleID == "com.roblox.RobloxPlayer"
            && window.frame.width > 1000
            && window.frame.height > 700
    }) {
        return mainRoblox
    }

    // 2. Fallback: größtes Roblox-Fenster.
    let robloxWindows = content.windows.filter { window in

        let appName =
            window.owningApplication?.applicationName ?? ""

        let bundleID =
            window.owningApplication?.bundleIdentifier ?? ""

        let isRoblox =
            appName.localizedCaseInsensitiveContains("Roblox")
            || bundleID.localizedCaseInsensitiveContains("roblox")

        let validSize =
            window.frame.width > 500
            && window.frame.height > 300

        return isRoblox && validSize
    }

    guard !robloxWindows.isEmpty else {
        return nil
    }

    return robloxWindows.max {
        ($0.frame.width * $0.frame.height)
            < ($1.frame.width * $1.frame.height)
    }
}

// ============================================================
// SCREENSHOT
// ============================================================

func captureWindow(_ window: SCWindow) async throws -> CGImage {

    let filter = SCContentFilter(
        desktopIndependentWindow: window
    )

    let configuration = SCStreamConfiguration()

    configuration.width = max(1, Int(window.frame.width))
    configuration.height = max(1, Int(window.frame.height))

    configuration.scalesToFit = false
    configuration.showsCursor = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    return try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
    )
}

// Die Event-Zeile aus dem Vollbild schneiden und für OCR
// vergrößern.
func cropEventRow(_ fullImage: CGImage) throws -> CGImage {

    let width = CGFloat(fullImage.width)
    let height = CGFloat(fullImage.height)

    let cropRect = CGRect(
        x: width * cropXFraction,
        y: height * cropYFraction,
        width: width * cropWidthFraction,
        height: height * cropHeightFraction
    ).integral

    guard let croppedImage = fullImage.cropping(to: cropRect)
    else {
        throw NSError(
            domain: "RobloxWatcher",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Event-Zeile konnte nicht zugeschnitten werden."
            ]
        )
    }

    let enlargedWidth = croppedImage.width * ocrUpscale
    let enlargedHeight = croppedImage.height * ocrUpscale

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
        data: nil,
        width: enlargedWidth,
        height: enlargedHeight,
        bitsPerComponent: 8,
        bytesPerRow: enlargedWidth * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return croppedImage
    }

    context.interpolationQuality = .high

    context.draw(
        croppedImage,
        in: CGRect(
            x: 0,
            y: 0,
            width: enlargedWidth,
            height: enlargedHeight
        )
    )

    return context.makeImage() ?? croppedImage
}

// ============================================================
// DEBUG SCREENSHOT
// ============================================================

func saveDebugScreenshot(_ image: CGImage) {

    let bitmapRep = NSBitmapImageRep(cgImage: image)

    guard let pngData = bitmapRep.representation(
        using: .png,
        properties: [:]
    ) else {
        print("❌ PNG konnte nicht erstellt werden.")
        return
    }

    do {
        try pngData.write(
            to: URL(fileURLWithPath: debugScreenshotPath)
        )
        print("📸 Debug-Screenshot: \(debugScreenshotPath)")
    } catch {
        print("❌ Screenshot konnte nicht gespeichert werden: \(error)")
    }
}

// ============================================================
// OCR
// ============================================================

// Vision liefert mehrere Lesarten pro Zeile. Die beste ist oft
// verstümmelt, während die zweite oder dritte den Namen trifft.
struct OCRLine {
    let text: String
    let alternatives: [String]
}

func recognizeLines(
    from image: CGImage,
    languageCorrection: Bool = false
) throws -> [OCRLine] {

    var lines: [OCRLine] = []

    let request = VNRecognizeTextRequest { request, error in

        if let error {
            print("❌ Vision OCR Fehler: \(error.localizedDescription)")
            return
        }

        guard let observations =
            request.results as? [VNRecognizedTextObservation]
        else {
            return
        }

        for observation in observations {

            let candidates = observation.topCandidates(3)

            guard let best = candidates.first else {
                continue
            }

            lines.append(
                OCRLine(
                    text: best.string,
                    alternatives: candidates.map { $0.string }
                )
            )
        }
    }

    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = languageCorrection
    request.recognitionLanguages = ["en-US", "de-DE"]

    // Die HUD-Schrift ist klein; Standard wäre 1/32 der Bildhöhe.
    request.minimumTextHeight = 0.02

    if languageCorrection {
        request.customWords = eventSpellings.map { $0.spelling }
    }

    let handler = VNImageRequestHandler(
        cgImage: image,
        orientation: .up,
        options: [:]
    )

    try handler.perform([request])

    return lines
}

// ============================================================
// LEVENSHTEIN
// ============================================================

func levenshteinDistance(_ a: String, _ b: String) -> Int {

    let aChars = Array(a)
    let bChars = Array(b)

    if aChars.isEmpty {
        return bChars.count
    }

    if bChars.isEmpty {
        return aChars.count
    }

    var previous = Array(0...bChars.count)

    for i in 1...aChars.count {

        var current = [i]

        for j in 1...bChars.count {

            let insertion = current[j - 1] + 1
            let deletion = previous[j] + 1

            let substitution =
                previous[j - 1]
                + (aChars[i - 1] == bChars[j - 1] ? 0 : 1)

            current.append(
                min(insertion, deletion, substitution)
            )
        }

        previous = current
    }

    return previous[bChars.count]
}

// ============================================================
// EVENT DETECTION
// ============================================================

// Kurze Namen vertragen keine Toleranz: "OG" hat zu fast jedem
// Zweibuchstaber Distanz 2.
func allowedDistance(for spelling: String) -> Int {

    switch spelling.count {
    case 0...3: return 0
    case 4...6: return 1
    default:    return 2
    }
}

func detectEvent(in line: String) -> String? {

    let upper = line.uppercased()

    for entry in eventSpellings where upper.contains(entry.spelling) {
        return entry.canonical
    }

    let words = upper
        .components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        .filter { !$0.isEmpty }

    for word in words {
        for entry in eventSpellings
            where levenshteinDistance(word, entry.spelling)
                <= allowedDistance(for: entry.spelling) {

            return entry.canonical
        }
    }

    return nil
}

func detectEvent(in line: OCRLine) -> String? {

    for candidate in line.alternatives {
        if let event = detectEvent(in: candidate) {
            return event
        }
    }

    return nil
}

// ============================================================
// TIMER
// ============================================================

// Die Event-Zeile zählt immer als "in 1:36". Junkyard und Blitz
// benutzen "in 51m 36s" - deshalb wird nur das Uhrzeit-Format
// akzeptiert. Rutscht ein Stück der Zeile darunter in den Crop,
// fällt es damit von selbst raus.
func parseClockTimer(from line: String) -> Int? {

    let cleaned = line
        .uppercased()
        .replacingOccurrences(of: "O", with: "0")
        .replacingOccurrences(of: "I", with: "1")
        .replacingOccurrences(of: "L", with: "1")
        .replacingOccurrences(of: ";", with: ":")

    // Ein "m" oder "s" hinter einer Zahl heißt: andere Zeile.
    if cleaned.range(
        of: #"\d\s*[MS]"#,
        options: .regularExpression
    ) != nil {
        return nil
    }

    let pattern = #"(?<!\d)(\d{1,2}):(\d{2})(?!\d)"#

    guard
        let regex = try? NSRegularExpression(pattern: pattern)
    else {
        return nil
    }

    let range = NSRange(
        cleaned.startIndex..<cleaned.endIndex,
        in: cleaned
    )

    guard let match = regex.firstMatch(in: cleaned, range: range)
    else {
        return nil
    }

    guard
        let minuteRange = Range(match.range(at: 1), in: cleaned),
        let secondRange = Range(match.range(at: 2), in: cleaned),
        let minutes = Int(cleaned[minuteRange]),
        let seconds = Int(cleaned[secondRange]),
        seconds < 60
    else {
        return nil
    }

    return minutes * 60 + seconds
}

// ============================================================
// ZEITPLAN
// ============================================================

// Sekunden bis zur nächsten vollen Minute X der Stunde.
// Steht die Uhr genau darauf, ist der Spawn gerade durch und der
// nächste kommt in einer Stunde.
func secondsUntil(minute targetMinute: Int) -> Int {

    let parts = Calendar.current.dateComponents(
        [.minute, .second],
        from: Date()
    )

    let elapsed = (parts.minute ?? 0) * 60 + (parts.second ?? 0)
    let target = targetMinute * 60

    let delta = target - elapsed

    return delta > 0 ? delta : delta + 3600
}

// Beide spawnen jede Stunde zur selben Minute - dafür braucht es
// keinen Screenshot.
func junkyardRemaining() -> Int {
    secondsUntil(minute: junkyardMinute)
}

func blitzRemaining() -> Int {
    secondsUntil(minute: blitzMinute)
}

// ROADWAY startet um :55, DRAGRACE um :25 - jeweils fünf Minuten
// vor der vollen bzw. halben Stunde. Wenn OCR den Namen nicht
// liest, lässt sich das aus der Uhrzeit ableiten, auf die der
// Countdown zeigt. Die Rarity-Events auf den übrigen
// 5-Minuten-Marken rotieren in unbekannter Reihenfolge und
// bleiben deshalb offen.
func scheduledEvent(inSeconds seconds: Int) -> String? {

    let target = Date().addingTimeInterval(TimeInterval(seconds))

    let minute = Calendar.current.component(.minute, from: target)

    // Eine Minute Toleranz, der Countdown ist nie exakt synchron.
    switch minute {
    case 54, 55: return "ROADWAY"
    case 24, 25: return "DRAGRACE"
    default:     return nil
    }
}

// ============================================================
// LESUNG
// ============================================================

struct EventReading {
    var event: String?
    var seconds: Int?
}

func parseEventRow(lines: [OCRLine]) -> EventReading {

    var reading = EventReading()

    for line in lines {

        // Name und Zeit stehen meist in zwei Zeilen, gelegentlich
        // fasst Vision sie zusammen - deshalb beides prüfen.
        if reading.event == nil,
           let event = detectEvent(in: line) {
            reading.event = event
        }

        if reading.seconds == nil,
           let seconds = parseClockTimer(from: line.text) {
            reading.seconds = seconds
        }
    }

    return reading
}

// ============================================================
// NACHRICHT
// ============================================================

// Letztes Update auf die laufende Nachricht, bevor sie liegen
// bleibt und die nächste anfängt.
func finishLiveMessage() async {

    guard let live = state.live, !live.finished else {
        return
    }

    _ = await updateDiscordMessage(
        messageID: live.id,
        content: discordContent(
            event: live.event,
            seconds: 0,
            junkyardSeconds: junkyardRemaining(),
            blitzSeconds: blitzRemaining(),
            mention: false
        )
    )

    live.finished = true
}

func startNewMessage(
    event: String?,
    deadline: Date,
    seconds: Int
) async {

    // Die alte Nachricht sauber abschließen.
    await finishLiveMessage()

    let shouldPing =
        event.map { alertEvents.contains($0) } ?? alertUnknownEvent

    print("")
    print(
        "🚨 \(title(for: event)) in \(formatTimer(seconds))"
        + (shouldPing ? " - neue Nachricht mit Ping." : " - neue Nachricht.")
    )
    print("")

    guard let messageID = await sendDiscordMessage(
        content: discordContent(
            event: event,
            seconds: seconds,
            junkyardSeconds: junkyardRemaining(),
            blitzSeconds: blitzRemaining(),
            mention: shouldPing
        )
    ) else {
        return
    }

    state.live = LiveMessage(
        id: messageID,
        cycleDeadline: deadline,
        event: event,
        lastShownSeconds: seconds
    )
}

// Zieht die laufende Nachricht nach. Braucht weder Screenshot
// noch OCR, nur die Uhr.
func tickCountdown() async {

    guard let live = state.live,
          !live.finished,
          state.deadline != nil
    else {
        return
    }

    let seconds = state.remaining

    if seconds <= 0 {

        _ = await updateDiscordMessage(
            messageID: live.id,
            content: discordContent(
                event: state.event,
                seconds: 0,
                junkyardSeconds: junkyardRemaining(),
            blitzSeconds: blitzRemaining(),
                mention: false
            )
        )

        print("🎉 \(live.title) ist da.")

        live.finished = true

        return
    }

    guard live.lastShownSeconds != seconds else {
        return
    }

    guard Date().timeIntervalSince(live.lastEditAt) >= editGap
    else {
        return
    }

    let success = await updateDiscordMessage(
        messageID: live.id,
        content: discordContent(
            event: state.event,
            seconds: seconds,
            junkyardSeconds: junkyardRemaining(),
            blitzSeconds: blitzRemaining(),
            mention: false
        )
    )

    if success {
        live.lastShownSeconds = seconds
        live.lastEditAt = Date()
    }
}

// ============================================================
// ONE SYNC
// ============================================================

func performSync() async {

    do {

        guard let window = try await findRobloxWindow() else {
            print("⚠️ Roblox-Fenster nicht gefunden.")
            return
        }

        let fullImage = try await captureWindow(window)

        let screenshot = try cropEventRow(fullImage)

        if debugEnabled {
            saveDebugScreenshot(screenshot)
        }

        let lines = try recognizeLines(from: screenshot)

        if debugEnabled {
            print("📝 OCR:")
            for line in lines {
                print("   \(line.text)")
            }
        }

        var reading = parseEventRow(lines: lines)

        // Zeit steht, Name nicht: zweiter Versuch mit
        // Sprachkorrektur und den Namen als customWords.
        if reading.event == nil, reading.seconds != nil {

            let retry = try recognizeLines(
                from: screenshot,
                languageCorrection: true
            )

            if debugEnabled {
                print("📝 OCR (2. Versuch):")
                for line in retry {
                    print("   \(line.text)")
                }
            }

            for line in retry {
                if let event = detectEvent(in: line) {
                    reading.event = event
                    break
                }
            }
        }

        guard let seconds = reading.seconds else {
            print("ℹ️ Keine Zeit in der Event-Zeile gelesen.")
            return
        }

        // Name unlesbar? Um :55 und :25 steht fest, was kommt.
        if reading.event == nil {

            reading.event = scheduledEvent(inSeconds: seconds)

            if let derived = reading.event {
                print("🗓️ Name aus Zeitplan abgeleitet: \(derived)")
            }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(seconds))

        print(
            "🎯 \(reading.event ?? "?") \(formatTimer(seconds))"
        )

        // ----------------------------------------------------
        // NEUER ZYKLUS?
        // ----------------------------------------------------
        //
        // Nicht am Namen festmachen: dasselbe Event kann zweimal
        // hintereinander kommen. Maßgeblich ist, ob der
        // Ablaufzeitpunkt deutlich nach hinten gesprungen ist.

        let isNewCycle: Bool

        if let previous = state.deadline {
            isNewCycle =
                deadline.timeIntervalSince(previous)
                    > newCycleToleranceSeconds
        } else {
            // Erster Durchlauf nach dem Start.
            isNewCycle = true
        }

        if isNewCycle {

            state.deadline = deadline
            state.event = reading.event

            await startNewMessage(
                event: reading.event,
                deadline: deadline,
                seconds: seconds
            )

            return
        }

        // ----------------------------------------------------
        // ABGLEICH
        // ----------------------------------------------------

        if abs(state.remaining - seconds) > resyncToleranceSeconds {
            state.deadline = deadline
        }

        // Name erst jetzt lesbar geworden.
        if state.event == nil, let event = reading.event {

            state.event = event

            if let live = state.live, !live.finished {
                live.event = event
                live.lastShownSeconds = -1

                print("🔤 Name nachgetragen: \(event)")
            }
        }

    } catch {
        print("❌ Sync fehlgeschlagen: \(error.localizedDescription)")
    }
}

// ============================================================
// START
// ============================================================

print("")
print("==============================================")
print("       ROBLOX EVENT WATCHER")
print("==============================================")
print("")
print("Verfolgt: nur die Event-Zeile oben")
print("Junkyard: gerechnet, jede Stunde :\(junkyardMinute)")
print("Blitz: gerechnet, jede Stunde :\(blitzMinute)")
print("Ping-Rolle: \(pingRoleID.isEmpty ? "kein Ping" : pingRoleID)")
print("Ping bei: \(alertEvents.sorted().joined(separator: ", "))")
print("Unbekannter Name: \(alertUnknownEvent ? "pingt trotzdem" : "kein Ping")")
print("")
print("Erste Nachricht beim Start, danach bei jedem Eventwechsel.")
print("")
print("Capture: ScreenCaptureKit")
print("OCR: Apple Vision")

if debugEnabled {
    print("")
    print("🐞 Debug an - OCR-Zeilen und \(debugScreenshotPath)")
    print(
        "   Crop: x \(cropXFraction) y \(cropYFraction) "
        + "b \(cropWidthFraction) h \(cropHeightFraction)"
        + (cropValues == nil ? "" : "  (aus WATCHER_CROP)")
    )
}

print("")
print("==============================================")
print("")

Task {

    print("🚀 Watcher gestartet.")
    print("")

    if testEnabled {

        print("🧪 Teste Discord-Webhook...")

        if let messageID = await sendDiscordMessage(
            content:
                "🧪 **Roblox Event Watcher** ist verbunden. "
                + "Das ist eine Testnachricht."
        ) {
            print("✅ Webhook funktioniert (Message \(messageID)).")
        } else {
            print("❌ Webhook-Test fehlgeschlagen - siehe Fehler oben.")
        }

        print("")
    }

    while !Task.isCancelled {

        if Date() >= state.nextSync {

            await performSync()

            let interval =
                state.remaining <= nearEndSeconds
                    ? syncIntervalNearEnd
                    : syncInterval

            state.nextSync = Date().addingTimeInterval(interval)
        }

        await tickCountdown()

        do {
            try await Task.sleep(
                nanoseconds: tickSeconds * 1_000_000_000
            )
        } catch {
            break
        }
    }

    print("🛑 Watcher beendet.")
}

// ============================================================
// KEEP PROCESS ALIVE
// ============================================================

dispatchMain()

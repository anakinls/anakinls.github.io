import Foundation
import Vision
import ScreenCaptureKit
import CoreGraphics
import AppKit
import Dispatch

// ============================================================
// CONFIG
// ============================================================

// Poll-Intervalle für OCR (Sekunden)
let idleCheckInterval: UInt64 = 25
let activeCheckInterval: UInt64 = 5

// Während ein Countdown läuft muss NICHT sekündlich gescreenshottet
// werden: aus einer Lesung wird ein Ablaufzeitpunkt, ab da zählt die
// Uhr lokal weiter. OCR dient nur noch dem Abgleich.
let syncCheckInterval: UInt64 = 10

// Takt der Hauptschleife. Daran hängt, wie schnell die Discord-
// Nachricht nachgezogen wird - nicht, wie oft OCR läuft.
let tickSeconds: UInt64 = 1

// Höchstens alle zwei Sekunden editieren. Zusammen mit dem Takt
// oben hinkt die angezeigte Zahl nie mehr als etwa drei Sekunden
// hinterher, und die Webhook-Rate bleibt im Rahmen.
let countdownEditGap: TimeInterval = 2

// Weicht die OCR-Lesung um mehr als das vom lokal gezählten Wert
// ab, gilt die Lesung - dann hat sich im Spiel etwas verschoben.
let resyncToleranceSeconds = 2

// Erst ab hier wird gepingt und der Countdown live mitgeschrieben.
// Der obere Slot wechselt alle 5 Minuten, also deckt ein Vorlauf von
// 5 Minuten praktisch den ganzen Zyklus ab.
let alertLeadSeconds = 300

// Es gibt immer nur EINE Nachricht. Eine neue wird frühestens nach
// dieser Zeit geschickt - alles dazwischen aktualisiert die
// bestehende. Nur eine neue Nachricht pingt die Rolle.
let newMessageMinInterval: TimeInterval = 300

// Rolle, die gepingt wird. Leer lassen = kein Ping.
let pingRoleID = "1555684515140341903"

// Oberer Slot: "garantierte" Events.
// ROADWAY  -> :55
// DRAGRACE -> :25
// auf den übrigen 5-Minuten-Marken ein Rarity-Event.
let knownEvents = [
    "ROADWAY",
    "DRAGRACE",
    "GOLD",
    "DIAMOND",
    "RAINBOW",
    "MYTHIC",
    "LEGENDARY",
    "SECRET",
    "OG"
]

// Nur diese Events lösen einen Discord-Ping aus.
// Alles eintragen = Ping alle 5 Minuten, also bewusst klein halten.
let alertEvents: Set<String> = [
    "SECRET",
    "OG",
    "MYTHIC",
    "LEGENDARY",
    "RAINBOW"
]

// Die beiden unteren Slots sind dauerhaft sichtbar und laufen
// unabhängig vom oberen Slot.
let alertJunkyard = false
let alertBlitz = false

// Wenn Vision den Namen im oberen Slot nicht lesen kann: trotzdem
// pingen. Zwischen Roadway (:00) und Dragrace (:30) laufen dort nur
// die Rarity-Events, und die meisten davon stehen ohnehin oben.
// Lieber ein Ping zu viel als ein verpasstes SECRET.
let alertUnknownRotating = true

// Crop auf das HUD unten rechts, relativ zur Fenstergröße.
// Gemessen an einem Debug-Screenshot sitzt der Block bei
// x 0.88-1.00 und y 0.89-0.98 - der Rest des Bildes ist für OCR
// nur Ablenkung und kostet Auflösung.
// Mit WATCHER_DEBUG=1 wird der Ausschnitt als PNG abgelegt,
// damit sich das auf einer anderen Auflösung nachziehen lässt.
let cropXFraction: CGFloat = 0.84
let cropYFraction: CGFloat = 0.84
let cropWidthFraction: CGFloat = 0.16
let cropHeightFraction: CGFloat = 0.16

// Die HUD-Schrift ist klein - Vision liest sie deutlich besser,
// wenn der Ausschnitt vorher hochskaliert wird.
let ocrUpscale = 6

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

// Der Webhook wird aus der Umgebungsvariable DISCORD_WEBHOOK_URL gelesen,
// damit er NIE in diesem öffentlichen Repository landet.
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
// SLOTS
// ============================================================

enum Slot: String, CaseIterable {
    case rotating
    case junkyard
    case blitz

    var emoji: String {
        switch self {
        case .rotating: return "🎯"
        case .junkyard: return "⛏️"
        case .blitz:    return "⚡"
        }
    }

    var label: String {
        switch self {
        case .rotating: return "Event"
        case .junkyard: return "Junkyard"
        case .blitz:    return "Blitz"
        }
    }
}

// Was eine einzelne OCR-Runde aus dem HUD gelesen hat.
struct HUDReading {
    var rotatingEvent: String? = nil
    var seconds: [Slot: Int] = [:]

    var isEmpty: Bool {
        seconds.isEmpty
    }
}

// ============================================================
// STATE
// ============================================================

// Aus einer OCR-Lesung wird ein Ablaufzeitpunkt. Die Restzeit
// ergibt sich danach aus der Uhr, nicht aus dem nächsten Screenshot.
struct SlotTiming {
    let deadline: Date
    let syncedAt: Date

    var remaining: Int {
        max(0, Int(deadline.timeIntervalSinceNow.rounded()))
    }
}

// Es läuft immer höchstens eine Discord-Nachricht. owner ist der
// Slot, dessen Countdown sie gerade anzeigt - nil heißt: frei, der
// nächste Countdown darf sie übernehmen.
final class LiveMessage {
    let id: String
    let createdAt: Date

    var owner: Slot?
    var title: String
    var lastShownSeconds: Int
    var lastEditAt: Date

    init(
        id: String,
        owner: Slot,
        title: String,
        lastShownSeconds: Int
    ) {
        self.id = id
        self.createdAt = Date()
        self.owner = owner
        self.title = title
        self.lastShownSeconds = lastShownSeconds
        self.lastEditAt = Date()
    }
}

final class WatcherState {
    var live: LiveMessage?

    // Lokal weiterlaufende Restzeiten, aus OCR nachgezogen.
    var timing: [Slot: SlotTiming] = [:]

    var lastSeconds: [Slot: Int] = [:]
    var lastRotatingEvent: String?
    var currentInterval: UInt64 = idleCheckInterval

    // Gelernte Zeilenpositionen im Crop. Sobald alle drei Zeilen
    // einmal gelesen wurden, lassen sich später auch unvollständige
    // Lesungen korrekt zuordnen.
    var slotY: [Slot: CGFloat] = [:]

    // Damit die Zeitplan-Meldung nicht bei jedem Check erscheint.
    var lastScheduleNote: String?

    // Nach einem 429 vor diesem Zeitpunkt nichts mehr an Discord schicken.
    var discordBlockedUntil: Date?
}

let state = WatcherState()

// ============================================================
// EVENT EMOJI
// ============================================================

func emoji(for event: String) -> String {
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

// ============================================================
// TIMER FORMAT
// ============================================================

func formatTimer(_ totalSeconds: Int) -> String {
    let safe = max(0, totalSeconds)

    let hours = safe / 3600
    let minutes = (safe % 3600) / 60
    let seconds = safe % 60

    if hours > 0 {
        return String(
            format: "%dh %02dm %02ds",
            hours,
            minutes,
            seconds
        )
    }

    if minutes > 0 {
        return String(
            format: "%dm %02ds",
            minutes,
            seconds
        )
    }

    return "\(seconds)s"
}

// ============================================================
// DISCORD CONTENT
// ============================================================

func discordContent(
    title: String,
    headlineEmoji: String,
    seconds: Int,
    reading: HUDReading,
    mention: Bool
) -> String {

    var lines: [String] = []

    let prefix = mention && !pingRoleID.isEmpty
        ? "<@&\(pingRoleID)> "
        : ""

    if seconds <= 0 {
        lines.append(
            "\(prefix)\(headlineEmoji) **\(title) IST DA!**"
        )
    } else {
        lines.append(
            "\(prefix)\(headlineEmoji) **\(title)**"
        )
        lines.append("")
        lines.append(
            "⏳ **noch \(formatTimer(seconds))**"
        )
    }

    // Die beiden Dauer-Slots als Kontext mitschicken.
    var context: [String] = []

    for slot in [Slot.junkyard, Slot.blitz] {

        guard let slotSeconds = reading.seconds[slot] else {
            continue
        }

        context.append(
            "\(slot.emoji) \(slot.label): \(formatTimer(slotSeconds))"
        )
    }

    if !context.isEmpty {
        lines.append("")
        lines.append(
            context.joined(separator: "   •   ")
        )
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
        "⏸️ Discord Rate-Limit: pausiere \(String(format: "%.1f", retryAfter))s"
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

    print("📤 Sende Discord-Nachricht...")

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
        URLQueryItem(
            name: "wait",
            value: "true"
        )
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

            applyRateLimit(
                data: data,
                fallbackSeconds: 5
            )

            return nil
        }

        guard (200...299).contains(httpResponse.statusCode) else {

            print("❌ Discord HTTP \(httpResponse.statusCode)")

            if let responseText = String(
                data: data,
                encoding: .utf8
            ) {
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

        print("")
        print("✅ DISCORD GESENDET (Message \(messageID))")
        print("")

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
        "allowed_mentions": [
            "parse": []
        ]
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
            webhookURL.absoluteString +
            "/messages/" +
            messageID
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

            applyRateLimit(
                data: data,
                fallbackSeconds: 2
            )

            return false
        }

        if (200...299).contains(httpResponse.statusCode) {
            return true
        }

        print("❌ Discord Countdown HTTP \(httpResponse.statusCode)")

        if let responseText = String(
            data: data,
            encoding: .utf8
        ) {
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

    // ============================================================
    // 1. PRIORITÄT: NORMALE HAUPT-ROBLOX-INSTANZ
    // ============================================================

    if let mainRoblox = content.windows.first(where: { window in

        let bundleID =
            window.owningApplication?.bundleIdentifier ?? ""

        return bundleID == "com.roblox.RobloxPlayer" &&
               window.frame.width > 1000 &&
               window.frame.height > 700
    }) {

        return mainRoblox
    }

    // ============================================================
    // 2. FALLBACK: GRÖSSTES ROBLOX-FENSTER
    // ============================================================

    let robloxWindows = content.windows.filter { window in

        let appName =
            window.owningApplication?.applicationName ?? ""

        let bundleID =
            window.owningApplication?.bundleIdentifier ?? ""

        let isRoblox =
            appName.localizedCaseInsensitiveContains("Roblox") ||
            bundleID.localizedCaseInsensitiveContains("roblox")

        let validSize =
            window.frame.width > 500 &&
            window.frame.height > 300

        return isRoblox && validSize
    }

    guard !robloxWindows.isEmpty else {
        return nil
    }

    return robloxWindows.max {
        ($0.frame.width * $0.frame.height) <
        ($1.frame.width * $1.frame.height)
    }
}

// ============================================================
// SCREENSHOT
// ============================================================

func captureHUD(_ window: SCWindow) async throws -> CGImage {

    let filter = SCContentFilter(
        desktopIndependentWindow: window
    )

    let configuration = SCStreamConfiguration()

    configuration.width = max(1, Int(window.frame.width))
    configuration.height = max(1, Int(window.frame.height))

    configuration.scalesToFit = false
    configuration.showsCursor = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    let fullImage = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
    )

    // ============================================================
    // HUD UNTEN RECHTS AUSSCHNEIDEN
    // ============================================================
    //
    // Das HUD hängt seit dem Update unten rechts und zeigt drei
    // Zeilen: oben das wechselnde Event mit Namen, darunter
    // Junkyard (Spitzhacke) und ganz unten Blitz.

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
                    "HUD-Bereich konnte nicht zugeschnitten werden."
            ]
        )
    }

    // ============================================================
    // OCR-BILD VERGRÖSSERN
    // ============================================================

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

    let url = URL(fileURLWithPath: debugScreenshotPath)

    do {
        try pngData.write(to: url)
        print("📸 Debug-Screenshot: \(url.path)")
    } catch {
        print("❌ Screenshot konnte nicht gespeichert werden: \(error)")
    }
}

// ============================================================
// OCR
// ============================================================

// Eine erkannte Textzeile samt vertikaler Position.
// midY ist normalisiert, 1.0 = oben.
// Vision liefert mehrere Lesarten pro Zeile - für den Event-Namen
// werden alle geprüft, für den Timer reicht die beste.
struct OCRLine {
    let text: String
    let alternatives: [String]
    let midY: CGFloat
}

// languageCorrection aus: Zahlen bleiben Zahlen.
// languageCorrection an (plus customWords): zweiter Versuch, wenn
// der Event-Name sonst nicht lesbar ist.
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
                    alternatives: candidates.map { $0.string },
                    midY: observation.boundingBox.midY
                )
            )
        }
    }

    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = languageCorrection
    request.recognitionLanguages = ["en-US"]

    // Die HUD-Schrift ist klein; Standard wäre 1/32 der Bildhöhe.
    request.minimumTextHeight = 0.02

    if languageCorrection {
        request.customWords = knownEvents
    }

    let handler = VNImageRequestHandler(
        cgImage: image,
        orientation: .up,
        options: [:]
    )

    try handler.perform([request])

    // Von oben nach unten sortieren.
    return lines.sorted { $0.midY > $1.midY }
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
func allowedDistance(for event: String) -> Int {
    switch event.count {
    case 0...3: return 0
    case 4...6: return 1
    default:    return 2
    }
}

func detectEvent(in line: String) -> String? {

    let upper = line.uppercased()

    for event in knownEvents where upper.contains(event) {
        return event
    }

    let words = upper
        .components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        .filter { !$0.isEmpty }

    for word in words {
        for event in knownEvents {

            if levenshteinDistance(word, event)
                <= allowedDistance(for: event) {

                return event
            }
        }
    }

    return nil
}

// Vision liefert pro Zeile mehrere Lesarten. Die beste ist oft
// verstümmelt, während die zweite oder dritte den Namen trifft.
func detectEvent(in line: OCRLine) -> String? {

    for candidate in line.alternatives {
        if let event = detectEvent(in: candidate) {
            return event
        }
    }

    return nil
}

// ============================================================
// TIMER EXTRACTION
// ============================================================

// Das HUD mischt zwei Schreibweisen: "in 0:14" beim oberen Slot
// und "in 15m 14s" bei den beiden unteren.
func parseDuration(from line: String) -> Int? {

    let cleaned = line
        .uppercased()
        .replacingOccurrences(of: "O", with: "0")
        .replacingOccurrences(of: "I", with: "1")
        .replacingOccurrences(of: "L", with: "1")
        .replacingOccurrences(of: ";", with: ":")
        .replacingOccurrences(of: "．", with: ".")

    // ---- Form 1: 1H 05M 14S / 15M 14S / 45S ----

    let unitPattern = #"(\d{1,2})\s*([HMS])"#

    if let regex = try? NSRegularExpression(pattern: unitPattern) {

        let range = NSRange(
            cleaned.startIndex..<cleaned.endIndex,
            in: cleaned
        )

        let matches = regex.matches(in: cleaned, range: range)

        if !matches.isEmpty {

            var total = 0
            var found = false

            for match in matches {

                guard
                    let valueRange = Range(
                        match.range(at: 1),
                        in: cleaned
                    ),
                    let unitRange = Range(
                        match.range(at: 2),
                        in: cleaned
                    ),
                    let value = Int(cleaned[valueRange])
                else {
                    continue
                }

                switch cleaned[unitRange] {
                case "H": total += value * 3600
                case "M": total += value * 60
                default:  total += value
                }

                found = true
            }

            if found {
                return total
            }
        }
    }

    // ---- Form 2: 0:14 / 12:34 / 1:02:03 ----

    let clockPattern =
        #"(?<!\d)(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?!\d)"#

    guard
        let regex = try? NSRegularExpression(pattern: clockPattern)
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

    func group(_ index: Int) -> Int? {

        guard let groupRange = Range(
            match.range(at: index),
            in: cleaned
        ) else {
            return nil
        }

        return Int(cleaned[groupRange])
    }

    guard
        let middle = group(2),
        let last = group(3),
        last < 60
    else {
        return nil
    }

    if let hours = group(1) {

        guard middle < 60 else {
            return nil
        }

        return hours * 3600 + middle * 60 + last
    }

    return middle * 60 + last
}

// ============================================================
// HUD PARSING
// ============================================================

// Zeilen von oben nach unten:
//
//   ROADWAY          <- Name, nur beim oberen Slot
//   in 0:14          <- oberer Slot
//   in 15m 14s       <- Junkyard
//   in 45m 14s       <- Blitz
//
// Die Zuordnung läuft über die y-Position aus Vision, nicht über
// die Reihenfolge im OCR-Ergebnis.
func parseHUD(lines: [OCRLine]) -> HUDReading {

    var reading = HUDReading()

    var timers: [(seconds: Int, midY: CGFloat)] = []
    var labels: [(event: String, midY: CGFloat)] = []

    for line in lines {

        // Vision trennt Name und Timer meist in zwei Zeilen, fasst sie
        // aber gelegentlich zu einer zusammen - deshalb beides prüfen.
        if let event = detectEvent(in: line) {
            labels.append((event, line.midY))
        }

        if let seconds = parseDuration(from: line.text) {
            timers.append((seconds, line.midY))
        }
    }

    guard !timers.isEmpty else {
        return reading
    }

    // Oberster Name gehört zum oberen Slot.
    let topLabel = labels.first

    reading.rotatingEvent = topLabel?.event

    // Timer unterhalb des Namens zuerst, sonst einfach von oben.
    var ordered = timers

    if let topLabel {
        // <= statt <, damit ein Timer auf Höhe des Namens
        // (zusammengefasste Zeile) nicht verloren geht.
        let below = timers.filter { $0.midY <= topLabel.midY }

        if !below.isEmpty {
            ordered = below
        }
    }

    let slotOrder: [Slot] = [.rotating, .junkyard, .blitz]

    if ordered.count >= slotOrder.count {

        // Alle Zeilen da: direkt zuordnen und die Positionen merken.
        for (index, timer) in ordered.prefix(slotOrder.count).enumerated() {
            reading.seconds[slotOrder[index]] = timer.seconds
            state.slotY[slotOrder[index]] = timer.midY
        }

    } else if !state.slotY.isEmpty {

        // Eine Zeile fehlt. Nach Reihenfolge zuzuordnen würde die
        // restlichen nach oben rutschen lassen - also über die
        // gelernten Positionen gehen.
        for timer in ordered {

            var best: (slot: Slot, distance: CGFloat)?

            for slot in slotOrder {

                guard let knownY = state.slotY[slot] else {
                    continue
                }

                let distance = abs(knownY - timer.midY)

                if best == nil || distance < best!.distance {
                    best = (slot, distance)
                }
            }

            // Zu weit weg heißt: das ist keine der bekannten Zeilen.
            if let best, best.distance < 0.08 {
                reading.seconds[best.slot] = timer.seconds
            }
        }

    } else {

        // Noch nichts gelernt - bestmöglich nach Reihenfolge.
        for (index, timer) in ordered.enumerated() {
            reading.seconds[slotOrder[index]] = timer.seconds
        }
    }

    return reading
}

// ============================================================
// SCHEDULE FALLBACK
// ============================================================

// ROADWAY startet um :55, DRAGRACE um :25 - jeweils fünf Minuten vor
// der vollen bzw. halben Stunde. Wenn OCR den Namen nicht liest,
// lässt sich das aus der Uhrzeit ableiten, auf die der Countdown
// zeigt. Die Rarity-Events auf den übrigen 5-Minuten-Marken
// rotieren in unbekannter Reihenfolge und bleiben deshalb offen.
func scheduledEvent(inSeconds seconds: Int) -> String? {

    let target = Date().addingTimeInterval(TimeInterval(seconds))

    let minute = Calendar.current.component(.minute, from: target)

    // Eine Minute Toleranz nach unten, der Countdown ist nie
    // exakt synchron.
    switch minute {
    case 54, 55: return "ROADWAY"
    case 24, 25: return "DRAGRACE"
    default:     return nil
    }
}

// ============================================================
// ALERT RULES
// ============================================================

func shouldAlert(slot: Slot, event: String?) -> Bool {

    switch slot {

    case .rotating:
        guard let event else {
            return alertUnknownRotating
        }

        return alertEvents.contains(event)

    case .junkyard:
        return alertJunkyard

    case .blitz:
        return alertBlitz
    }
}

func title(for slot: Slot, event: String?) -> String {

    switch slot {

    case .rotating:
        return event ?? "EVENT (Name nicht lesbar)"

    case .junkyard:
        return "JUNKYARD"

    case .blitz:
        return "BLITZ"
    }
}

func headlineEmoji(for slot: Slot, event: String?) -> String {

    switch slot {

    case .rotating:
        return emoji(for: event ?? "")

    default:
        return slot.emoji
    }
}

// ============================================================
// COUNTDOWN HANDLING
// ============================================================

func handleSlot(
    _ slot: Slot,
    reading: HUDReading
) async {

    guard let seconds = reading.seconds[slot] else {
        return
    }

    let event = slot == .rotating ? reading.rotatingEvent : nil

    // ----------------------------------------------------
    // NEUER ZYKLUS
    // ----------------------------------------------------
    //
    // Springt der Timer wieder hoch, hat der Slot neu gestartet.

    if let previous = state.lastSeconds[slot],
       seconds > previous + 10 {

        if let live = state.live, live.owner == slot {

            print("🔄 \(slot.label): neuer Zyklus.")

            _ = await updateDiscordMessage(
                messageID: live.id,
                content: discordContent(
                    title: live.title,
                    headlineEmoji: headlineEmoji(
                        for: slot,
                        event: state.lastRotatingEvent
                    ),
                    seconds: 0,
                    reading: reading,
                    mention: false
                )
            )

            live.owner = nil
        }

        if slot == .rotating {
            state.lastScheduleNote = nil
        }
    }

    state.lastSeconds[slot] = seconds

    if slot == .rotating, let event {
        state.lastRotatingEvent = event
    }

    // ----------------------------------------------------
    // LAUFENDER COUNTDOWN
    // ----------------------------------------------------
    //
    // Das Nachziehen der Nachricht übernimmt tickCountdown() im
    // Sekundentakt. Hier wird nur noch entschieden, ob ein
    // Countdown anfängt.

    if state.live?.owner == slot {
        return
    }

    // ----------------------------------------------------
    // NEUEN COUNTDOWN STARTEN
    // ----------------------------------------------------

    guard seconds > 0, seconds <= alertLeadSeconds else {
        return
    }

    // Ein anderer Slot schreibt gerade - es gibt nur eine Nachricht.
    guard state.live?.owner == nil else {
        return
    }

    var resolvedEvent = event

    if slot == .rotating, resolvedEvent == nil {
        resolvedEvent = scheduledEvent(inSeconds: seconds)

        if let resolvedEvent, state.lastScheduleNote != resolvedEvent {
            state.lastScheduleNote = resolvedEvent

            print("🗓️ Name aus Zeitplan abgeleitet: \(resolvedEvent)")
        }
    }

    guard shouldAlert(slot: slot, event: resolvedEvent) else {
        return
    }

    let slotTitle = title(for: slot, event: resolvedEvent)
    let slotEmoji = headlineEmoji(for: slot, event: resolvedEvent)

    let content = discordContent(
        title: slotTitle,
        headlineEmoji: slotEmoji,
        seconds: seconds,
        reading: reading,
        mention: true
    )

    // ----------------------------------------------------
    // BESTEHENDE NACHRICHT WEITERVERWENDEN
    // ----------------------------------------------------
    //
    // Ist die letzte Nachricht noch keine fünf Minuten alt, wird
    // sie übernommen statt eine neue zu schicken. Ein Edit pingt
    // die Rolle nicht - genau so ist es gewollt.

    if let live = state.live,
       Date().timeIntervalSince(live.createdAt) < newMessageMinInterval {

        print("")
        print("♻️ \(slotTitle) in \(formatTimer(seconds)) - bestehende Nachricht.")
        print("")

        live.owner = slot
        live.title = slotTitle
        live.lastShownSeconds = seconds
        live.lastEditAt = Date()

        _ = await updateDiscordMessage(
            messageID: live.id,
            content: discordContent(
                title: slotTitle,
                headlineEmoji: slotEmoji,
                seconds: seconds,
                reading: reading,
                mention: false
            )
        )

        return
    }

    // ----------------------------------------------------
    // NEUE NACHRICHT
    // ----------------------------------------------------

    print("")
    print("🚨 \(slotTitle) in \(formatTimer(seconds)) - neue Nachricht.")
    print("")

    guard let messageID = await sendDiscordMessage(content: content)
    else {
        return
    }

    state.live = LiveMessage(
        id: messageID,
        owner: slot,
        title: slotTitle,
        lastShownSeconds: seconds
    )
}

// ============================================================
// LOKALER COUNTDOWN
// ============================================================

// Zustand aus den lokal laufenden Uhren, ohne neuen Screenshot.
func currentReading() -> HUDReading {

    var reading = HUDReading()

    reading.rotatingEvent = state.lastRotatingEvent

    for (slot, timing) in state.timing {
        reading.seconds[slot] = timing.remaining
    }

    return reading
}

// Zieht die Discord-Nachricht nach. Läuft im Sekundentakt und
// braucht dafür weder Screenshot noch OCR.
func tickCountdown() async {

    guard let live = state.live,
          let slot = live.owner,
          let timing = state.timing[slot]
    else {
        return
    }

    let seconds = timing.remaining
    let reading = currentReading()

    let event = slot == .rotating
        ? state.lastRotatingEvent
        : nil

    if seconds <= 0 {

        _ = await updateDiscordMessage(
            messageID: live.id,
            content: discordContent(
                title: live.title,
                headlineEmoji: headlineEmoji(for: slot, event: event),
                seconds: 0,
                reading: reading,
                mention: false
            )
        )

        print("🎉 \(live.title) ist da.")

        live.owner = nil

        return
    }

    guard live.lastShownSeconds != seconds else {
        return
    }

    guard Date().timeIntervalSince(live.lastEditAt) >= countdownEditGap
    else {
        return
    }

    let success = await updateDiscordMessage(
        messageID: live.id,
        content: discordContent(
            title: live.title,
            headlineEmoji: headlineEmoji(for: slot, event: event),
            seconds: seconds,
            reading: reading,
            mention: false
        )
    )

    if success {
        live.lastShownSeconds = seconds
        live.lastEditAt = Date()
    }
}

// ============================================================
// ONE CHECK
// ============================================================

func performCheck() async -> HUDReading {

    do {

        guard let window = try await findRobloxWindow() else {
            print("⚠️ Roblox-Fenster nicht gefunden.")
            return HUDReading()
        }

        let screenshot = try await captureHUD(window)

        if debugEnabled {
            saveDebugScreenshot(screenshot)
        }

        let lines = try recognizeLines(from: screenshot)

        guard !lines.isEmpty else {
            print("ℹ️ Kein Text erkannt.")
            return HUDReading()
        }

        if debugEnabled {
            print("📝 OCR:")
            for line in lines {
                print("   \(line.text)")
            }
        }

        var reading = parseHUD(lines: lines)

        // ----------------------------------------------------
        // ZWEITER VERSUCH FÜR DEN NAMEN
        // ----------------------------------------------------
        //
        // Der Timer steht, aber der Name nicht: nochmal mit
        // Sprachkorrektur und den Event-Namen als customWords.
        // Für Zahlen wäre das riskant, für ein Wort hilft es.

        if reading.rotatingEvent == nil,
           reading.seconds[.rotating] != nil {

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

            // Der Name steht auf oder über der obersten Timer-Zeile.
            // Weiter unten liegen nur Junkyard und Blitz, dort wäre
            // ein Treffer ein Fehlalarm.
            let floorY = state.slotY[.rotating].map { $0 - 0.02 }

            for line in retry {

                if let floorY, line.midY < floorY {
                    continue
                }

                if let event = detectEvent(in: line) {
                    reading.rotatingEvent = event
                    break
                }
            }
        }

        guard !reading.isEmpty else {
            print("ℹ️ Keine Timer im HUD gefunden.")
            return reading
        }

        // ----------------------------------------------------
        // UHREN NACHZIEHEN
        // ----------------------------------------------------
        //
        // Jede Lesung wird zu einem Ablaufzeitpunkt. Weicht sie nur
        // um ein, zwei Sekunden von der lokal laufenden Uhr ab, ist
        // das Rundung im HUD - dann bleibt die alte Uhr stehen,
        // sonst würde die Anzeige hin und her springen.

        for slot in Slot.allCases {

            guard let seconds = reading.seconds[slot] else {
                continue
            }

            if let existing = state.timing[slot],
               abs(existing.remaining - seconds) <= resyncToleranceSeconds {
                continue
            }

            state.timing[slot] = SlotTiming(
                deadline: Date().addingTimeInterval(TimeInterval(seconds)),
                syncedAt: Date()
            )
        }

        // Slots, die das HUD nicht mehr zeigt, nicht ewig
        // weiterzählen lassen.
        for slot in Slot.allCases where reading.seconds[slot] == nil {

            if let timing = state.timing[slot],
               Date().timeIntervalSince(timing.syncedAt) > 120 {

                state.timing[slot] = nil
            }
        }

        // ----------------------------------------------------
        // STATUS
        // ----------------------------------------------------

        var status: [String] = []

        if let rotating = reading.seconds[.rotating] {

            let name = reading.rotatingEvent ?? "?"

            status.append("🎯 \(name) \(formatTimer(rotating))")
        }

        if let junkyard = reading.seconds[.junkyard] {
            status.append("⛏️ \(formatTimer(junkyard))")
        }

        if let blitz = reading.seconds[.blitz] {
            status.append("⚡ \(formatTimer(blitz))")
        }

        print(status.joined(separator: "   |   "))

        // ----------------------------------------------------
        // SLOTS
        // ----------------------------------------------------

        for slot in Slot.allCases {
            await handleSlot(slot, reading: reading)
        }

        return reading

    } catch {

        print("❌ Check fehlgeschlagen: \(error.localizedDescription)")

        return HUDReading()
    }
}

// ============================================================
// POLL INTERVAL
// ============================================================

// Nur noch der OCR-Takt. Wie flüssig der Countdown aussieht, hängt
// davon nicht ab - das macht die lokale Uhr.
func nextInterval(for reading: HUDReading) -> UInt64 {

    // Läuft ein Countdown, reicht ein Abgleich alle paar Sekunden.
    if state.live?.owner != nil {
        return syncCheckInterval
    }

    var soonest: Int?

    for slot in Slot.allCases {

        guard let seconds = reading.seconds[slot] else {
            continue
        }

        let event = slot == .rotating
            ? (reading.rotatingEvent
                ?? scheduledEvent(inSeconds: seconds))
            : nil

        guard shouldAlert(slot: slot, event: event) else {
            continue
        }

        if soonest == nil || seconds < soonest! {
            soonest = seconds
        }
    }

    guard let soonest else {
        return idleCheckInterval
    }

    // Kurz vor dem Vorlauf schon dichter prüfen, damit der
    // Countdown nicht mitten im Zyklus startet.
    if soonest <= alertLeadSeconds + 60 {
        return activeCheckInterval
    }

    return idleCheckInterval
}

// ============================================================
// START
// ============================================================

print("")
print("==============================================")
print("       ROBLOX EVENT WATCHER")
print("==============================================")
print("")
print("HUD: unten rechts, 3 Slots")
print("  🎯 Event    (Name + Countdown)")
print("  ⛏️ Junkyard")
print("  ⚡ Blitz")
print("")
print("Ping bei: \(alertEvents.sorted().joined(separator: ", "))")
print("Vorlauf: \(alertLeadSeconds)s")
print("Rolle: \(pingRoleID.isEmpty ? "kein Ping" : pingRoleID)")
print("Neue Nachricht frühestens alle \(Int(newMessageMinInterval))s")
print("Unbekannter Name: \(alertUnknownRotating ? "pingt trotzdem" : "kein Ping")")
print("Junkyard-Ping: \(alertJunkyard ? "an" : "aus")")
print("Blitz-Ping: \(alertBlitz ? "an" : "aus")")
print("")
print("Capture: ScreenCaptureKit")
print("OCR: Apple Vision")

if debugEnabled {
    print("")
    print("🐞 Debug an - OCR-Zeilen und \(debugScreenshotPath)")
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

    // Die Schleife läuft im Sekundentakt, OCR aber nur, wenn es
    // fällig ist. Dazwischen zieht tickCountdown() die Nachricht
    // allein aus der lokalen Uhr nach.
    var nextOCR = Date()

    while !Task.isCancelled {

        if Date() >= nextOCR {

            let reading = await performCheck()

            let interval = nextInterval(for: reading)

            if interval != state.currentInterval {

                state.currentInterval = interval

                print("⏳ OCR-Takt: alle \(interval)s")
            }

            nextOCR = Date().addingTimeInterval(TimeInterval(interval))
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

import Foundation
import Vision
import ScreenCaptureKit
import CoreGraphics
import AppKit
import Dispatch

// ============================================================
// CONFIG
// ============================================================

let normalCheckInterval: UInt64 = 25
let activeCheckInterval: UInt64 = 5

let targetEvents = [
    "SECRET",
    "DIAMOND",
    "RAINBOW"
]

// ============================================================
// CORE GRAPHICS / APP
// ============================================================

_ = CGMainDisplayID()

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

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
// STATE
// ============================================================

final class WatcherState {
    var lastDetectedEvent: String?
    var countdownMessageID: String?
    var countdownEvent: String?
    var countdownLastSecond: Int?
    var lastTimerSeconds: Int?
    var currentInterval: UInt64 = normalCheckInterval
}

let state = WatcherState()

// ============================================================
// DISCORD CONTENT
// ============================================================

func discordContent(event: String, seconds: Int) -> String {
    let emoji: String

    switch event {
    case "RAINBOW":
        emoji = "🌈"
    case "DIAMOND":
        emoji = "💎"
    case "SECRET":
        emoji = "🔴"
    default:
        emoji = "🚨"
    }

    return """
    @everyone \(emoji) **\(event) GARAGE DETECTED!**

    ⏳ **\(seconds) SECONDS LEFT**
    """
}

// ============================================================
// DISCORD SEND
// ============================================================

func sendDiscordMessage(
    event: String,
    seconds: Int
) async -> String? {

    print("📤 Sende Discord-Nachricht...")

    let payload: [String: Any] = [
        "username": "Roblox Event Watcher",
        "content": discordContent(
            event: event,
            seconds: seconds
        ),
        "allowed_mentions": [
            "parse": ["everyone"]
        ]
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
            try await URLSession.shared.data(
                for: request
            )

        guard let httpResponse =
            response as? HTTPURLResponse
        else {

            print("❌ Ungültige Discord-Antwort.")
            return nil
        }

        print(
            "📡 Discord HTTP Status: \(httpResponse.statusCode)"
        )

        guard (200...299).contains(
            httpResponse.statusCode
        ) else {

            print(
                "❌ Discord HTTP \(httpResponse.statusCode)"
            )

            if let responseText =
                String(
                    data: data,
                    encoding: .utf8
                ) {

                print(
                    "Discord Antwort: \(responseText)"
                )
            }

            return nil
        }

        guard
            let json =
                try? JSONSerialization.jsonObject(
                    with: data,
                    options: []
                ) as? [String: Any],

            let messageID =
                json["id"] as? String

        else {

            print(
                "❌ Discord Message-ID konnte nicht gelesen werden."
            )

            if let responseText =
                String(
                    data: data,
                    encoding: .utf8
                ) {

                print(
                    "Discord Antwort: \(responseText)"
                )
            }

            return nil
        }

        print("")
        print(
            "✅ DISCORD GESENDET: \(event) bei \(seconds)s"
        )
        print(
            "🆔 Message ID: \(messageID)"
        )
        print("")

        return messageID

    } catch {

        print(
            "❌ Discord Fehler: \(error.localizedDescription)"
        )

        return nil
    }
}

// ============================================================
// DISCORD UPDATE
// ============================================================

func updateDiscordCountdown(
    messageID: String,
    event: String,
    seconds: Int
) async -> Bool {

    let payload: [String: Any] = [
        "content": discordContent(
            event: event,
            seconds: seconds
        ),

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

    var request = URLRequest(
        url: messageURL
    )

    request.httpMethod = "PATCH"

    request.setValue(
        "application/json",
        forHTTPHeaderField: "Content-Type"
    )

    request.timeoutInterval = 15
    request.httpBody = body

    do {

        let (data, response) =
            try await URLSession.shared.data(
                for: request
            )

        guard let httpResponse =
            response as? HTTPURLResponse
        else {

            print("❌ Ungültige Discord Countdown-Antwort.")
            return false
        }

        if (200...299).contains(
            httpResponse.statusCode
        ) {

            print(
                "⏱️ Discord Countdown aktualisiert: \(seconds)s"
            )

            return true

        } else {

            print(
                "❌ Discord Countdown HTTP \(httpResponse.statusCode)"
            )

            if let responseText =
                String(
                    data: data,
                    encoding: .utf8
                ) {

                print(
                    "Discord Antwort: \(responseText)"
                )
            }

            return false
        }

    } catch {

        print(
            "❌ Discord Countdown Fehler: \(error.localizedDescription)"
        )

        return false
    }
}

// ============================================================
// FIND ROBLOX WINDOW
// ============================================================

func findRobloxWindow() async throws -> SCWindow? {

    print("🔎 Suche nach Roblox-Hauptfenster...")

    let content =
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

    print("🪟 Gefundene Fenster: \(content.windows.count)")

    // Alle Roblox-Fenster anzeigen
    for window in content.windows {

        let appName =
            window.owningApplication?.applicationName ?? ""

        let bundleID =
            window.owningApplication?.bundleIdentifier ?? ""


        if appName.localizedCaseInsensitiveContains("Roblox") ||
           bundleID.localizedCaseInsensitiveContains("roblox") {

            print(
                "   • Roblox: \(bundleID) | " +
                "\(Int(window.frame.width))x\(Int(window.frame.height))"
            )
        }
    }

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

        print(
            "✅ HAUPT-ROBLOX AUSGEWÄHLT: " +
            "\(Int(mainRoblox.frame.width))x" +
            "\(Int(mainRoblox.frame.height))"
        )

        return mainRoblox
    }

    // ============================================================
    // 2. FALLBACK: GRÖSSTES ROBLOX-FENSTER
    // ============================================================

    let robloxWindows =
        content.windows.filter { window in

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

        print("⚠️ Kein geeignetes Roblox-Fenster gefunden.")

        return nil
    }

    let selected =
        robloxWindows.max {
            ($0.frame.width * $0.frame.height) <
            ($1.frame.width * $1.frame.height)
        }

    print(
        "✅ Roblox-Fallback ausgewählt: " +
        "\(Int(selected!.frame.width))x" +
        "\(Int(selected!.frame.height))"
    )

    return selected
}

// ============================================================
// SCREENSHOT
// ============================================================

func captureRobloxWindow(
    _ window: SCWindow
) async throws -> CGImage {

    let filter = SCContentFilter(
        desktopIndependentWindow: window
    )

    let configuration = SCStreamConfiguration()

    configuration.width = max(
        1,
        Int(window.frame.width)
    )

    configuration.height = max(
        1,
        Int(window.frame.height)
    )

    configuration.scalesToFit = false
    configuration.showsCursor = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    let fullImage = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
    )

    // ============================================================
    // NUR GARAGE-BALKEN + TEXT OBEN AUFNEHMEN
    // ============================================================

    let width = CGFloat(fullImage.width)
    let height = CGFloat(fullImage.height)

    // Bei deinem Screenshot ungefähr:
    //
    // x: 565 ... 1068
    // y: 37  ... 95
    //
    // Als relative Werte, damit es sich an andere Auflösungen
    // anpassen kann.

    let cropX = width * 0.30
    let cropY = height * 0.02
    let cropWidth = width * 0.40
    let cropHeight = height * 0.11

    let cropRect = CGRect(
        x: cropX,
        y: cropY,
        width: cropWidth,
        height: cropHeight
    ).integral

    guard let croppedImage = fullImage.cropping(
        to: cropRect
    ) else {
        throw NSError(
            domain: "RobloxWatcher",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Garage-Bereich konnte nicht zugeschnitten werden."
            ]
        )
    }

    
    // ============================================================
    // OCR-BILD VERGRÖSSERN
    // ============================================================

    let enlargedWidth =
        croppedImage.width * 3

    let enlargedHeight =
        croppedImage.height * 3

    let colorSpace =
        CGColorSpaceCreateDeviceRGB()

    guard let context =
        CGContext(
            data: nil,
            width: enlargedWidth,
            height: enlargedHeight,
            bitsPerComponent: 8,
            bytesPerRow: enlargedWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
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

    if let enlargedImage = context.makeImage() {

        print(
            "🔎 OCR-Bereich vergrößert: " +
            "\(enlargedImage.width)x\(enlargedImage.height)"
        )

        return enlargedImage
    }

    return croppedImage
    
}
// ============================================================
// DEBUG SCREENSHOT
// ============================================================

func saveDebugScreenshot(
    _ image: CGImage
) {

    let bitmapRep =
        NSBitmapImageRep(
            cgImage: image
        )

    guard let pngData =
        bitmapRep.representation(
            using: .png,
            properties: [:]
        )
    else {

        print("❌ PNG konnte nicht erstellt werden.")
        return
    }

    let url =
        URL(
            fileURLWithPath:
                "/tmp/roblox-debug.png"
        )

    do {

        try pngData.write(
            to: url
        )

        print(
            "📸 Screenshot gespeichert: \(url.path)"
        )

    } catch {

        print(
            "❌ Screenshot konnte nicht gespeichert werden: \(error)"
        )
    }
}

// ============================================================
// OCR
// ============================================================

func recognizeText(
    from image: CGImage
) throws -> String {

    var recognizedLines: [String] = []

    let request =
        VNRecognizeTextRequest {
            request,
            error in

            if let error {

                print(
                    "❌ Vision OCR Fehler: " +
                    "\(error.localizedDescription)"
                )

                return
            }

            guard let observations =
                request.results
                    as? [VNRecognizedTextObservation]
            else {

                return
            }

            let lines =
                observations.compactMap {
                    $0.topCandidates(1)
                        .first?
                        .string
                }

            recognizedLines.append(
                contentsOf: lines
            )
        }

    request.recognitionLevel =
        .accurate

    request.usesLanguageCorrection =
        false

    let handler =
        VNImageRequestHandler(
            cgImage: image,
            orientation: .up,
            options: [:]
        )

    try handler.perform(
        [request]
    )

    return recognizedLines.joined(
        separator: "\n"
    )
}

// ============================================================
// LEVENSHTEIN
// ============================================================

func levenshteinDistance(
    _ a: String,
    _ b: String
) -> Int {

    let aChars = Array(a)
    let bChars = Array(b)

    if aChars.isEmpty {
        return bChars.count
    }

    if bChars.isEmpty {
        return aChars.count
    }

    var previous =
        Array(0...bChars.count)

    for i in 1...aChars.count {

        var current = [i]

        for j in 1...bChars.count {

            let insertion =
                current[j - 1] + 1

            let deletion =
                previous[j] + 1

            let substitution =
                previous[j - 1]
                +
                (
                    aChars[i - 1] ==
                    bChars[j - 1]
                    ? 0
                    : 1
                )

            current.append(
                min(
                    insertion,
                    deletion,
                    substitution
                )
            )
        }

        previous = current
    }

    return previous[
        bChars.count
    ]
}

// ============================================================
// EVENT DETECTION
// ============================================================

func detectEvent(
    in text: String
) -> String? {

    let upperText =
        text.uppercased()

    // Exakte Suche
    for event in targetEvents {

        if upperText.contains(event) {
            return event
        }
    }

    // OCR-Fehler tolerieren
    let words =
        upperText
            .components(
                separatedBy:
                    CharacterSet
                        .alphanumerics
                        .inverted
            )
            .filter {
                !$0.isEmpty
            }

    for word in words {

        for event in targetEvents {

            if levenshteinDistance(
                word,
                event
            ) <= 2 {

                return event
            }
        }
    }

    return nil
}

// ============================================================
// TIMER EXTRACTION
// ============================================================

func extractGarageTimer(
    from text: String
) -> Int? {

    let cleaned =
        text
            .uppercased()
            .replacingOccurrences(
                of: "O:",
                with: "0:"
            )
            .replacingOccurrences(
                of: "O;",
                with: "0:"
            )
            .replacingOccurrences(
                of: "I:",
                with: "1:"
            )
            .replacingOccurrences(
                of: "L:",
                with: "1:"
            )
            .replacingOccurrences(
                of: ";",
                with: ":"
            )
            .replacingOccurrences(
                of: ".",
                with: ":"
            )
            .replacingOccurrences(
                of: " ",
                with: ""
            )

    let pattern =
        #"(?<!\d)(\d{1,2}):(\d{2})(?!\d)"#

    guard let regex =
        try? NSRegularExpression(
            pattern: pattern
        )
    else {

        return nil
    }

    let range =
        NSRange(
            cleaned.startIndex..<cleaned.endIndex,
            in: cleaned
        )

    guard
        let match =
            regex.firstMatch(
                in: cleaned,
                range: range
            ),

        let minuteRange =
            Range(
                match.range(at: 1),
                in: cleaned
            ),

        let secondRange =
            Range(
                match.range(at: 2),
                in: cleaned
            ),

        let minutes =
            Int(
                cleaned[minuteRange]
            ),

        let seconds =
            Int(
                cleaned[secondRange]
            ),

        seconds < 60

    else {

        return nil
    }

    return minutes * 60 + seconds
}

// ============================================================
// TIMER FORMAT
// ============================================================

func formatTimer(
    _ totalSeconds: Int
) -> String {

    let safe =
        max(
            0,
            totalSeconds
        )

    let minutes =
        safe / 60

    let seconds =
        safe % 60

    return String(
        format: "%d:%02d",
        minutes,
        seconds
    )
}

// ============================================================
// RESET COUNTDOWN
// ============================================================

func resetCountdown() {

    state.countdownMessageID = nil
    state.countdownEvent = nil
    state.countdownLastSecond = nil
}

// ============================================================
// ONE CHECK
// ============================================================

func performCheck() async
    -> (
        eventDetected: Bool,
        timerSeconds: Int?
    )
{

    print("")
    print("🔍 Überprüfe Roblox...")

    do {

        // ----------------------------------------------------
        // ROBLOX WINDOW
        // ----------------------------------------------------

        guard let window =
            try await findRobloxWindow()
        else {

            print(
                "⚠️ Roblox-Fenster nicht gefunden."
            )

            return (
                false,
                nil
            )
        }

        // ----------------------------------------------------
        // SCREENSHOT
        // ----------------------------------------------------

        let screenshot =
            try await captureRobloxWindow(
                window
            )

        print(
            "📸 Screenshot: " +
            "\(screenshot.width)x" +
            "\(screenshot.height)"
        )

        // ----------------------------------------------------
        // OCR
        // ----------------------------------------------------

        let text =
            try recognizeText(
                from: screenshot
            )

        if text.isEmpty {

            print(
                "ℹ️ Kein Text erkannt."
            )

            return (
                false,
                nil
            )
        }

        print(
            "📝 OCR:\n\(text)"
        )

        // ----------------------------------------------------
        // TIMER
        // ----------------------------------------------------

        let timerSeconds =
            extractGarageTimer(
                from: text
            )

        if let timerSeconds {

            print(
                "⏱️ Garage-Timer: " +
                "\(formatTimer(timerSeconds))"
            )

        } else {

            print(
                "⏱️ Garage-Timer nicht erkannt."
            )
        }

        // ----------------------------------------------------
        // NEW GARAGE CYCLE
        // ----------------------------------------------------

        if let timerSeconds,
           let previousTimer =
                state.lastTimerSeconds {

            if previousTimer <= 10 &&
               timerSeconds > previousTimer + 10 {

                print(
                    "🔄 Neuer Garage-Zyklus erkannt."
                )

                state.lastDetectedEvent = nil

                resetCountdown()
            }
        }

        // ----------------------------------------------------
        // EVENT
        // ----------------------------------------------------

        if let event =
            detectEvent(in: text) {

            if state.lastDetectedEvent != event {

                print(
                    "🎯 EVENT ERKANNT: \(event)"
                )

                state.lastDetectedEvent =
                    event
            }
        }

        // ----------------------------------------------------
        // EVENT FEHLT
        // ----------------------------------------------------

        guard let event =
            state.lastDetectedEvent
        else {

            state.lastTimerSeconds =
                timerSeconds

            return (
                false,
                timerSeconds
            )
        }

        // ----------------------------------------------------
        // TIMER FEHLT
        // ----------------------------------------------------

        guard let timerSeconds
        else {

            print(
                "🟡 Event \(event) bekannt, " +
                "aber Timer fehlt."
            )

            return (
                true,
                nil
            )
        }

        // ====================================================
        // DISCORD
        // ====================================================

        // WICHTIG:
        // Wir senden jetzt SOFORT, sobald Event + Timer
        // erkannt wurden.
        //
        // Nicht erst bei <=20 Sekunden.
        // ====================================================

        if state.countdownMessageID == nil {

            print("")
            print(
                "🚨 \(event) → " +
                "\(formatTimer(timerSeconds)) bis Garage!"
            )
            print(
                "📤 Discord wird sofort benachrichtigt..."
            )
            print("")

            if let messageID =
                await sendDiscordMessage(
                    event: event,
                    seconds: timerSeconds
                ) {

                state.countdownMessageID =
                    messageID

                state.countdownEvent =
                    event

                state.countdownLastSecond =
                    timerSeconds

            } else {

                print(
                    "⚠️ Discord Nachricht konnte " +
                    "nicht gesendet werden."
                )
            }

        } else if let messageID =
                    state.countdownMessageID {

            // ------------------------------------------------
            // COUNTDOWN UPDATE
            // ------------------------------------------------

            if state.countdownLastSecond !=
                timerSeconds {

                let success =
                    await updateDiscordCountdown(
                        messageID: messageID,
                        event:
                            state.countdownEvent
                            ?? event,
                        seconds: timerSeconds
                    )

                if success {

                    state.countdownLastSecond =
                        timerSeconds
                }
            }

            // ------------------------------------------------
            // GARAGE SPAWNED
            // ------------------------------------------------

            if timerSeconds <= 0 {

                print("")
                print(
                    "🎉 Garage gespawnt!"
                )
                print(
                    "🧹 Discord Countdown beendet."
                )
                print("")

                resetCountdown()
                state.lastDetectedEvent =
                    nil
            }
        }

        state.lastTimerSeconds =
            timerSeconds

        return (
            true,
            timerSeconds
        )

    } catch {

        print(
            "❌ Check fehlgeschlagen: " +
            "\(error.localizedDescription)"
        )

        return (
            false,
            nil
        )
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
print("Events:")
print("  🌈 RAINBOW")
print("  💎 DIAMOND")
print("  🔴 SECRET")
print("")
print("Normal interval: 25 seconds")
print("Active interval: 5 seconds")
print("Capture: ScreenCaptureKit")
print("OCR: Apple Vision")
print("")
print("Discord:")
print("  ✅ Sofortige Nachricht bei Event + Timer")
print("  ⏱️ Danach Countdown-Updates")
print("")
print("==============================================")
print("")

Task {

    print("🚀 Watcher gestartet.")
    print("")

    while !Task.isCancelled {

        let result =
            await performCheck()

        // ----------------------------------------------------
        // CHECK INTERVAL
        // ----------------------------------------------------

        if let timerSeconds =
            result.timerSeconds {

            if timerSeconds <= 25 {

                if state.currentInterval != 1 {

                    state.currentInterval =
                        1

                    print(
                        "⚡ Garage-Timer ≤25s → " +
                        "Check jede 1 Sekunde"
                    )
                }

            } else if result.eventDetected {

                if state.currentInterval !=
                    activeCheckInterval {

                    state.currentInterval =
                        activeCheckInterval

                    print(
                        "🟢 Event bekannt → " +
                        "Check alle 5 Sekunden"
                    )
                }

            } else {

                if state.currentInterval !=
                    normalCheckInterval {

                    state.currentInterval =
                        normalCheckInterval

                    print(
                        "🔴 Kein Event → " +
                        "Check alle 25 Sekunden"
                    )
                }
            }

        } else if result.eventDetected {

            if state.currentInterval !=
                activeCheckInterval {

                state.currentInterval =
                    activeCheckInterval

                print(
                    "🟢 Event bekannt, Timer unbekannt → " +
                    "Check alle 5 Sekunden"
                )
            }

        } else {

            if state.currentInterval !=
                normalCheckInterval {

                state.currentInterval =
                    normalCheckInterval

                print(
                    "🔴 Kein Event → " +
                    "Check alle 25 Sekunden"
                )
            }
        }

        print(
            "⏳ Nächster Check in " +
            "\(state.currentInterval) Sekunden."
        )

        do {

            try await Task.sleep(
                nanoseconds:
                    state.currentInterval *
                    1_000_000_000
            )

        } catch {

            break
        }
    }

    print(
        "🛑 Watcher beendet."
    )
}

// ============================================================
// KEEP PROCESS ALIVE
// ============================================================

dispatchMain()

import Foundation

/// Demo Mode: simulated replies and a sample conversation, so the app can be tried (and reviewed) with no
/// Jarvis server. Everything here runs on the device; nothing is sent anywhere.
/// Shared by the iPhone and Apple Watch apps.
enum DemoBrain {
    static let banner = "DEMO MODE: replies are simulated on this device. No server is needed and nothing is sent anywhere. Turn it off in Settings to connect to your own Jarvis server."

    /// (fromMe, text) pairs shown when Demo Mode is switched on.
    static let sampleConversation: [(fromMe: Bool, text: String)] = [
        (true, "Good morning, Jarvis."),
        (false, "Good morning, sir. All systems are running normally."),
        (true, "What can you do?"),
        (false, "Hold the microphone button and speak, or type below. With your own Jarvis server connected I answer out loud, keep notes, and can suggest tasks for your computer that only run after you approve them."),
        (true, "Remind me to stretch at lunch."),
        (false, "Noted, sir. In Demo Mode notes aren't saved, but on your own server they are."),
    ]

    static func reply(to text: String, now: Date = Date()) -> String {
        let t = text.lowercased()
        if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "I heard you, sir, but couldn't make out the words in Demo Mode. Try typing your question instead."
        }
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("time") {
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            return "It's \(f.string(from: now)), sir."
        }
        if has("date", "day is it", "today") {
            let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
            return "Today is \(f.string(from: now)), sir."
        }
        if has("hello", "hi jarvis", "hey", "good morning", "good evening", "good afternoon") {
            return "Hello, sir. This is Demo Mode, so my answers are simulated, but I'm at your service."
        }
        if has("weather") {
            return "In Demo Mode I can't check the weather, sir. Connected to your own Jarvis server, I'd answer that properly."
        }
        if has("joke") {
            return "I would tell you a UDP joke, sir, but you might not get it."
        }
        if has("who are you", "what are you", "your name") {
            return "I'm Jarvis, a front end for your own self-hosted assistant. Right now I'm in Demo Mode."
        }
        if has("remind", "note", "remember") {
            return "Noted, sir. In Demo Mode it isn't saved, but on your own server it would be."
        }
        if has("thank") {
            return "Always a pleasure, sir."
        }
        return "In Demo Mode I can't reach a real Jarvis server, sir, so this reply is simulated. You asked: \u{201C}\(text)\u{201D}. Connect your own server in Settings for real answers."
    }
}

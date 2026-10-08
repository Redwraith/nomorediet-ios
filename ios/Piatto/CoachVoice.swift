import AVFoundation
import Foundation

/// The coach's voice, male or female.
/// With a Gemini key it uses Google's neural text-to-speech (natural, expressive voices; free tier);
/// otherwise, or if that fails, the best Italian voice installed on the iPhone (premium/enhanced voices
/// can be downloaded in Settings → Accessibility → Spoken Content → Voices → Italian).
@MainActor
final class CoachVoice: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = CoachVoice()

    enum Gender: String { case uomo, donna }

    @Published var gender = Gender(rawValue: UserDefaults.standard.string(forKey: "coach.gender") ?? "") ?? .uomo {
        didSet { UserDefaults.standard.set(gender.rawValue, forKey: "coach.gender") }
    }
    @Published private(set) var speaking = false
    /// "Gemini" or "iPhone": which engine spoke last, for the settings.
    @Published private(set) var lastEngine = ""

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private static let ttsModelKey = "gemini.tts.model"
    /// After a Gemini error (quota, no TTS model) the iPhone voice is used for a while, without waiting.
    private var geminiPausedUntil = Date.distantPast

    /// Gemini prebuilt voices: warm and natural in Italian.
    private var geminiVoice: String { gender == .uomo ? "Charon" : "Kore" }

    func speak(_ text: String) {
        stop()
        let clean = text.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        speaking = true
        task = Task {
            if GeminiAI.hasKey, Date() > geminiPausedUntil, let audio = await geminiSpeech(clean), !Task.isCancelled {
                play(audio, fallback: clean)
            } else if !Task.isCancelled {
                appleSpeak(clean)
            }
        }
    }

    func stop() {
        task?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        speaking = false
    }

    // MARK: Apple voices

    /// The most natural installed Italian voice of the chosen gender.
    static func appleVoice(_ gender: Gender) -> AVSpeechSynthesisVoice? {
        let italian = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("it") }
        let wanted: AVSpeechSynthesisVoiceGender = gender == .uomo ? .male : .female
        // known Italian voices when the system does not report the gender
        let names = gender == .uomo ? ["luca", "marco", "giorgio", "diego"] : ["alice", "federica", "paola", "emma", "silvia"]
        let matching = italian.filter { voice in voice.gender == wanted || names.contains { voice.name.lowercased().contains($0) } }
        let pool = matching.isEmpty ? italian : matching
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "it-IT")
    }

    static var hasNaturalAppleVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix("it") && $0.quality != .default }
    }

    private func appleSpeak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.appleVoice(gender)
        utterance.rate = 0.5
        utterance.pitchMultiplier = gender == .uomo ? 0.95 : 1.05
        utterance.postUtteranceDelay = 0.1
        lastEngine = "iPhone"
        synthesizer.speak(utterance)
        speaking = false
    }

    // MARK: Gemini text-to-speech

    /// WAV audio of the text, or nil (no key, no TTS model, quota, network).
    private func geminiSpeech(_ text: String) async -> Data? {
        guard let key = Keychain.read(Keychain.gemini) else { return nil }
        guard let model = await ttsModel(key: key) else { geminiPausedUntil = Date().addingTimeInterval(3600); return nil }
        let prompt = "Leggi in italiano con il tono energico e caloroso di un personal trainer, ritmo naturale: \(text.prefix(1500))"
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": geminiVoice]]],
            ],
        ]
        var request = URLRequest(url: URL(string: "\(GeminiAI.base)/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            DebugLog.shared.add("info", "voce", "Voce Gemini non disponibile (HTTP \(status)): uso la voce dell'iPhone")
            geminiPausedUntil = Date().addingTimeInterval(status == 404 ? 86400 : 600)
            if status == 404 { UserDefaults.standard.removeObject(forKey: Self.ttsModelKey) }
            return nil
        }
        let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        guard let inline = parts.compactMap({ $0["inlineData"] as? [String: Any] ?? $0["inline_data"] as? [String: Any] }).first,
              let b64 = inline["data"] as? String, let pcm = Data(base64Encoded: b64) else { return nil }
        let mime = (inline["mimeType"] ?? inline["mime_type"]) as? String ?? ""
        let rate = Int(mime.components(separatedBy: "rate=").last?.prefix { $0.isNumber } ?? "") ?? 24000
        return Self.wav(pcm: pcm, sampleRate: rate)
    }

    /// Newest Gemini TTS model available to the key, cached.
    private func ttsModel(key: String) async -> String? {
        if let cached = UserDefaults.standard.string(forKey: Self.ttsModelKey) { return cached }
        var request = URLRequest(url: URL(string: "\(GeminiAI.base)/models?pageSize=200")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] else { return nil }
        let names = models.compactMap { $0["name"] as? String }.filter { $0.contains("tts") && $0.contains("flash") }
        guard let best = names.sorted(by: { $0 > $1 }).first else { return nil }
        UserDefaults.standard.set(best, forKey: Self.ttsModelKey)
        return best
    }

    /// 16-bit mono PCM → WAV container for AVAudioPlayer.
    nonisolated static func wav(pcm: Data, sampleRate: Int) -> Data {
        var out = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVE".utf8)); out.append(contentsOf: Array("fmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(sampleRate)); le(UInt32(sampleRate * 2)); le(UInt16(2)); le(UInt16(16))
        out.append(contentsOf: Array("data".utf8)); le(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    private func play(_ wav: Data, fallback: String) {
        guard let player = try? AVAudioPlayer(data: wav) else { return appleSpeak(fallback) }
        player.delegate = self
        self.player = player
        lastEngine = "Gemini"
        player.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.speaking = false }
    }
}

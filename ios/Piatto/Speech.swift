import AVFoundation
import Speech

/// "Tieni premuto e parla": Italian speech-to-text while the button is held.
final class SpeechListener {
    static let shared = SpeechListener()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""

    func start(completion: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                return DispatchQueue.main.async { completion("Consenti il riconoscimento vocale in Impostazioni → Nomorediet.") }
            }
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard granted else { return completion("Consenti il microfono in Impostazioni → Nomorediet.") }
                    do { try self.begin(); completion(nil) } catch { completion("Il microfono non è disponibile in questo momento.") }
                }
            }
        }
    }

    private func begin() throws {
        stopAudio()
        latest = ""
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            if let text = result?.bestTranscription.formattedString { self?.latest = text }
        }
    }

    func stop(completion: @escaping (String) -> Void) {
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return completion("") }
            let text = self.latest
            self.stopAudio()
            completion(text)
        }
    }

    private func stopAudio() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

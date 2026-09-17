import SwiftUI
import Speech
import AVFoundation

/// On-device dictation and spoken replies on the iPhone.
@MainActor
final class PhoneVoice: NSObject, ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    @Published var level: CGFloat = 0
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    var onFinal: ((String) -> Void)?
    private var silence: Timer?
    private var lastChange = Date()

    func toggle() { listening ? stop(send: true) : start() }

    func start() {
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.error = "Allow Speech Recognition in Settings to talk to Nexus."; return }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in ok ? self.begin() : (self.error = "Allow Microphone access in Settings.") }
                }
            }
        }
    }

    private func begin() {
        guard let rec = SFSpeechRecognizer(), rec.isAvailable else { error = "Speech recognition unavailable."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { self.error = error.localizedDescription; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { error = "No microphone available (Simulator: use the keyboard)."; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            req.append(buf)
            guard let d = buf.floatChannelData?[0] else { return }
            var sum: Float = 0; let n = Int(buf.frameLength)
            for i in stride(from: 0, to: n, by: 8) { sum += d[i] * d[i] }
            let db = 20 * log10(max(sqrt(sum / Float(max(1, n / 8))), 0.00001))
            Task { @MainActor in self?.level = CGFloat(min(1, max(0, (db + 55) / 45))) }
        }
        engine.prepare()
        do { try engine.start() } catch { self.error = error.localizedDescription; return }
        transcript = ""; listening = true; lastChange = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        task = rec.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString; self.lastChange = Date() }
                if err != nil && self.listening && self.transcript.isEmpty { self.stop(send: false) }
            }
        }
        silence = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.listening else { return }
                if !self.transcript.isEmpty && Date().timeIntervalSince(self.lastChange) > 1.4 { self.stop(send: true) }
            }
        }
    }

    func stop(send: Bool) {
        silence?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        listening = false; level = 0
        if send && !transcript.trimmingCharacters(in: .whitespaces).isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFinal?(transcript)
        }
    }

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: String(text.prefix(260)))
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }
}

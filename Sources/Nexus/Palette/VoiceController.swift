import SwiftUI
import AVFoundation
import Speech
import NexusCore

/// Voice is a first-class way to drive Nexus:
///   • Hold the voice hotkey to talk, release to send (push-to-talk)
///   • Tap it to start; Nexus sends after you pause (hands-free)
///   • Destructive plans are read back; answer “run it” or “cancel”
///   • Results are spoken (optional)
/// Recognition runs on-device when the Mac supports it.
@MainActor
final class VoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceController()

    enum Phase: Equatable { case idle, listening, confirming, speaking }
    enum Mode { case tap, hold }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0          // 0…1, smoothed input level
    @Published var error: String?
    @Published private(set) var onDevice = false

    private(set) var mode: Mode = .tap
    /// True when the current palette command was started by voice (drives spoken confirmation & replies).
    private(set) var sessionIsVoice = false

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastChange = Date()
    private var startedAt = Date()
    private let synth = AVSpeechSynthesizer()
    private var afterSpeaking: (() -> Void)?

    private var settings: NexusSettings { AppState.shared.settings }
    var isActive: Bool { phase == .listening || phase == .confirming }

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Entry points

    /// Global hotkey pressed.
    func hotkeyDown() {
        if isActive { finish(send: true); return }
        PaletteController.shared.show()
        start(mode: .hold)
    }

    /// Global hotkey released: short press → keep listening hands-free; long press → send now.
    func hotkeyUp() {
        guard phase == .listening, mode == .hold else { return }
        if Date().timeIntervalSince(startedAt) < 0.45 {
            mode = .tap                       // it was a tap: hands-free mode
        } else {
            finish(send: true)
        }
    }

    func toggleFromUI() {
        isActive ? finish(send: !transcript.trimmed.isEmpty) : start(mode: .tap)
    }

    func cancel() {
        stopAudio()
        synth.stopSpeaking(at: .immediate)
        phase = .idle
        transcript = ""
        sessionIsVoice = false
    }

    // MARK: Listening

    func start(mode: Mode, confirming: Bool = false) {
        error = nil
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            error = "Voice needs the bundled Nexus.app (run scripts/build-app.sh)."
            return
        }
        self.mode = mode
        sessionIsVoice = true
        synth.stopSpeaking(at: .immediate)
        Task {
            guard await Self.authorize() else {
                error = "Allow Microphone and Speech Recognition for Nexus in System Settings ▸ Privacy & Security."
                return
            }
            begin(confirming: confirming)
        }
    }

    static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func begin(confirming: Bool) {
        stopAudio()
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            error = "Speech recognition isn’t available right now."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = confirming ? .confirmation : .search
        onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = ["Nexus", "Downloads", "Desktop", "Documents", "organize", "rule", "tag", "project", "invoices", "screenshots", "undo", "run it", "cancel"]
            + AppState.shared.projects.map(\.name)
        request = req

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { error = "No microphone input available."; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            let rms = Self.rms(buffer)
            Task { @MainActor in self?.level = max(rms, (self?.level ?? 0) * 0.82) }
        }
        audio.prepare()
        do { try audio.start() } catch { self.error = "Microphone error: \(error.localizedDescription)"; return }

        transcript = ""
        startedAt = Date()
        lastChange = Date()
        phase = confirming ? .confirming : .listening
        NSSound(named: "Tink")?.play()

        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript { self.transcript = text; self.lastChange = Date(); self.didHear(text) }
                    if result.isFinal && self.mode == .tap { self.finish(send: true) }
                }
                if err != nil && self.isActive && self.transcript.isEmpty { self.finish(send: false) }
            }
        }

        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSilence() }
        }
    }

    private func didHear(_ text: String) {
        if phase == .listening { PaletteController.shared.model.setTextFromVoice(text) }
        if phase == .confirming, let decision = Self.confirmation(text) {
            finishAudioOnly()
            phase = .idle
            decision ? PaletteController.shared.model.confirmFromVoice() : PaletteController.shared.model.cancelPreview()
        }
    }

    private func checkSilence() {
        guard isActive else { silenceTimer?.invalidate(); return }
        let quiet = Date().timeIntervalSince(lastChange)
        if phase == .confirming {
            if quiet > 6 { finishAudioOnly(); phase = .idle }     // no answer: leave the preview on screen
            return
        }
        if mode == .tap && settings.voiceAutoSubmit && !transcript.isEmpty && quiet > 1.3 { finish(send: true) }
        if transcript.isEmpty && Date().timeIntervalSince(startedAt) > 8 { error = "Didn’t catch that — try again."; finish(send: false) }
    }

    func finish(send: Bool) {
        let text = transcript.trimmed
        finishAudioOnly()
        phase = .idle
        guard send, !text.isEmpty else { return }
        NSSound(named: "Pop")?.play()
        PaletteController.shared.model.setTextFromVoice(text)
        PaletteController.shared.model.submit()
    }

    private func finishAudioOnly() {
        silenceTimer?.invalidate()
        stopAudio()
        level = 0
    }

    private func stopAudio() {
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    static func confirmation(_ text: String) -> Bool? {
        let t = " " + text.lowercased() + " "
        let yes = [" yes", " yeah", " yep", " run", " do it", " go ahead", " confirm", " okay", " ok ", " sure", " proceed", " apply"]
        let no = [" no", " nope", " cancel", " stop", " never mind", " nevermind", " don't", " abort"]
        if no.contains(where: t.contains) { return false }
        if yes.contains(where: t.contains) { return true }
        return nil
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(max(1, n / 4)))
        let db = 20 * log10(max(rms, 0.000_01))
        return CGFloat(min(1, max(0, (db + 55) / 45)))
    }

    // MARK: Speaking

    /// Reads a plan back and listens for “run it” / “cancel”.
    func confirm(plan: CommandPlan) {
        guard sessionIsVoice, settings.voiceConfirmBySpeech else { return }
        let steps = plan.steps.compactMap(\.note).prefix(2).joined(separator: ", then ")
        speak("\(steps). Say run it, or cancel.") { [weak self] in self?.start(mode: .tap, confirming: true) }
    }

    func reply(_ result: CommandResult) {
        defer { sessionIsVoice = false }
        guard sessionIsVoice, settings.speakResponses else { return }
        let first = result.message.split(separator: "\n").first.map(String.init) ?? result.message
        speak(first.replacingOccurrences(of: "~/", with: "").replacingOccurrences(of: "/", with: " "))
    }

    func speak(_ text: String, then: (() -> Void)? = nil) {
        guard !text.trimmed.isEmpty else { then?(); return }
        afterSpeaking = then
        phase = .speaking
        let u = AVSpeechUtterance(string: String(text.prefix(280)))
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        u.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")) ?? AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.phase == .speaking { self.phase = .idle }
            let next = self.afterSpeaking
            self.afterSpeaking = nil
            next?()
        }
    }
}

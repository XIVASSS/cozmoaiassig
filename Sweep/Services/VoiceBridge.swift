import AVFoundation
import Foundation
import Speech

/// Speaks the sentence the state machine already chose. Gemini Live is used only when it is connected.
/// If it is not, the phone speaks the same sentence. The model is not asked for titles or prices.
final class VoiceBridge: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onTranscript: ((String) -> Void)?
    private var lastHeard = ""
    private var pending = ""
    private var commit: DispatchWorkItem?
    private var generation = 0
    private let live = GeminiLiveMouth()
    private var started = false
    private var paused = false
    private var tapInstalled = false

    func start(onTranscript: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        self.onTranscript = onTranscript
        synthesizer.delegate = self
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try? audio.setActive(true)
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { self?.listen() }
        }
        live.connect()
    }

    func speak(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paused = true
        commit?.cancel()
        pending = ""
        recognitionTask?.cancel()
        audioEngine.pause()
        if live.isReady {
            live.say(trimmed)
            resumeListening(after: 1.2)
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = 0.34
        utterance.pitchMultiplier = 1
        utterance.preUtteranceDelay = 0.05
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resumeListening(after: 0.8)
    }

    private func resumeListening(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.paused = false
            self.listen()
        }
    }

    func stop() {
        audioEngine.stop()
        request?.endAudio()
        recognitionTask?.cancel()
        live.close()
        started = false
    }

    private func listen() {
        generation += 1
        let token = generation
        commit?.cancel()
        pending = ""
        recognitionTask?.cancel()
        request?.endAudio()
        guard let recognizer, recognizer.isAvailable else {
            retry(token, after: 1)
            return
        }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.taskHint = .dictation
        request = next
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            retry(token, after: 0.5)
            return
        }
        if tapInstalled {
            node.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            next.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        try? audioEngine.start()
        recognitionTask = recognizer.recognitionTask(with: next) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil
            DispatchQueue.main.async {
                guard let self, self.generation == token, !self.paused else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.consider(text, token: token)
                } else if failed {
                    self.retry(token, after: 0.4)
                }
            }
        }
    }

    /// The recognizer keeps the sentence open while the mic is open, so a short pause is the end of what the person said.
    private func consider(_ text: String, token: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed != lastHeard else { return }
        pending = trimmed
        commit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.paused else { return }
            let said = self.pending
            guard said.count >= 2, said != self.lastHeard else { return }
            self.lastHeard = said
            self.pending = ""
            self.onTranscript?(said)
            self.listen()
        }
        commit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func retry(_ token: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token, !self.paused else { return }
            self.listen()
        }
    }
}

final class GeminiLiveMouth: NSObject, URLSessionWebSocketDelegate {
    private(set) var isReady = false
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let player = AVAudioPlayerNode()
    private let engine = AVAudioEngine()
    private var prepared = false

    func connect() {
        guard !AppSecrets.geminiAPIKey.isEmpty, socket == nil else { return }
        guard var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent") else { return }
        components.queryItems = [URLQueryItem(name: "key", value: AppSecrets.geminiAPIKey)]
        guard let url = components.url else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        let model = AppSecrets.geminiLiveModel
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"]
                ],
                "systemInstruction": [
                    "parts": [[
                        "text": "Speak slowly. Say only the exact sentence you are given. Add nothing. Do not name a book, a price, or a measurement."
                    ]]
                ]
            ]
        ]
        send(setup)
        receive()
    }

    func say(_ line: String) {
        let payload: [String: Any] = [
            "clientContent": [
                "turns": [[
                    "role": "user",
                    "parts": [["text": "Say exactly this and nothing else: \(line)"]]
                ]],
                "turnComplete": true
            ]
        ]
        send(payload)
    }

    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isReady = false
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isReady = false
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            if case .success(let message) = result {
                let text: String?
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text, let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if json["setupComplete"] != nil { self.isReady = true }
                    self.playAudio(in: json)
                }
                self.receive()
            } else {
                self.isReady = false
            }
        }
    }

    private func playAudio(in json: [String: Any]) {
        guard let server = json["serverContent"] as? [String: Any],
              let turn = server["modelTurn"] as? [String: Any],
              let parts = turn["parts"] as? [[String: Any]] else { return }
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any],
                  let encoded = inline["data"] as? String,
                  let audio = Data(base64Encoded: encoded) else { continue }
            DispatchQueue.main.async { self.play(pcm: audio) }
        }
    }

    private func play(pcm: Data) {
        if !prepared {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)
            guard let format else { return }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try? engine.start()
            player.play()
            prepared = true
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true) else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            guard let address = raw.baseAddress, let channel = buffer.int16ChannelData else { return }
            channel[0].update(from: address.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        player.scheduleBuffer(buffer)
    }
}

enum IntentClassifier {
    static func classify(_ text: String) async -> Correction {
        let local = CorrectionParser.parse(text)
        if local != .none || AppSecrets.geminiAPIKey.isEmpty { return local }
        guard var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppSecrets.geminiTextModel):generateContent") else { return .none }
        components.queryItems = [URLQueryItem(name: "key", value: AppSecrets.geminiAPIKey)]
        guard let url = components.url else { return .none }
        let prompt = "Classify this utterance as exactly one of confirm_hunch, first_edition, skip_shelf, is_print, is_original, set_us_usd, none. Reply with JSON {\"intent\":\"...\"} only. Do not invent a title or a price. Utterance: \(text)"
        let body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 8
        guard let data = try? await URLSession.shared.data(for: request).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let raw = parts.first?["text"] as? String else { return .none }
        if raw.contains("confirm_hunch") { return .confirmHunch }
        if raw.contains("first_edition") { return .firstEdition }
        if raw.contains("skip_shelf") { return .skipShelf }
        if raw.contains("is_print") { return .isPrint }
        if raw.contains("is_original") { return .isOriginal }
        if raw.contains("set_us_usd") { return .countryUSD }
        return .none
    }
}

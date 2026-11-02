import Foundation

enum AppSecrets {
    static var geminiAPIKey: String { value("GeminiAPIKey") }
    static var googleBooksAPIKey: String { value("GoogleBooksAPIKey") }
    static var abeBooksClientKey: String { value("AbeBooksClientKey") }
    static var geminiLiveModel: String {
        let model = value("GeminiLiveModel")
        return model.isEmpty ? "gemini-2.5-flash-native-audio-preview-12-2025" : model
    }
    static var geminiTextModel: String {
        let model = value("GeminiTextModel")
        return model.isEmpty ? "gemini-2.5-flash" : model
    }

    private static func value(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        if raw.hasPrefix("$(") { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

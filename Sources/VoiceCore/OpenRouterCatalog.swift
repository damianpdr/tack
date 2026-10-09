import Foundation

public enum OpenRouterCatalog {
    static let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=transcription")!

    private struct Response: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    public static func transcriptionModels(session: URLSession = .shared) async throws -> [String] {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TranscriptionError.http(status: status, message: OpenRouterEngine.snippet(data))
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.invalidResponse(OpenRouterEngine.snippet(data))
        }
        return decoded.data.map(\.id).sorted()
    }
}

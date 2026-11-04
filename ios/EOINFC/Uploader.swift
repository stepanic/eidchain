import Foundation

/// Sends the probe log to the Mac over Tailscale, so results reach the
/// development session without copy-pasting from the phone.
enum Uploader {
    static let url = URL(string: "https://ms.tailf0e6eb.ts.net/eoinfc/log")!

    static func send(_ text: String) async -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(text.utf8)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return "Poslano (\((resp as? HTTPURLResponse)?.statusCode ?? 0))"
        } catch {
            return "Greška: \(error.localizedDescription)"
        }
    }
}

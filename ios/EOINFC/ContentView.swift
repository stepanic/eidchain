import SwiftUI

struct ContentView: View {
    @StateObject private var probe = Probe()
    @State private var sent = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Button("Prisloni osobnu") { probe.start() }
                    .buttonStyle(.borderedProminent)
                ScrollView {
                    Text(probe.log.isEmpty ? "Log je prazan." : probe.log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Kopiraj") { UIPasteboard.general.string = probe.log }
                    Spacer()
                    Button("Pošalji na Mac") { Task { sent = await Uploader.send(probe.log) } }
                }
                if !sent.isEmpty { Text(sent).font(.caption) }
            }
            .padding()
            .navigationTitle("eOI NFC")
        }
    }
}

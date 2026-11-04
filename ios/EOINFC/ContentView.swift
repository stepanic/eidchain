import SwiftUI

struct ContentView: View {
    @StateObject private var probe = Probe()
    @State private var sent = ""
    @State private var can = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Button("Proba bez CAN-a") { probe.start() }
                    .buttonStyle(.bordered)
                HStack {
                    TextField("CAN (6 znamenki)", text: $can)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button("PACE") { probe.start(can: can) }
                        .buttonStyle(.borderedProminent)
                        .disabled(can.count != 6)
                }
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

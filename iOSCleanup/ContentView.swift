import SwiftUI

struct ContentView: View {
    @State private var output = "Tap a button to scan"
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Photos") { Task { await runPhotoScan() } }
                    Button("Contacts") { Task { await runContactScan() } }
                    Button("Files") { Task { await runFileScan() } }
                }
                #endif
            }
            .navigationTitle("iOSCleanup Debug")
        }
        .disabled(isScanning)
    }

    private func runPhotoScan() async {
        isScanning = true
        let start = Date()
        let engine = PhotoScanEngine()
        var groups: [PhotoGroup] = []
        for await result in engine.scan() {
            switch result {
            case .success(let g): groups = g
            case .failure(let e): output = "Photo scan error: \(e)"; isScanning = false; return
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let photoCount = groups.reduce(0) { $0 + $1.assets.count }
        output = "Found \(groups.count) groups (\(photoCount) photos) in \(String(format: "%.1f", elapsed))s"
        isScanning = false
    }

    private func runContactScan() async {
        isScanning = true
        let start = Date()
        let engine = ContactScanEngine()
        do {
            let matches = try await engine.scan()
            let elapsed = Date().timeIntervalSince(start)
            output = "Found \(matches.count) duplicate contact pairs in \(String(format: "%.1f", elapsed))s"
        } catch {
            output = "Contact scan error: \(error)"
        }
        isScanning = false
    }

    private func runFileScan() async {
        isScanning = true
        let start = Date()
        let engine = FileScanEngine()
        do {
            let files = try await engine.scan()
            let elapsed = Date().timeIntervalSince(start)
            let totalBytes = files.reduce(Int64(0)) { $0 + $1.byteSize }
            let formatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            output = "Found \(files.count) large files (\(formatted) total) in \(String(format: "%.1f", elapsed))s"
        } catch {
            output = "File scan error: \(error)"
        }
        isScanning = false
    }
}

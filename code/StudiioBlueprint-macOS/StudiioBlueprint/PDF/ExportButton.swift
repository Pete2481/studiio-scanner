import SwiftUI

/// Toolbar button that triggers PDF export with a save dialog.
struct ExportButton: View {
    let project: PropertyProject

    @State private var isExporting = false
    @State private var showSavePanel = false
    @State private var exportError: String?

    var body: some View {
        Button {
            exportPDF()
        } label: {
            HStack(spacing: 4) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                }
                Image(systemName: "arrow.down.doc")
                Text("Export PDF")
            }
        }
        .disabled(isExporting)
        .alert("Export Error", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.title = "Export Blueprint PDF"
        panel.nameFieldStringValue = "\(project.address ?? "Blueprint").pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            isExporting = true
            let capturedProject = project

            Task { @MainActor in
                let pdfData = PDFExporter.exportProject(project: capturedProject)
                do {
                    try PDFExporter.savePDF(data: pdfData, to: url)
                    isExporting = false
                    NSWorkspace.shared.open(url)
                } catch {
                    exportError = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }
}

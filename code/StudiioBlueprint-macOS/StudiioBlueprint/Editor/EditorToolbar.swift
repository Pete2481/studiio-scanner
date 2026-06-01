import SwiftUI

/// Toolbar for the blueprint editor with mode selection and actions.
struct EditorToolbar: View {
    @Binding var editMode: EditMode
    @Binding var showEditor: Bool
    var onExportPDF: () -> Void

    enum EditMode: String, CaseIterable {
        case select = "Select"
        case moveRoom = "Move Room"
        case verifyDimension = "Verify Dimension"

        var icon: String {
            switch self {
            case .select: return "cursorarrow"
            case .moveRoom: return "arrow.up.and.down.and.arrow.left.and.right"
            case .verifyDimension: return "ruler"
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mode picker
            ForEach(EditMode.allCases, id: \.self) { mode in
                Button {
                    editMode = mode
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                        Text(mode.rawValue)
                    }
                    .font(.caption)
                    .foregroundColor(editMode == mode ? .white : StudiioTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(editMode == mode ? StudiioTheme.accentOrange : StudiioTheme.backgroundElevated)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Actions
            Button {
                onExportPDF()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                    Text("Export PDF")
                }
                .font(.caption.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(StudiioTheme.accentOrange))
            }
            .buttonStyle(.plain)

            Button {
                showEditor = false
            } label: {
                Text("Done")
                    .font(.caption.weight(.medium))
                    .foregroundColor(StudiioTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(StudiioTheme.backgroundSecondary)
    }
}

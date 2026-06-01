import Foundation
import Network

/// Bonjour listener that accepts incoming .studiio bundles from iPhones on the local network.
/// Advertises as _studiio._tcp so the iOS app can discover this Mac.
@MainActor
final class BonjourListener: ObservableObject {

    @Published var isListening = false
    @Published var lastReceivedProject: PropertyProject?

    private var listener: NWListener?
    private let importer: ProjectImporter

    init(importer: ProjectImporter) {
        self.importer = importer
    }

    // MARK: - Start/Stop

    func startListening() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: "Studiio Blueprint",
                type: "_studiio._tcp"
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isListening = true
                    case .failed, .cancelled:
                        self?.isListening = false
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            isListening = false
        }
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        // Receive all data (up to 50MB max for a .studiio bundle)
        let maxSize = 50 * 1024 * 1024
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxSize) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self, let data = data, error == nil else {
                    connection.cancel()
                    return
                }

                self.processReceivedData(data)
                if isComplete {
                    connection.cancel()
                }
            }
        }
    }

    private func processReceivedData(_ data: Data) {
        // Write to a temporary file and import
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("studiio")

        do {
            try data.write(to: tempURL)
            let project = try importer.importProject(from: tempURL)
            lastReceivedProject = project
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}

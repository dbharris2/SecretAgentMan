import Foundation

struct CodexSessionFileMetadata: Equatable {
    var rawModelName: String?
    var collaborationMode: CodexCollaborationMode
    var contextPercentUsed: Double

    init(
        rawModelName: String? = nil,
        collaborationMode: CodexCollaborationMode = .default,
        contextPercentUsed: Double = 0
    ) {
        self.rawModelName = rawModelName
        self.collaborationMode = collaborationMode
        self.contextPercentUsed = contextPercentUsed
    }
}

private enum CodexSessionMetadataScanner {
    static let chunkSize = 64 * 1024
    static let maxLineBytes = 1024 * 1024
}

extension CodexAppServerMonitor {
    nonisolated static func sessionFileMetadata(
        atPath path: String,
        initial: CodexSessionFileMetadata = CodexSessionFileMetadata()
    ) -> CodexSessionFileMetadata {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return initial
        }
        defer { try? handle.close() }

        var metadata = initial
        var buffer = Data()
        var droppingOversizedLine = false

        while true {
            let chunk = handle.readData(ofLength: CodexSessionMetadataScanner.chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            processSessionMetadataBuffer(
                &buffer,
                droppingOversizedLine: &droppingOversizedLine,
                metadata: &metadata
            )
        }

        if !droppingOversizedLine, !buffer.isEmpty {
            processSessionMetadataLine(buffer, metadata: &metadata)
        }

        return metadata
    }

    private nonisolated static func processSessionMetadataBuffer(
        _ buffer: inout Data,
        droppingOversizedLine: inout Bool,
        metadata: inout CodexSessionFileMetadata
    ) {
        while true {
            if droppingOversizedLine {
                guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                    buffer.removeAll(keepingCapacity: true)
                    return
                }
                buffer.removeSubrange(...newlineIndex)
                droppingOversizedLine = false
                continue
            }

            guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { break }
            let lineData = Data(buffer.prefix(upTo: newlineIndex))
            processSessionMetadataLine(lineData, metadata: &metadata)
            buffer.removeSubrange(...newlineIndex)
        }

        if !droppingOversizedLine, buffer.count > CodexSessionMetadataScanner.maxLineBytes {
            buffer.removeAll(keepingCapacity: true)
            droppingOversizedLine = true
        }
    }

    private nonisolated static func processSessionMetadataLine(
        _ lineData: Data,
        metadata: inout CodexSessionFileMetadata
    ) {
        guard !lineData.isEmpty,
              lineData.count <= CodexSessionMetadataScanner.maxLineBytes,
              shouldParseSessionMetadataLine(lineData),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        if let rawModelName = rawModelName(fromSessionEvent: object) {
            metadata.rawModelName = rawModelName
        }
        if let mode = collaborationMode(fromSessionEvent: object) {
            metadata.collaborationMode = mode
        }
        if let contextPercent = contextPercentUsed(fromSessionEvent: object) {
            metadata.contextPercentUsed = contextPercent
        }
    }

    private nonisolated static func shouldParseSessionMetadataLine(_ lineData: Data) -> Bool {
        guard let header = String(bytes: lineData.prefix(512), encoding: .utf8) else { return false }
        return header.contains(#""type":"turn_context""#)
            || header.contains(#""type": "turn_context""#)
            || header.contains(#""type":"event_msg""#)
            || header.contains(#""type": "event_msg""#)
    }
}

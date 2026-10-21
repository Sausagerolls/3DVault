import Foundation
import UniformTypeIdentifiers

/// Streams a multipart/form-data body to a temp file so large uploads never sit in memory.
struct MultipartBody {
    let boundary = "vault-\(UUID().uuidString)"
    let fileURL: URL
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    init(files: [(field: String, url: URL)], fields: [(String, String)]) throws {
        fileURL = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: fileURL)
        defer { try? out.close() }
        func write(_ s: String) throws { try out.write(contentsOf: Data(s.utf8)) }

        for (name, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        for (field, url) in files {
            let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: url)
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try input.close()
            try write("\r\n")
        }
        try write("--\(boundary)--\r\n")
    }
}

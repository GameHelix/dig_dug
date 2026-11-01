import Foundation
import zlib

/// Decodes gzip bodies with the system zlib, the way Go's gzip reader does: every member of a
/// multi-member stream, each checked against its CRC-32 and length.
enum Gzip {
    private enum Outcome {
        case decoded
        case failed(String)
    }

    static func decode(_ data: Data) throws(LessonHTTPError) -> Data {
        // An empty body reads as empty in Go, not as an error.
        if data.isEmpty { return data }
        var stream = z_stream()
        // 15 + 16: the largest window, and only the gzip format.
        guard inflateInit2_(&stream, 15 + 16, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw .invalidResponse("gzip: the decoder could not start")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunk = 64 << 10
        let scratch = UnsafeMutablePointer<Bytef>.allocate(capacity: chunk)
        defer { scratch.deallocate() }

        let outcome = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Outcome in
            guard let base = input.baseAddress else { return .decoded }
            stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)
            while true {
                stream.next_out = scratch
                stream.avail_out = uInt(chunk)
                let status = inflate(&stream, Z_NO_FLUSH)
                output.append(scratch, count: chunk - Int(stream.avail_out))
                switch status {
                case Z_STREAM_END:
                    if stream.avail_in == 0 { return .decoded }
                    // Another member follows.
                    guard inflateReset(&stream) == Z_OK else { return .failed("gzip: the decoder could not restart") }
                case Z_OK:
                    continue
                case Z_BUF_ERROR:
                    return .failed("gzip: the body ended in the middle of the stream")
                default:
                    let reason = stream.msg.map { String(cString: $0) } ?? "status \(status)"
                    return .failed("gzip: \(reason)")
                }
            }
        }
        switch outcome {
        case .decoded: return output
        case .failed(let message): throw .invalidResponse(message)
        }
    }
}

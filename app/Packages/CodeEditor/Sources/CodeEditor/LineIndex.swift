import Foundation

/// Where each line starts, so the gutter can number a line without counting from the top.
/// Lines end where TextKit 2 paragraphs end: LF, CR, CRLF and U+2029.
struct LineIndex {
    /// The UTF-16 offset of each line's first character. The first line starts at 0.
    private(set) var starts: [Int] = [0]
    /// The length of the indexed text, in UTF-16 code units.
    private(set) var length = 0

    init() {}

    init(_ text: NSString) {
        length = text.length
        starts = [0] + Self.lineStarts(in: text, from: 0, to: length)
    }

    var count: Int { starts.count }

    /// Updates the index after an edit: `oldRange` of the old text became `newLength` code
    /// units, and `text` is the new text. Only the lines around the edit are read again.
    mutating func replaceCharacters(in oldRange: NSRange, newLength: Int, text: NSString) {
        let delta = newLength - oldRange.length
        // Start a line early: the edit may join a CR at the end of that line with a LF.
        let firstLine = max(0, line(containing: oldRange.location) - 1)
        // Keep going one line past the edit, for the same reason at the other end.
        let nextLine = min(line(containing: NSMaxRange(oldRange)) + 2, starts.count)
        let scanStart = starts[firstLine]
        let scanEnd = (nextLine < starts.count ? starts[nextLine] : length) + delta

        var updated = Array(starts[...firstLine])
        updated.reserveCapacity(starts.count + 8)
        updated += Self.lineStarts(in: text, from: scanStart, to: scanEnd).filter { $0 < scanEnd || nextLine == starts.count }
        updated += starts[nextLine...].map { $0 + delta }
        starts = updated
        length += delta
    }

    /// The zero-based line that holds a UTF-16 offset.
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Where a line's characters end, before its line break. `text` is the indexed text.
    func contentEnd(of line: Int, in text: NSString) -> Int {
        guard line + 1 < starts.count else { return length }
        let next = starts[line + 1]
        // A CRLF is one break of two characters.
        let crlf = next - 2 >= starts[line] && text.character(at: next - 1) == 0x0A && text.character(at: next - 2) == 0x0D
        return next - (crlf ? 2 : 1)
    }

    /// The zero-based lines a selection touches. A selection that ends where a line starts does
    /// not touch that line.
    func lines(covering selection: NSRange) -> ClosedRange<Int> {
        let first = line(containing: selection.location)
        let last = selection.length > 0 ? line(containing: NSMaxRange(selection) - 1) : first
        return first...max(first, last)
    }

    /// The offsets after each line break in `start..<end`. A CR that ends the range counts as a
    /// break unless a LF follows it in the text.
    private static func lineStarts(in text: NSString, from start: Int, to end: Int) -> [Int] {
        var result: [Int] = []
        guard end > start else { return result }
        let textLength = text.length
        var buffer = [unichar](repeating: 0, count: min(8192, end - start))
        var chunkStart = start
        while chunkStart < end {
            let count = min(buffer.count, end - chunkStart)
            buffer.withUnsafeMutableBufferPointer { characters in
                guard let base = characters.baseAddress else { return }
                text.getCharacters(base, range: NSRange(location: chunkStart, length: count))
                for index in 0..<count {
                    let offset = chunkStart + index
                    switch characters[index] {
                    case 0x0A, 0x2029:
                        result.append(offset + 1)
                    case 0x0D:
                        // A CR followed by a LF ends the line after the LF.
                        let next: unichar = if index + 1 < count {
                            characters[index + 1]
                        } else if offset + 1 < textLength {
                            text.character(at: offset + 1)
                        } else {
                            0
                        }
                        if next != 0x0A {
                            result.append(offset + 1)
                        }
                    default:
                        break
                    }
                }
            }
            chunkStart += count
        }
        return result
    }
}

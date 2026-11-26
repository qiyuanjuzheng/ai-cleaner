#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 严格只读、零外部依赖的纯 Swift Zstandard（RFC 8878）流式头部解压器。
/// 面向 Codex（`.jsonl.zst`）与 DeepSeek Harness（`.jsonl.zstd`）等压缩会话归档，
/// 限制读取与解压字节上限，不落盘、不修改原文件，遇到损坏/截断/带外部字典的数据时优雅降级。
public enum ZstandardDecoder {
    private static let zstdMagic: UInt32 = 0xFD2F_B528
    private static let skippableMagicMask: UInt32 = 0xFFFF_FFF0
    private static let skippableMagicBase: UInt32 = 0x184D_2A50
    private static let maxBlockSize = 128 * 1024
    private static let maxWindowLog = 31
    private static let maxHuffmanTableLog = 11
    private static let maxHuffmanWeights = 255

    /// 从内存中的 Zstandard 字节流解压至多 `maxOutputBytes` 字节（支持多帧与头部截断流）。
    /// - Parameters:
    ///   - data: 压缩字节流（可为大文件的头部截断切片）
    ///   - maxOutputBytes: 最大输出解压字节数上限
    ///   - shouldStop: 可选的按块提前终止回调（接收当前已解压的累计字节数组；返回 `true` 时立即停止后续块解压）
    /// - Returns: 成功解压的前缀数据；若无任何有效数据可解压或魔数不匹配，返回 `nil`。
    public static func decompressPrefix(
        from data: Data,
        maxOutputBytes: Int = 393_216,
        shouldStop: (([UInt8]) -> Bool)? = nil
    ) -> Data? {
        guard maxOutputBytes > 0, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        var cursor = 0
        var output: [UInt8] = []
        output.reserveCapacity(min(maxOutputBytes, max(4096, bytes.count * 2)))
        var decodedAnyFrame = false

        while cursor + 4 <= bytes.count && output.count < maxOutputBytes {
            let magic = readUInt32LE(bytes, at: cursor)

            if (magic & skippableMagicMask) == skippableMagicBase {
                guard cursor + 8 <= bytes.count else { break }
                let skipSize = Int(readUInt32LE(bytes, at: cursor + 4))
                let nextCursor = cursor + 8 + skipSize
                guard skipSize >= 0, nextCursor >= cursor + 8, nextCursor <= bytes.count else { break }
                cursor = nextCursor
                continue
            }

            guard magic == zstdMagic else {
                break
            }

            let frameResult = decodeFrame(
                bytes: bytes,
                cursor: &cursor,
                output: &output,
                maxOutputBytes: maxOutputBytes,
                shouldStop: shouldStop
            )
            if frameResult.producedBytes {
                decodedAnyFrame = true
            }
            if frameResult.stoppedEarly || !frameResult.completedFrame {
                break
            }
        }

        guard decodedAnyFrame || !output.isEmpty else {
            return nil
        }
        return Data(output)
    }

    /// 严格只读地从本地常规文件读取头部至多 `maxCompressedBytes` 字节并解压前 `maxOutputBytes` 字节。
    public static func decompressFilePrefix(
        at url: URL,
        maxCompressedBytes: Int = 262_144,
        maxOutputBytes: Int = 393_216,
        platform: (any PlatformAdapter)? = nil,
        shouldStop: (([UInt8]) -> Bool)? = nil
    ) -> Data? {
        guard maxCompressedBytes > 0, maxOutputBytes > 0 else { return nil }
        let platform = platform ?? HostPlatformAdapter.shared
        guard let reader = platform.openReadOnlyRegularFile(at: url) else { return nil }
        defer { reader.close() }
        guard let compressed = reader.read(upToCount: maxCompressedBytes), !compressed.isEmpty else { return nil }
        return decompressPrefix(from: compressed, maxOutputBytes: maxOutputBytes, shouldStop: shouldStop)
    }

    // MARK: - Frame Decoding

    private struct FrameDecodeResult {
        let producedBytes: Bool
        let completedFrame: Bool
        let stoppedEarly: Bool
    }

    private struct FrameContext {
        var huffmanTable: HuffmanTable?
        var llTable: FSETable?
        var ofTable: FSETable?
        var mlTable: FSETable?
        var repeatOffsets: (Int, Int, Int) = (1, 4, 8)
    }

    private static func decodeFrame(
        bytes: [UInt8],
        cursor: inout Int,
        output: inout [UInt8],
        maxOutputBytes: Int,
        shouldStop: (([UInt8]) -> Bool)?
    ) -> FrameDecodeResult {
        let startOutputCount = output.count
        guard cursor + 5 <= bytes.count else {
            return FrameDecodeResult(producedBytes: false, completedFrame: false, stoppedEarly: false)
        }
        cursor += 4 // skip magic

        let fhd = bytes[cursor]
        cursor += 1

        let fcsFlag = Int((fhd >> 6) & 0x03)
        let singleSegment = ((fhd >> 5) & 0x01) != 0
        let reservedBit = (fhd >> 3) & 0x01
        let hasContentChecksum = ((fhd >> 2) & 0x01) != 0
        let dictIDFlag = Int(fhd & 0x03)

        guard reservedBit == 0 else {
            return FrameDecodeResult(producedBytes: false, completedFrame: false, stoppedEarly: false)
        }

        var windowSize: UInt64 = 0
        if !singleSegment {
            guard cursor < bytes.count else {
                return FrameDecodeResult(producedBytes: false, completedFrame: false, stoppedEarly: false)
            }
            let wd = bytes[cursor]
            cursor += 1
            let exponent = Int(wd >> 3)
            let mantissa = UInt64(wd & 0x07)
            let windowLog = 10 + exponent
            guard windowLog <= maxWindowLog else {
                return FrameDecodeResult(producedBytes: false, completedFrame: false, stoppedEarly: false)
            }
            let base = UInt64(1) << windowLog
            windowSize = base + (base / 8) * mantissa
        }

        let dictIDSize = [0, 1, 2, 4][dictIDFlag]
        guard cursor + dictIDSize <= bytes.count else {
            return FrameDecodeResult(producedBytes: false, completedFrame: false, stoppedEarly: false)
        }
        var dictID: UInt32 = 0
        for i in 0..<dictIDSize {
            dictID |= UInt32(bytes[cursor + i]) << (i * 8)
        }
        cursor += dictIDSize
        // 外部字典归档不支持，优雅降级
        guard dictID == 0 else {
            return FrameDecodeResult(producedBytes: false, completedFrame: false, stoppedEarly: false)
        }

        let fcsSize: Int
        switch fcsFlag {
        case 0: fcsSize = singleSegment ? 1 : 0
        case 1: fcsSize = 2
        case 2: fcsSize = 4
        case 3: fcsSize = 8
        default: fcsSize = 0
        }
        guard cursor + fcsSize <= bytes.count else {
            return FrameDecodeResult(producedBytes: false, completedFrame: false, stoppedEarly: false)
        }
        var frameContentSize: UInt64?
        switch fcsSize {
        case 1:
            frameContentSize = UInt64(bytes[cursor])
        case 2:
            frameContentSize = UInt64(readUInt16LE(bytes, at: cursor)) + 256
        case 4:
            frameContentSize = UInt64(readUInt32LE(bytes, at: cursor))
        case 8:
            let lo = UInt64(readUInt32LE(bytes, at: cursor))
            let hi = UInt64(readUInt32LE(bytes, at: cursor + 4))
            frameContentSize = lo | (hi << 32)
        default:
            break
        }
        cursor += fcsSize

        if singleSegment {
            windowSize = frameContentSize ?? UInt64(maxBlockSize)
        }

        var context = FrameContext()
        var frameOutput: [UInt8] = []
        let remainingBudget = maxOutputBytes - output.count
        frameOutput.reserveCapacity(min(remainingBudget, Int(min(frameContentSize ?? UInt64(remainingBudget), UInt64(remainingBudget)))))

        var lastBlock = false
        var stoppedEarly = false
        while !lastBlock && frameOutput.count < remainingBudget {
            guard cursor + 3 <= bytes.count else {
                appendCapped(&output, from: frameOutput, maxOutputBytes: maxOutputBytes)
                return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
            }
            let blockHeader = Int(bytes[cursor])
                | (Int(bytes[cursor + 1]) << 8)
                | (Int(bytes[cursor + 2]) << 16)
            cursor += 3

            lastBlock = (blockHeader & 1) != 0
            let blockType = (blockHeader >> 1) & 0x03
            let blockSize = blockHeader >> 3

            switch blockType {
            case 0: // Raw_Block
                guard blockSize <= maxBlockSize, cursor + blockSize <= bytes.count else {
                    appendCapped(&output, from: frameOutput, maxOutputBytes: maxOutputBytes)
                    return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
                }
                let toCopy = min(blockSize, remainingBudget - frameOutput.count)
                if toCopy > 0 {
                    frameOutput.append(contentsOf: bytes[cursor..<(cursor + toCopy)])
                }
                cursor += blockSize

            case 1: // RLE_Block
                guard blockSize <= maxBlockSize, cursor + 1 <= bytes.count else {
                    appendCapped(&output, from: frameOutput, maxOutputBytes: maxOutputBytes)
                    return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
                }
                let repeatedByte = bytes[cursor]
                cursor += 1
                let toAppend = min(blockSize, remainingBudget - frameOutput.count)
                if toAppend > 0 {
                    frameOutput.append(contentsOf: repeatElement(repeatedByte, count: toAppend))
                }

            case 2: // Compressed_Block
                guard blockSize <= maxBlockSize, cursor + blockSize <= bytes.count else {
                    appendCapped(&output, from: frameOutput, maxOutputBytes: maxOutputBytes)
                    return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
                }
                let blockEnd = cursor + blockSize
                let ok = decodeCompressedBlock(
                    bytes: bytes,
                    start: cursor,
                    end: blockEnd,
                    windowSize: windowSize,
                    context: &context,
                    frameOutput: &frameOutput,
                    maxFrameOutputBytes: remainingBudget
                )
                cursor = blockEnd
                guard ok else {
                    appendCapped(&output, from: frameOutput, maxOutputBytes: maxOutputBytes)
                    return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
                }

            default: // Reserved
                appendCapped(&output, from: frameOutput, maxOutputBytes: maxOutputBytes)
                return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
            }

            if !lastBlock, let shouldStop, !frameOutput.isEmpty {
                if output.isEmpty {
                    if shouldStop(frameOutput) {
                        stoppedEarly = true
                        break
                    }
                } else {
                    var combined = output
                    appendCapped(&combined, from: frameOutput, maxOutputBytes: maxOutputBytes)
                    if shouldStop(combined) {
                        stoppedEarly = true
                        break
                    }
                }
            }
        }

        appendCapped(&output, from: frameOutput, maxOutputBytes: maxOutputBytes)

        if stoppedEarly {
            return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: true)
        }

        if lastBlock {
            if hasContentChecksum {
                guard cursor + 4 <= bytes.count else {
                    return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
                }
                cursor += 4
            }
            return FrameDecodeResult(producedBytes: output.count > startOutputCount || frameContentSize == 0, completedFrame: true, stoppedEarly: false)
        }

        return FrameDecodeResult(producedBytes: output.count > startOutputCount, completedFrame: false, stoppedEarly: false)
    }

    private static func appendCapped(_ dst: inout [UInt8], from src: [UInt8], maxOutputBytes: Int) {
        let space = maxOutputBytes - dst.count
        guard space > 0, !src.isEmpty else { return }
        if src.count <= space {
            dst.append(contentsOf: src)
        } else {
            dst.append(contentsOf: src[0..<space])
        }
    }

    // MARK: - Compressed Block Decoding

    private static func decodeCompressedBlock(
        bytes: [UInt8],
        start: Int,
        end: Int,
        windowSize: UInt64,
        context: inout FrameContext,
        frameOutput: inout [UInt8],
        maxFrameOutputBytes: Int
    ) -> Bool {
        var pos = start
        guard let literals = decodeLiteralsSection(
            bytes: bytes,
            pos: &pos,
            end: end,
            context: &context
        ) else {
            return false
        }

        guard pos < end else {
            return false
        }

        let numSequences: Int
        let firstSeqByte = Int(bytes[pos])
        pos += 1
        if firstSeqByte == 0 {
            numSequences = 0
        } else if firstSeqByte < 128 {
            numSequences = firstSeqByte
        } else if firstSeqByte < 255 {
            guard pos < end else { return false }
            numSequences = ((firstSeqByte - 128) << 8) + Int(bytes[pos])
            pos += 1
        } else {
            guard pos + 2 <= end else { return false }
            numSequences = Int(bytes[pos]) + (Int(bytes[pos + 1]) << 8) + 0x7F00
            pos += 2
        }

        if numSequences == 0 {
            appendCapped(&frameOutput, from: literals, maxOutputBytes: maxFrameOutputBytes)
            return true
        }

        guard pos < end else { return false }
        let modesByte = bytes[pos]
        pos += 1
        guard (modesByte & 0x03) == 0 else { return false }

        let llMode = Int((modesByte >> 6) & 0x03)
        let ofMode = Int((modesByte >> 4) & 0x03)
        let mlMode = Int((modesByte >> 2) & 0x03)

        guard let llTable = resolveSequenceTable(
            mode: llMode,
            predefined: predefinedLLTable,
            previous: context.llTable,
            maxAccuracyLog: 9,
            maxSymbol: 35,
            bytes: bytes,
            pos: &pos,
            end: end
        ),
        let ofTable = resolveSequenceTable(
            mode: ofMode,
            predefined: predefinedOFTable,
            previous: context.ofTable,
            maxAccuracyLog: 8,
            maxSymbol: 31,
            bytes: bytes,
            pos: &pos,
            end: end
        ),
        let mlTable = resolveSequenceTable(
            mode: mlMode,
            predefined: predefinedMLTable,
            previous: context.mlTable,
            maxAccuracyLog: 9,
            maxSymbol: 52,
            bytes: bytes,
            pos: &pos,
            end: end
        ) else {
            return false
        }

        context.llTable = llTable
        context.ofTable = ofTable
        context.mlTable = mlTable

        guard var bitReader = BackwardBitReader(bytes: bytes, start: pos, end: end) else {
            return false
        }

        guard var llState = bitReader.readBits(llTable.accuracyLog),
              var ofState = bitReader.readBits(ofTable.accuracyLog),
              var mlState = bitReader.readBits(mlTable.accuracyLog) else {
            return false
        }

        var litIndex = 0
        var rep = context.repeatOffsets
        let llEntries = llTable.entries
        let ofEntries = ofTable.entries
        let mlEntries = mlTable.entries
        let maxWindowCheck = max(windowSize, UInt64(maxFrameOutputBytes))

        for seqIndex in 0..<numSequences {
            guard llState < llEntries.count,
                  ofState < ofEntries.count,
                  mlState < mlEntries.count else {
                return false
            }
            let llEntry = llEntries[llState]
            let ofEntry = ofEntries[ofState]
            let mlEntry = mlEntries[mlState]

            let ofCode = Int(ofEntry.symbol)
            let mlCode = Int(mlEntry.symbol)
            let llCode = Int(llEntry.symbol)

            guard ofCode <= 31, mlCode < matchLengthTable.count, llCode < literalLengthTable.count else {
                return false
            }

            guard let ofExtra = bitReader.readBits(ofCode) else { return false }
            let offsetValue = (1 << ofCode) + ofExtra

            let mlSpec = matchLengthTable[mlCode]
            guard let mlExtra = bitReader.readBits(mlSpec.bits) else { return false }
            let matchLength = mlSpec.baseline + mlExtra

            let llSpec = literalLengthTable[llCode]
            guard let llExtra = bitReader.readBits(llSpec.bits) else { return false }
            let literalLength = llSpec.baseline + llExtra

            if seqIndex + 1 < numSequences {
                guard let llBits = bitReader.readBits(Int(llEntry.nbBits)),
                      let mlBits = bitReader.readBits(Int(mlEntry.nbBits)),
                      let ofBits = bitReader.readBits(Int(ofEntry.nbBits)) else {
                    return false
                }
                llState = Int(llEntry.newStateBase) + llBits
                mlState = Int(mlEntry.newStateBase) + mlBits
                ofState = Int(ofEntry.newStateBase) + ofBits
            }

            let actualOffset: Int
            if ofCode > 1 {
                actualOffset = offsetValue - 3
                rep = (actualOffset, rep.0, rep.1)
            } else if literalLength == 0 {
                switch offsetValue {
                case 1:
                    actualOffset = rep.1
                    rep = (actualOffset, rep.0, rep.2)
                case 2:
                    actualOffset = rep.2
                    rep = (actualOffset, rep.0, rep.1)
                case 3:
                    actualOffset = rep.0 - 1
                    guard actualOffset >= 1 else { return false }
                    rep = (actualOffset, rep.0, rep.1)
                default:
                    return false
                }
            } else {
                switch offsetValue {
                case 1:
                    actualOffset = rep.0
                case 2:
                    actualOffset = rep.1
                    rep = (actualOffset, rep.0, rep.2)
                case 3:
                    actualOffset = rep.2
                    rep = (actualOffset, rep.0, rep.1)
                default:
                    return false
                }
            }

            guard litIndex + literalLength <= literals.count else { return false }
            if literalLength > 0 {
                let copyCount = min(literalLength, maxFrameOutputBytes - frameOutput.count)
                if copyCount > 0 {
                    frameOutput.append(contentsOf: literals[litIndex..<(litIndex + copyCount)])
                }
                litIndex += literalLength
            }
            if frameOutput.count >= maxFrameOutputBytes {
                context.repeatOffsets = rep
                return true
            }

            guard actualOffset > 0,
                  actualOffset <= frameOutput.count,
                  UInt64(actualOffset) <= maxWindowCheck else {
                return false
            }

            let copyMatchCount = min(matchLength, maxFrameOutputBytes - frameOutput.count)
            if copyMatchCount > 0 {
                // 避免对 frameOutput 自身切片调用 append(contentsOf:) 触发 Array COW 全量拷贝
                var srcIndex = frameOutput.count - actualOffset
                let needed = frameOutput.count + copyMatchCount
                if frameOutput.capacity < needed {
                    frameOutput.reserveCapacity(max(needed, frameOutput.capacity * 2))
                }
                for _ in 0..<copyMatchCount {
                    frameOutput.append(frameOutput[srcIndex])
                    srcIndex += 1
                }
            }
            if frameOutput.count >= maxFrameOutputBytes {
                context.repeatOffsets = rep
                return true
            }
        }

        if litIndex < literals.count && frameOutput.count < maxFrameOutputBytes {
            let remaining = min(literals.count - litIndex, maxFrameOutputBytes - frameOutput.count)
            frameOutput.append(contentsOf: literals[litIndex..<(litIndex + remaining)])
        }

        context.repeatOffsets = rep
        return true
    }

    // MARK: - Literals Section

    private static func decodeLiteralsSection(
        bytes: [UInt8],
        pos: inout Int,
        end: Int,
        context: inout FrameContext
    ) -> [UInt8]? {
        guard pos < end else { return nil }
        let b0 = Int(bytes[pos])
        let litType = b0 & 0x03
        let sizeFormat = (b0 >> 2) & 0x03

        if litType == 0 || litType == 1 {
            let regenSize: Int
            if sizeFormat == 0 || sizeFormat == 2 {
                regenSize = b0 >> 3
                pos += 1
            } else if sizeFormat == 1 {
                guard pos + 2 <= end else { return nil }
                regenSize = (b0 >> 4) | (Int(bytes[pos + 1]) << 4)
                pos += 2
            } else {
                guard pos + 3 <= end else { return nil }
                regenSize = (b0 >> 4) | (Int(bytes[pos + 1]) << 4) | (Int(bytes[pos + 2]) << 12)
                pos += 3
            }

            guard regenSize <= maxBlockSize else { return nil }
            if litType == 0 {
                guard pos + regenSize <= end else { return nil }
                let result = Array(bytes[pos..<(pos + regenSize)])
                pos += regenSize
                return result
            } else {
                guard pos + 1 <= end else { return nil }
                let value = bytes[pos]
                pos += 1
                return [UInt8](repeating: value, count: regenSize)
            }
        }

        let regenSize: Int
        let compSize: Int
        let streamCount: Int

        switch sizeFormat {
        case 0, 1:
            guard pos + 3 <= end else { return nil }
            let val24 = b0 | (Int(bytes[pos + 1]) << 8) | (Int(bytes[pos + 2]) << 16)
            regenSize = (val24 >> 4) & 0x3FF
            compSize = (val24 >> 14) & 0x3FF
            streamCount = (sizeFormat == 0) ? 1 : 4
            pos += 3
        case 2:
            guard pos + 4 <= end else { return nil }
            let val32 = UInt32(b0)
                | (UInt32(bytes[pos + 1]) << 8)
                | (UInt32(bytes[pos + 2]) << 16)
                | (UInt32(bytes[pos + 3]) << 24)
            regenSize = Int((val32 >> 4) & 0x3FFF)
            compSize = Int((val32 >> 18) & 0x3FFF)
            streamCount = 4
            pos += 4
        case 3:
            guard pos + 5 <= end else { return nil }
            let val40 = UInt64(b0)
                | (UInt64(bytes[pos + 1]) << 8)
                | (UInt64(bytes[pos + 2]) << 16)
                | (UInt64(bytes[pos + 3]) << 24)
                | (UInt64(bytes[pos + 4]) << 32)
            regenSize = Int((val40 >> 4) & 0x3FFFF)
            compSize = Int((val40 >> 22) & 0x3FFFF)
            streamCount = 4
            pos += 5
        default:
            return nil
        }

        guard regenSize <= maxBlockSize, pos + compSize <= end else { return nil }
        let litSectionEnd = pos + compSize
        var litCursor = pos
        pos = litSectionEnd

        let huffmanTable: HuffmanTable
        if litType == 2 {
            guard let parsed = readHuffmanTable(bytes: bytes, pos: &litCursor, end: litSectionEnd) else {
                return nil
            }
            context.huffmanTable = parsed
            huffmanTable = parsed
        } else {
            guard let existing = context.huffmanTable else { return nil }
            huffmanTable = existing
        }

        var output: [UInt8] = []
        output.reserveCapacity(regenSize)

        if streamCount == 1 {
            guard decodeHuffmanStream(
                bytes: bytes,
                start: litCursor,
                end: litSectionEnd,
                table: huffmanTable,
                expectedCount: regenSize,
                into: &output
            ) else {
                return nil
            }
            return output
        }

        guard litCursor + 6 <= litSectionEnd else { return nil }
        let s1 = Int(readUInt16LE(bytes, at: litCursor))
        let s2 = Int(readUInt16LE(bytes, at: litCursor + 2))
        let s3 = Int(readUInt16LE(bytes, at: litCursor + 4))
        litCursor += 6

        let stream1End = litCursor + s1
        let stream2End = stream1End + s2
        let stream3End = stream2End + s3
        guard stream3End <= litSectionEnd else { return nil }

        let chunkRegenSize = (regenSize + 3) / 4
        guard chunkRegenSize * 3 <= regenSize else { return nil }
        let lastChunkRegenSize = regenSize - chunkRegenSize * 3

        let slices: [(Int, Int, Int)] = [
            (litCursor, stream1End, chunkRegenSize),
            (stream1End, stream2End, chunkRegenSize),
            (stream2End, stream3End, chunkRegenSize),
            (stream3End, litSectionEnd, lastChunkRegenSize)
        ]

        for (sStart, sEnd, expected) in slices {
            guard decodeHuffmanStream(
                bytes: bytes,
                start: sStart,
                end: sEnd,
                table: huffmanTable,
                expectedCount: expected,
                into: &output
            ) else {
                return nil
            }
        }

        return output
    }

    // MARK: - Huffman Table & Decoding

    private struct HuffmanEntry {
        let symbol: UInt8
        let numBits: UInt8
    }

    private struct HuffmanTable {
        let maxBits: Int
        let entries: [HuffmanEntry]
    }

    private static func readHuffmanTable(
        bytes: [UInt8],
        pos: inout Int,
        end: Int
    ) -> HuffmanTable? {
        guard pos < end else { return nil }
        let headerByte = Int(bytes[pos])
        pos += 1

        var weights: [Int] = []
        if headerByte >= 128 {
            let numWeights = headerByte - 127
            let byteCount = (numWeights + 1) / 2
            guard pos + byteCount <= end else { return nil }
            weights.reserveCapacity(numWeights + 1)
            for i in 0..<numWeights {
                let byte = bytes[pos + (i / 2)]
                let weight = (i % 2 == 0) ? Int(byte >> 4) : Int(byte & 0x0F)
                weights.append(weight)
            }
            pos += byteCount
        } else {
            let compressedSize = headerByte
            guard compressedSize > 0, pos + compressedSize <= end else { return nil }
            let compEnd = pos + compressedSize
            var fsePos = pos
            pos = compEnd

            guard let fseTable = readFSETable(
                bytes: bytes,
                pos: &fsePos,
                end: compEnd,
                maxAccuracyLog: 6,
                maxSymbol: 12
            ) else {
                return nil
            }

            guard var reader = BackwardBitReader(bytes: bytes, start: fsePos, end: compEnd) else {
                return nil
            }
            guard var state1 = reader.readBits(fseTable.accuracyLog),
                  var state2 = reader.readBits(fseTable.accuracyLog) else {
                return nil
            }

            weights.reserveCapacity(64)
            while weights.count < maxHuffmanWeights {
                guard state1 < fseTable.entries.count else { return nil }
                let e1 = fseTable.entries[state1]
                weights.append(Int(e1.symbol))
                let nb1 = Int(e1.nbBits)
                if reader.bitsRemaining < nb1 {
                    guard state2 < fseTable.entries.count else { return nil }
                    weights.append(Int(fseTable.entries[state2].symbol))
                    break
                }
                guard let bits1 = reader.readBits(nb1) else { return nil }
                state1 = Int(e1.newStateBase) + bits1

                if weights.count >= maxHuffmanWeights { break }

                guard state2 < fseTable.entries.count else { return nil }
                let e2 = fseTable.entries[state2]
                weights.append(Int(e2.symbol))
                let nb2 = Int(e2.nbBits)
                if reader.bitsRemaining < nb2 {
                    guard state1 < fseTable.entries.count else { return nil }
                    weights.append(Int(fseTable.entries[state1].symbol))
                    break
                }
                guard let bits2 = reader.readBits(nb2) else { return nil }
                state2 = Int(e2.newStateBase) + bits2
            }
        }

        guard !weights.isEmpty, weights.count <= maxHuffmanWeights else { return nil }

        var weightSum = 0
        for w in weights {
            guard w >= 0 && w <= maxHuffmanTableLog else { return nil }
            if w > 0 {
                weightSum += 1 << (w - 1)
            }
        }
        guard weightSum > 0 else { return nil }

        let maxBits = (Int.bitWidth - weightSum.leadingZeroBitCount)
        guard maxBits >= 1 && maxBits <= maxHuffmanTableLog else { return nil }
        let total = 1 << maxBits
        let leftOver = total - weightSum
        guard leftOver > 0 && (leftOver & (leftOver - 1)) == 0 else { return nil }
        let lastWeight = leftOver.trailingZeroBitCount + 1
        guard lastWeight <= maxBits else { return nil }
        weights.append(lastWeight)

        var rankCount = [Int](repeating: 0, count: maxBits + 2)
        for w in weights where w > 0 {
            rankCount[w] += 1
        }

        var rankStart = [Int](repeating: 0, count: maxBits + 2)
        var nextIndex = 0
        for w in 1...maxBits {
            rankStart[w] = nextIndex
            nextIndex += rankCount[w] * (1 << (w - 1))
        }
        guard nextIndex == total else { return nil }

        var entries = [HuffmanEntry](repeating: HuffmanEntry(symbol: 0, numBits: 0), count: total)
        for (sym, w) in weights.enumerated() where w > 0 {
            let numBits = UInt8(maxBits + 1 - w)
            let span = 1 << (w - 1)
            let startIdx = rankStart[w]
            rankStart[w] = startIdx + span
            let entry = HuffmanEntry(symbol: UInt8(sym), numBits: numBits)
            for idx in startIdx..<(startIdx + span) {
                entries[idx] = entry
            }
        }

        return HuffmanTable(maxBits: maxBits, entries: entries)
    }

    private static func decodeHuffmanStream(
        bytes: [UInt8],
        start: Int,
        end: Int,
        table: HuffmanTable,
        expectedCount: Int,
        into output: inout [UInt8]
    ) -> Bool {
        guard var reader = BackwardBitReader(bytes: bytes, start: start, end: end) else {
            return expectedCount == 0
        }
        let maxBits = table.maxBits
        let entries = table.entries
        var decoded = 0

        while reader.bitsRemaining > 0 && decoded < expectedCount {
            let peeked = reader.peekBitsPadded(maxBits)
            let entry = entries[peeked]
            let nb = Int(entry.numBits)
            guard nb > 0, nb <= reader.bitsRemaining else { return false }
            reader.skipBits(nb)
            output.append(entry.symbol)
            decoded += 1
        }

        return decoded == expectedCount && reader.bitsRemaining == 0
    }

    // MARK: - FSE Table Construction & Decoding

    private struct FSEEntry {
        let symbol: UInt8
        let nbBits: UInt8
        let newStateBase: UInt16
    }

    private struct FSETable {
        let accuracyLog: Int
        let entries: [FSEEntry]
    }

    private static func resolveSequenceTable(
        mode: Int,
        predefined: FSETable,
        previous: FSETable?,
        maxAccuracyLog: Int,
        maxSymbol: Int,
        bytes: [UInt8],
        pos: inout Int,
        end: Int
    ) -> FSETable? {
        switch mode {
        case 0:
            return predefined
        case 1:
            guard pos < end else { return nil }
            let symbol = bytes[pos]
            pos += 1
            guard Int(symbol) <= maxSymbol else { return nil }
            return FSETable(
                accuracyLog: 0,
                entries: [FSEEntry(symbol: symbol, nbBits: 0, newStateBase: 0)]
            )
        case 2:
            return readFSETable(
                bytes: bytes,
                pos: &pos,
                end: end,
                maxAccuracyLog: maxAccuracyLog,
                maxSymbol: maxSymbol
            )
        case 3:
            return previous
        default:
            return nil
        }
    }

    private static func readFSETable(
        bytes: [UInt8],
        pos: inout Int,
        end: Int,
        maxAccuracyLog: Int,
        maxSymbol: Int
    ) -> FSETable? {
        guard pos < end else { return nil }
        var reader = ForwardBitReader(bytes: bytes, start: pos, end: end)
        guard let accBits = reader.readBits(4) else { return nil }
        let accuracyLog = accBits + 5
        guard accuracyLog <= maxAccuracyLog else { return nil }

        let tableSize = 1 << accuracyLog
        var remaining = tableSize + 1
        var threshold = tableSize
        var bitCount = accuracyLog + 1
        var symbol = 0
        var previousZero = false
        var normalized = [Int](repeating: 0, count: maxSymbol + 1)

        while remaining > 1 && symbol <= maxSymbol {
            if previousZero {
                var repeatCount = 0
                while true {
                    guard let twoBits = reader.readBits(2) else { return nil }
                    repeatCount += twoBits
                    if twoBits < 3 { break }
                }
                symbol += repeatCount
                if symbol > maxSymbol {
                    return nil
                }
            }

            let maxVal = 2 * threshold - 1 - remaining
            guard let lowBits = reader.peekBits(bitCount - 1) else { return nil }
            let rawValue: Int
            if lowBits < maxVal {
                rawValue = lowBits
                reader.consumeBits(bitCount - 1)
            } else {
                guard let fullBits = reader.peekBits(bitCount) else { return nil }
                var val = fullBits
                if val >= threshold {
                    val -= maxVal
                }
                rawValue = val
                reader.consumeBits(bitCount)
            }

            let count = rawValue - 1
            if count == -1 {
                remaining -= 1
            } else if count >= 0 {
                remaining -= count
            } else {
                return nil
            }
            guard remaining >= 1 else { return nil }

            normalized[symbol] = count
            symbol += 1
            previousZero = (count == 0)

            while remaining < threshold && bitCount > 1 {
                bitCount -= 1
                threshold >>= 1
            }
        }

        guard remaining == 1 else { return nil }
        let bytesConsumed = reader.bytesConsumed
        guard pos + bytesConsumed <= end else { return nil }
        pos += bytesConsumed

        return buildFSETable(normalized: Array(normalized.prefix(symbol)), accuracyLog: accuracyLog)
    }

    private static func buildFSETable(normalized: [Int], accuracyLog: Int) -> FSETable? {
        let tableSize = 1 << accuracyLog
        let tableMask = tableSize - 1
        let step = (tableSize >> 1) + (tableSize >> 3) + 3

        var tableSymbols = [UInt8](repeating: 0, count: tableSize)
        var symbolNext = [Int](repeating: 0, count: normalized.count)
        var highThreshold = tableSize - 1

        for (sym, count) in normalized.enumerated() {
            if count == -1 {
                guard highThreshold >= 0 else { return nil }
                tableSymbols[highThreshold] = UInt8(sym)
                highThreshold -= 1
                symbolNext[sym] = 1
            } else if count > 0 {
                symbolNext[sym] = count
            }
        }

        var position = 0
        for (sym, count) in normalized.enumerated() where count > 0 {
            for _ in 0..<count {
                tableSymbols[position] = UInt8(sym)
                repeat {
                    position = (position + step) & tableMask
                } while position > highThreshold
            }
        }
        guard position == 0 else { return nil }

        var entries: [FSEEntry] = []
        entries.reserveCapacity(tableSize)
        for u in 0..<tableSize {
            let sym = tableSymbols[u]
            let nextState = symbolNext[Int(sym)]
            symbolNext[Int(sym)] = nextState + 1
            guard nextState > 0 else { return nil }
            let highBit = Int.bitWidth - 1 - nextState.leadingZeroBitCount
            let nbBits = accuracyLog - highBit
            guard nbBits >= 0 else { return nil }
            let baseline = (nextState << nbBits) - tableSize
            guard baseline >= 0 && baseline < tableSize else { return nil }
            entries.append(
                FSEEntry(
                    symbol: sym,
                    nbBits: UInt8(nbBits),
                    newStateBase: UInt16(baseline)
                )
            )
        }

        return FSETable(accuracyLog: accuracyLog, entries: entries)
    }

    // MARK: - Bit Readers

    private struct ForwardBitReader {
        let bytes: [UInt8]
        let start: Int
        let end: Int
        var bitOffset: Int = 0

        var totalBits: Int { (end - start) * 8 }
        var bytesConsumed: Int { (bitOffset + 7) / 8 }

        func peekBits(_ count: Int) -> Int? {
            guard count >= 0, count <= 31 else { return nil }
            if count == 0 { return 0 }
            let available = totalBits - bitOffset
            guard available > 0 else { return nil }
            let actualCount = min(count, available)
            var result = 0
            for i in 0..<actualCount {
                let absBit = bitOffset + i
                let byteIdx = start + (absBit >> 3)
                let bit = Int((bytes[byteIdx] >> (absBit & 7)) & 1)
                result |= bit << i
            }
            return result
        }

        mutating func consumeBits(_ count: Int) {
            bitOffset = min(totalBits, bitOffset + count)
        }

        mutating func readBits(_ count: Int) -> Int? {
            guard count >= 0, bitOffset + count <= totalBits else { return nil }
            let val = peekBits(count)
            bitOffset += count
            return val
        }
    }

    /// 带 64 位位缓冲池的高速反向 MSB 优先位读取器（减少逐字节循环，安全无越界）
    private struct BackwardBitReader {
        let bytes: [UInt8]
        let start: Int
        /// 尚未装入缓存池的字节上界（排他）
        var nextByteEnd: Int
        /// 当前缓冲池中的位（高位对齐在 bit 63 侧）
        var bitBuffer: UInt64 = 0
        /// `bitBuffer` 中当前有效位数（0...64）
        var bufferedBits: Int = 0
        /// 整个流剩余未消费总位数
        var bitsRemaining: Int

        init?(bytes: [UInt8], start: Int, end: Int) {
            guard start < end, end <= bytes.count else { return nil }
            let lastByte = bytes[end - 1]
            guard lastByte != 0 else { return nil }
            let leadingZeros = lastByte.leadingZeroBitCount
            let sentinelOffsetFromMSB = leadingZeros + 1
            let totalPayloadBits = (end - start) * 8 - sentinelOffsetFromMSB
            guard totalPayloadBits >= 0 else { return nil }

            self.bytes = bytes
            self.start = start
            self.nextByteEnd = end - 1
            self.bitsRemaining = totalPayloadBits

            // 将末字节中哨兵位之下的低位左对齐装入 bitBuffer 顶部
            let validInLastByte = 8 - sentinelOffsetFromMSB
            if validInLastByte > 0 {
                let mask = UInt8((1 << validInLastByte) - 1)
                let payload = UInt64(lastByte & mask)
                self.bitBuffer = payload << (64 - validInLastByte)
                self.bufferedBits = validInLastByte
            }
            refill()
        }

        @inline(__always)
        private mutating func refill() {
            while bufferedBits <= 56 && nextByteEnd > start {
                nextByteEnd -= 1
                let b = UInt64(bytes[nextByteEnd])
                bitBuffer |= b << (56 - bufferedBits)
                bufferedBits += 8
            }
        }

        @inline(__always)
        mutating func readBits(_ count: Int) -> Int? {
            guard count >= 0, count <= 31 else { return nil }
            if count == 0 { return 0 }
            guard count <= bitsRemaining else { return nil }
            if bufferedBits < count {
                refill()
            }
            let value = Int(bitBuffer >> (64 - count))
            bitBuffer <<= count
            bufferedBits -= count
            bitsRemaining -= count
            return value
        }

        @inline(__always)
        mutating func peekBitsPadded(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            if bufferedBits < count && nextByteEnd > start {
                refill()
            }
            // bitBuffer 本身高位对齐且低位已补零，直接右移即可得到零填充前缀！
            return Int(bitBuffer >> (64 - count))
        }

        @inline(__always)
        mutating func skipBits(_ count: Int) {
            bitBuffer <<= count
            bufferedBits -= count
            bitsRemaining -= count
        }
    }

    // MARK: - Little-Endian Readers

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - RFC 8878 Predefined Tables

    private struct LengthSpec {
        let baseline: Int
        let bits: Int
    }

    private static let literalLengthTable: [LengthSpec] = [
        LengthSpec(baseline: 0, bits: 0), LengthSpec(baseline: 1, bits: 0),
        LengthSpec(baseline: 2, bits: 0), LengthSpec(baseline: 3, bits: 0),
        LengthSpec(baseline: 4, bits: 0), LengthSpec(baseline: 5, bits: 0),
        LengthSpec(baseline: 6, bits: 0), LengthSpec(baseline: 7, bits: 0),
        LengthSpec(baseline: 8, bits: 0), LengthSpec(baseline: 9, bits: 0),
        LengthSpec(baseline: 10, bits: 0), LengthSpec(baseline: 11, bits: 0),
        LengthSpec(baseline: 12, bits: 0), LengthSpec(baseline: 13, bits: 0),
        LengthSpec(baseline: 14, bits: 0), LengthSpec(baseline: 15, bits: 0),
        LengthSpec(baseline: 16, bits: 1), LengthSpec(baseline: 18, bits: 1),
        LengthSpec(baseline: 20, bits: 1), LengthSpec(baseline: 22, bits: 1),
        LengthSpec(baseline: 24, bits: 2), LengthSpec(baseline: 28, bits: 2),
        LengthSpec(baseline: 32, bits: 3), LengthSpec(baseline: 40, bits: 3),
        LengthSpec(baseline: 48, bits: 4), LengthSpec(baseline: 64, bits: 6),
        LengthSpec(baseline: 128, bits: 7), LengthSpec(baseline: 256, bits: 8),
        LengthSpec(baseline: 512, bits: 9), LengthSpec(baseline: 1024, bits: 10),
        LengthSpec(baseline: 2048, bits: 11), LengthSpec(baseline: 4096, bits: 12),
        LengthSpec(baseline: 8192, bits: 13), LengthSpec(baseline: 16384, bits: 14),
        LengthSpec(baseline: 32768, bits: 15), LengthSpec(baseline: 65536, bits: 16)
    ]

    private static let matchLengthTable: [LengthSpec] = [
        LengthSpec(baseline: 3, bits: 0), LengthSpec(baseline: 4, bits: 0),
        LengthSpec(baseline: 5, bits: 0), LengthSpec(baseline: 6, bits: 0),
        LengthSpec(baseline: 7, bits: 0), LengthSpec(baseline: 8, bits: 0),
        LengthSpec(baseline: 9, bits: 0), LengthSpec(baseline: 10, bits: 0),
        LengthSpec(baseline: 11, bits: 0), LengthSpec(baseline: 12, bits: 0),
        LengthSpec(baseline: 13, bits: 0), LengthSpec(baseline: 14, bits: 0),
        LengthSpec(baseline: 15, bits: 0), LengthSpec(baseline: 16, bits: 0),
        LengthSpec(baseline: 17, bits: 0), LengthSpec(baseline: 18, bits: 0),
        LengthSpec(baseline: 19, bits: 0), LengthSpec(baseline: 20, bits: 0),
        LengthSpec(baseline: 21, bits: 0), LengthSpec(baseline: 22, bits: 0),
        LengthSpec(baseline: 23, bits: 0), LengthSpec(baseline: 24, bits: 0),
        LengthSpec(baseline: 25, bits: 0), LengthSpec(baseline: 26, bits: 0),
        LengthSpec(baseline: 27, bits: 0), LengthSpec(baseline: 28, bits: 0),
        LengthSpec(baseline: 29, bits: 0), LengthSpec(baseline: 30, bits: 0),
        LengthSpec(baseline: 31, bits: 0), LengthSpec(baseline: 32, bits: 0),
        LengthSpec(baseline: 33, bits: 0), LengthSpec(baseline: 34, bits: 0),
        LengthSpec(baseline: 35, bits: 1), LengthSpec(baseline: 37, bits: 1),
        LengthSpec(baseline: 39, bits: 1), LengthSpec(baseline: 41, bits: 1),
        LengthSpec(baseline: 43, bits: 2), LengthSpec(baseline: 47, bits: 2),
        LengthSpec(baseline: 51, bits: 3), LengthSpec(baseline: 59, bits: 3),
        LengthSpec(baseline: 67, bits: 4), LengthSpec(baseline: 83, bits: 4),
        LengthSpec(baseline: 99, bits: 5), LengthSpec(baseline: 131, bits: 7),
        LengthSpec(baseline: 259, bits: 8), LengthSpec(baseline: 515, bits: 9),
        LengthSpec(baseline: 1027, bits: 10), LengthSpec(baseline: 2051, bits: 11),
        LengthSpec(baseline: 4099, bits: 12), LengthSpec(baseline: 8195, bits: 13),
        LengthSpec(baseline: 16387, bits: 14), LengthSpec(baseline: 32771, bits: 15),
        LengthSpec(baseline: 65539, bits: 16)
    ]

    private static let predefinedLLTable: FSETable = buildFSETable(
        normalized: [
            4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
            2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
            -1, -1, -1, -1
        ],
        accuracyLog: 6
    )!

    private static let predefinedMLTable: FSETable = buildFSETable(
        normalized: [
            1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
            -1, -1, -1, -1, -1
        ],
        accuracyLog: 6
    )!

    private static let predefinedOFTable: FSETable = buildFSETable(
        normalized: [
            1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
        ],
        accuracyLog: 5
    )!
}

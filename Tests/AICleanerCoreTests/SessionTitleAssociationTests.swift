import AICleanerCore
import Foundation
import SQLite3
import XCTest

final class SessionTitleAssociationTests: XCTestCase {
    private var sandbox: TestSandbox!

    // 真实 zstd 压缩的 Codex rollout JSONL（含需跳过的 <environment_context>、项目 cwd 与真实中文提问）
    private static let codexZstBytes: [UInt8] = [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x7D, 0x0C, 0x00, 0x66, 0x96, 0x55, 0x3E, 0x40, 0x89, 0xB6,
        0x0D, 0xCF, 0xDF, 0x76, 0x37, 0xBB, 0x8A, 0xA2, 0x76, 0xD4, 0x23, 0xAF, 0x29, 0x14, 0xFC, 0xD8,
        0x44, 0x70, 0x58, 0xD8, 0x39, 0xEE, 0x8D, 0x30, 0x89, 0xCB, 0xE2, 0x46, 0x9F, 0x4B, 0x09, 0xD0,
        0xEA, 0xB5, 0xDA, 0x22, 0x5D, 0x76, 0x91, 0x65, 0x89, 0x68, 0xCD, 0x30, 0x8E, 0x59, 0xE1, 0x61,
        0xCE, 0x3D, 0x62, 0xD7, 0x23, 0x66, 0x2C, 0x03, 0x04, 0x3B, 0x17, 0x42, 0x00, 0x3D, 0x00, 0x47,
        0x00, 0x7F, 0x05, 0x48, 0x14, 0x97, 0x47, 0xC8, 0x1B, 0x2E, 0xAA, 0x61, 0x42, 0x51, 0x13, 0x35,
        0x91, 0x53, 0xE4, 0x70, 0x61, 0x12, 0x11, 0x03, 0x00, 0x49, 0x45, 0x93, 0xE9, 0x1D, 0xA2, 0x7F,
        0x90, 0xD7, 0x3F, 0x30, 0x4C, 0x1E, 0x2B, 0xC7, 0xA6, 0x5F, 0xC4, 0xCA, 0x31, 0x59, 0x29, 0x16,
        0x52, 0xF3, 0x08, 0xB9, 0xC4, 0x9F, 0x59, 0xB4, 0xCE, 0x7B, 0xFF, 0x7A, 0xAC, 0xFC, 0x35, 0x0B,
        0xEC, 0x17, 0x01, 0x1E, 0x21, 0xC7, 0x15, 0x8F, 0x2D, 0xBC, 0x69, 0x74, 0x0E, 0x88, 0x95, 0x63,
        0xFA, 0x98, 0x56, 0xFB, 0x77, 0xA3, 0x54, 0xEB, 0x11, 0xF2, 0x9F, 0x90, 0xF7, 0x7E, 0x96, 0x3D,
        0x9E, 0xD6, 0x5F, 0x5A, 0xB5, 0xFB, 0x56, 0xC2, 0x71, 0x5E, 0x27, 0xB6, 0xE1, 0x1B, 0x61, 0x54,
        0x5A, 0x09, 0xE9, 0x2F, 0xA9, 0x5D, 0x02, 0xB6, 0x52, 0x48, 0x7F, 0x4D, 0x8A, 0x94, 0xAE, 0x0D,
        0x54, 0xE2, 0x3B, 0xEF, 0x95, 0x22, 0x1A, 0xF9, 0xC3, 0x78, 0x10, 0x70, 0x68, 0x11, 0x8D, 0xEC,
        0xB1, 0xD9, 0x9B, 0x90, 0xBC, 0x61, 0xD1, 0x5D, 0x02, 0xAD, 0x71, 0xB0, 0xBB, 0x8F, 0x6D, 0x80,
        0x81, 0xB6, 0x54, 0xD8, 0x5D, 0xD8, 0xC9, 0x78, 0x7A, 0x63, 0xB3, 0x35, 0x9E, 0xFE, 0x08, 0x73,
        0x04, 0xE7, 0x12, 0x04, 0xF6, 0xB6, 0xD2, 0x89, 0x19, 0x00, 0x57, 0x58, 0x98, 0x7E, 0x46, 0xAB,
        0x9D, 0x05, 0xE8, 0x43, 0x78, 0xAC, 0x02, 0x12, 0x8E, 0x8B, 0xE0, 0xBC, 0xD2, 0x5D, 0x80, 0xB0,
        0x40, 0x7B, 0xDF, 0xC6, 0x5C, 0x3E, 0x95, 0xEE, 0x03, 0xF2, 0x79, 0x2E, 0x13, 0x34, 0x46, 0xD8,
        0x01, 0xF9, 0x3C, 0x12, 0x28, 0xE8, 0x07, 0x99, 0x7C, 0x01, 0x33, 0xC8, 0x19, 0xC9, 0xD8, 0x1C,
        0x0E, 0x8D, 0xD1, 0xE0, 0x03, 0x66, 0x32, 0x26, 0xEC, 0x28, 0xE8, 0xC8, 0x9F, 0x47, 0x45, 0x87,
        0x84, 0x9D, 0x03, 0x11, 0xB2, 0xC6, 0xD3, 0x20, 0x67, 0xC4, 0x92, 0xB1, 0x2D, 0x74, 0x64, 0xBC,
        0x55, 0x1C, 0x12, 0x00, 0xCF, 0xB1, 0x8E, 0xFF, 0x4F, 0x8B, 0x81, 0xAA, 0xCD, 0xD0, 0x68, 0xEF,
        0x25, 0x5B, 0xDA, 0x8D, 0xED, 0x22, 0xA7, 0x62, 0x86, 0xEE, 0x0A, 0x33, 0xA9, 0x03, 0x8A, 0x52,
        0x5B, 0x09, 0xB8, 0x72, 0xD5, 0xD4, 0x45, 0x7B, 0x34, 0xA2, 0x67, 0x84, 0x22, 0x25, 0x00, 0x83,
        0xA1, 0xFF, 0x82, 0xD9, 0xB7, 0x64, 0xAB, 0xCC, 0x40, 0x04, 0x62, 0xCC
    ]

    // 真实 zstd 压缩的 DeepSeek Harness session.v4.jsonl.zstd（含 session/title 与 user/message）
    private static let dshZstdBytes: [UInt8] = [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0xAD, 0x0A, 0x00, 0x56, 0xD2, 0x46, 0x39, 0x40, 0xA5, 0x3A,
        0x07, 0x88, 0x48, 0xBE, 0xAB, 0x28, 0x8A, 0x8B, 0x42, 0xE5, 0xD7, 0x29, 0x8C, 0x92, 0x44, 0x60,
        0x64, 0xC3, 0x34, 0x4C, 0xDD, 0xF5, 0x82, 0xD8, 0x03, 0xCF, 0x69, 0x67, 0x5F, 0x46, 0x6C, 0x5C,
        0x64, 0x3C, 0xC2, 0x24, 0x41, 0x77, 0xC6, 0x51, 0xCC, 0x69, 0x3D, 0xD3, 0xED, 0x6F, 0x61, 0x7E,
        0x25, 0x54, 0x45, 0xC0, 0x18, 0x10, 0x36, 0x00, 0x32, 0x00, 0x3A, 0x00, 0x57, 0x73, 0xDA, 0xA6,
        0x45, 0x26, 0x1D, 0x45, 0x1B, 0xE8, 0x38, 0x0C, 0xD2, 0x15, 0x4C, 0x30, 0x89, 0xB7, 0x6D, 0x98,
        0x84, 0x32, 0xF9, 0xB0, 0x2D, 0xC2, 0x09, 0x74, 0x9C, 0xE6, 0x35, 0xAD, 0xFD, 0x81, 0x4D, 0xAF,
        0x8D, 0xD6, 0xEB, 0x08, 0x4D, 0xAF, 0x16, 0x47, 0xF0, 0xDF, 0xBF, 0x69, 0x6D, 0xBF, 0x24, 0xE0,
        0xD6, 0x04, 0xB5, 0x2D, 0xB6, 0x5F, 0xD3, 0x0B, 0x42, 0x6B, 0x1F, 0xF8, 0x37, 0xBD, 0xDA, 0x2B,
        0xF6, 0xDF, 0x2D, 0xD9, 0xF5, 0xC7, 0x3C, 0xC8, 0x76, 0x11, 0xAC, 0x88, 0x8E, 0x5D, 0xFF, 0xEE,
        0x98, 0xB9, 0x67, 0x2F, 0x6F, 0x70, 0xC7, 0x4C, 0xE6, 0x1E, 0x18, 0xDA, 0xEC, 0xAF, 0x3F, 0x41,
        0x96, 0xF1, 0x9A, 0x06, 0x35, 0x12, 0x62, 0x10, 0x67, 0x64, 0x8F, 0x34, 0xCE, 0x93, 0xC5, 0x59,
        0xE1, 0xC9, 0x0C, 0xA8, 0x16, 0xC8, 0x21, 0x6F, 0x3C, 0x98, 0x23, 0x00, 0x79, 0x62, 0x95, 0x29,
        0x3C, 0xB9, 0x93, 0x2A, 0x23, 0x40, 0x19, 0xA5, 0xCA, 0x23, 0xD3, 0xC9, 0x81, 0x61, 0x4A, 0x7C,
        0xCC, 0xA6, 0xB5, 0xB1, 0xE8, 0x58, 0x1C, 0xAF, 0x3F, 0x26, 0x1C, 0x6F, 0x6B, 0x68, 0x0F, 0x92,
        0xEC, 0x8D, 0xC2, 0x80, 0x00, 0x1F, 0x16, 0xE9, 0x94, 0x17, 0x44, 0xE7, 0xA6, 0xD4, 0x0A, 0xA9,
        0xCA, 0x4F, 0xAA, 0x34, 0x71, 0x72, 0x69, 0xC5, 0x12, 0xD0, 0xC1, 0x12, 0x5D, 0x9C, 0x19, 0x10,
        0xB9, 0xB3, 0x2A, 0x43, 0x24, 0xB3, 0x81, 0x93, 0x9B, 0x56, 0x0D, 0x8B, 0x16, 0x3F, 0xF8, 0x6F,
        0x2D, 0x61, 0xE8, 0x5D, 0xCC, 0xD8, 0x34, 0x14, 0x00, 0xDF, 0xC8, 0xB5, 0x7A, 0x79, 0xE0, 0x17,
        0x14, 0x01, 0xC0, 0xDD, 0xB5, 0x79, 0xA7, 0x0D, 0x39, 0x54, 0x26, 0xB4, 0xB3, 0x0B, 0x03, 0x1B,
        0x80, 0x15, 0xC0, 0xFC, 0xC4, 0x00, 0xF8, 0xED, 0xC3, 0xA8, 0xDE, 0xB2, 0x90, 0x7C, 0x30, 0x6C,
        0xA3, 0x11, 0xB3, 0x4C, 0x3C, 0x07, 0xCC, 0x3E, 0x93, 0xAA, 0x41, 0x2C, 0x94, 0x31, 0xDE, 0xF9,
        0x08, 0x05
    ]

    // 多帧 + Skippable Frame + level-19 压缩夹具
    private static let multiFrameZstBytes: [UInt8] = [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x4D, 0x02, 0x00, 0xF2, 0x44, 0x11, 0x17, 0x90, 0xB5, 0x3A,
        0xEC, 0x5D, 0x54, 0x1B, 0x52, 0xEC, 0x1F, 0xF8, 0xD9, 0x64, 0x63, 0xFF, 0xCD, 0x22, 0x3D, 0xE3,
        0x79, 0xDE, 0x0C, 0x02, 0x41, 0x8C, 0x7E, 0x52, 0x66, 0x0C, 0xA7, 0xA1, 0x40, 0xCA, 0x17, 0x5D,
        0x7B, 0x30, 0xE5, 0xF2, 0xE5, 0x20, 0xCD, 0x65, 0x5F, 0x22, 0x4D, 0x6C, 0x5C, 0x31, 0x24, 0x36,
        0xAA, 0xD0, 0xD3, 0x65, 0xC1, 0xDA, 0x9E, 0x0A, 0x80, 0x3A, 0xBB, 0x5F, 0x13, 0x7F, 0xBD, 0x66,
        0x18, 0x00, 0xC6, 0xE9, 0x1A, 0x43, 0x50, 0x2A, 0x4D, 0x18, 0x04, 0x00, 0x00, 0x00, 0x53, 0x4B,
        0x49, 0x50, 0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x68, 0xB5, 0x02, 0x00, 0x94, 0x04, 0x7B, 0x22, 0x74,
        0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x6D, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x22, 0x2C, 0x22,
        0x72, 0x6F, 0x6C, 0x75, 0x73, 0x65, 0x72, 0x22, 0x2C, 0x22, 0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E,
        0x74, 0xE5, 0xA4, 0x9A, 0xE5, 0xB8, 0xA7, 0xE4, 0xB8, 0x8E, 0xE9, 0xAB, 0x98, 0xE5, 0x8E, 0x8B,
        0xE7, 0xBC, 0xA9, 0xE6, 0xAF, 0x94, 0xE5, 0x9B, 0x9E, 0xE5, 0xBD, 0x92, 0xE9, 0xAA, 0x8C, 0xE8,
        0xAF, 0x81, 0x22, 0x7D, 0x0A, 0x7B, 0x03, 0x00, 0xD5, 0x48, 0x81, 0x7A, 0x00, 0x28, 0x14, 0xCC,
        0x26, 0xD7, 0x01, 0x1E, 0xBF
    ]

    // 触发 RLE 块/重复字面量路径的 zstd 夹具（4096 * "A" + "\n" + 2048 * "B"）
    private static let rleZstBytes: [UInt8] = [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x75, 0x00, 0x00, 0x20, 0x41, 0x41, 0x0A, 0x42, 0x02, 0x00,
        0xFC, 0x83, 0x1F, 0xEF, 0xDF, 0x07, 0x58, 0x8F, 0x78, 0x67, 0xF6
    ]

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "SessionTitleAssociationTests")
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
    }

    func testZstandardDecoderHandlesRealCompressedFixturesMultiFrameRLEAndCorruptInputs() throws {
        // 1. Codex 压缩夹具完整解压与字节上限裁剪
        let codexFull = try XCTUnwrap(ZstandardDecoder.decompressPrefix(from: Data(Self.codexZstBytes), maxOutputBytes: 65_536))
        let codexText = String(decoding: codexFull, as: UTF8.self)
        XCTAssertTrue(codexText.contains("/Users/alice/workspace/brand-studio"))
        XCTAssertTrue(codexText.contains("帮我生成一组极简科技感应用图标草图"))

        let codexCapped = try XCTUnwrap(ZstandardDecoder.decompressPrefix(from: Data(Self.codexZstBytes), maxOutputBytes: 96))
        XCTAssertEqual(codexCapped.count, 96)

        // 2. DeepSeek Harness 压缩夹具
        let dshFull = try XCTUnwrap(ZstandardDecoder.decompressPrefix(from: Data(Self.dshZstdBytes), maxOutputBytes: 65_536))
        let dshText = String(decoding: dshFull, as: UTF8.self)
        XCTAssertTrue(dshText.contains("库存扣减超卖问题排查"))
        XCTAssertTrue(dshText.contains("排查高并发下单库存扣减超卖问题"))

        // 3. 多帧 + Skippable Frame + level-19 压缩
        let multi = try XCTUnwrap(ZstandardDecoder.decompressPrefix(from: Data(Self.multiFrameZstBytes), maxOutputBytes: 65_536))
        let multiText = String(decoding: multi, as: UTF8.self)
        XCTAssertTrue(multiText.contains("/Users/alice/workspace/multi-frame"))
        XCTAssertTrue(multiText.contains("多帧与高压缩比回归验证"))

        // 4. RLE 压缩夹具
        let rle = try XCTUnwrap(ZstandardDecoder.decompressPrefix(from: Data(Self.rleZstBytes), maxOutputBytes: 16_384))
        XCTAssertEqual(rle.count, 4096 + 1 + 2048)
        XCTAssertEqual(String(decoding: rle.prefix(4), as: UTF8.self), "AAAA")
        XCTAssertEqual(String(decoding: rle.suffix(4), as: UTF8.self), "BBBB")

        // 5. 截断、损坏、空数据均安全降级且不崩溃
        XCTAssertNil(ZstandardDecoder.decompressPrefix(from: Data(), maxOutputBytes: 4096))
        XCTAssertNil(ZstandardDecoder.decompressPrefix(from: Data([0x00, 0x01, 0x02, 0x03, 0x04]), maxOutputBytes: 4096))
        // 合法魔数但帧头不完整或载荷严重损坏
        XCTAssertNil(ZstandardDecoder.decompressPrefix(from: Data([0x28, 0xB5, 0x2F, 0xFD, 0x04]), maxOutputBytes: 4096))
        let corrupted = Data(Self.codexZstBytes.prefix(24) + [0xFF, 0x00, 0xAA, 0x55])
        _ = ZstandardDecoder.decompressPrefix(from: corrupted, maxOutputBytes: 4096)
    }

    func testCodexCompressedArchiveAndCorruptArchiveExtraction() throws {
        let validUUID = "019eca9e-5e0f-7a41-bdc5-0af7077f27c2"
        let indexedUUID = "019eca9e-5e0f-7a41-bdc5-0af7077f27c3"
        let corruptUUID = "019eca9e-5e0f-7a41-bdc5-0af7077f27c4"

        let validArchive = sandbox.homeURL.appendingPathComponent(
            ".codex/sessions/2026/11/01/rollout-2026-11-01T10-00-00-\(validUUID).jsonl.zst"
        )
        let indexedArchive = sandbox.homeURL.appendingPathComponent(
            ".codex/archived_sessions/rollout-2026-11-01T11-00-00-\(indexedUUID).jsonl.zst"
        )
        let corruptArchive = sandbox.homeURL.appendingPathComponent(
            ".codex/sessions/2026/11/01/rollout-2026-11-01T12-00-00-\(corruptUUID).jsonl.zst"
        )

        try writeData(Data(Self.codexZstBytes), to: validArchive)
        try writeData(Data(Self.codexZstBytes), to: indexedArchive)
        try writeData(Data([0x28, 0xB5, 0x2F, 0xFD, 0xFF, 0xFE, 0x00, 0x11]), to: corruptArchive)
        try writeUTF8(
            #"{"id":"\#(indexedUUID)","thread_name":"已重命名的归档会话标题"}"# + "\n",
            to: sandbox.homeURL.appendingPathComponent(".codex/session_index.jsonl")
        )

        let beforeBytes = try Data(contentsOf: validArchive)
        let report = ScanEngine(homeDirectory: sandbox.homeURL).scan()
        let codex = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "codex" }))

        let validItem = try XCTUnwrap(codex.items.first(where: { $0.url.path == validArchive.path }))
        XCTAssertEqual(validItem.sessionProjectName, "brand-studio")
        XCTAssertTrue(validItem.displayName.contains("brand-studio"))
        XCTAssertTrue(validItem.displayName.contains("帮我生成一组极简科技感应用图标草图"))
        XCTAssertFalse(validItem.displayName.contains("<environment_context>"))

        // 优先使用 session_index.jsonl 标题，同时补齐项目名
        let indexedItem = try XCTUnwrap(codex.items.first(where: { $0.url.path == indexedArchive.path }))
        XCTAssertEqual(indexedItem.sessionTitle, "已重命名的归档会话标题")
        XCTAssertEqual(indexedItem.preferredDisplayTitle, "已重命名的归档会话标题")
        XCTAssertEqual(indexedItem.sessionProjectName, "brand-studio")

        // 损坏的 .jsonl.zst 优雅降级为可读时间+短ID，不崩溃
        let corruptItem = try XCTUnwrap(codex.items.first(where: { $0.url.path == corruptArchive.path }))
        XCTAssertEqual(corruptItem.displayName, "2026-11-01 12:00 · 压缩会话归档 (019eca9e)")

        // 严格只读：原压缩文件未被修改，目录下无任何临时解压产物
        XCTAssertEqual(try Data(contentsOf: validArchive), beforeBytes)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: validArchive.deletingLastPathComponent().path)
        XCTAssertEqual(Set(siblingNames), [validArchive.lastPathComponent, corruptArchive.lastPathComponent])
    }

    func testCodexGeneratedImagesResolvesIndexCompressedSessionStateDBSubagentAndOrphanFallback() throws {
        let indexUUID = "11111111-1111-7111-8111-111111111111"
        let zstUUID = "019eca9e-5e0f-7a41-bdc5-0af7077f27c2"
        let parentUUID = "22222222-2222-7222-8222-222222222222"
        let subagentUUID = "33333333-3333-7333-8333-333333333333"
        let orphanUUID = "44444444-4444-7444-8444-444444444444"

        // 1. session_index.jsonl 命中
        try writeUTF8(
            #"{"id":"\#(indexUUID)","thread_name":"设计品牌官网主视觉"}"# + "\n",
            to: sandbox.homeURL.appendingPathComponent(".codex/session_index.jsonl")
        )

        // 2. 压缩归档 .jsonl.zst（未录入 session_index 与 sqlite）反哺给图片缓存
        let zstRollout = sandbox.homeURL.appendingPathComponent(
            ".codex/sessions/2026/11/02/rollout-2026-11-02T09-00-00-\(zstUUID).jsonl.zst"
        )
        try writeData(Data(Self.codexZstBytes), to: zstRollout)

        // 3. state_5.sqlite 只读回退 + 子代理继承父会话标题
        let stateDBURL = sandbox.homeURL.appendingPathComponent(".codex/state_5.sqlite")
        let subagentSource = #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parentUUID)","depth":1,"agent_nickname":"Pascal"}}}"#
        try createSQLiteDatabase(
            at: stateDBURL,
            statements: [
                """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    cwd TEXT,
                    source TEXT,
                    first_user_message TEXT
                );
                """,
                """
                INSERT INTO threads (id, title, cwd, source, first_user_message) VALUES
                ('\(parentUUID)', '开发微信3D弹珠台小游戏', '/Users/alice/workspace/pinball-3d', 'cli', '开发微信3D弹珠台小游戏'),
                ('\(subagentUUID)', '', '/Users/alice/workspace/pinball-3d', '\(subagentSource)', '');
                """
            ]
        )

        // 生成 4 个 .codex/generated_images/<uuid> 目录
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(indexUUID)/hero.png", byteCount: 512)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(indexUUID)/banner.webp", byteCount: 512)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(zstUUID)/icon.png", byteCount: 512)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(subagentUUID)/sprite1.png", byteCount: 512)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(subagentUUID)/sprite2.png", byteCount: 512)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(orphanUUID)/a.png", byteCount: 512)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(orphanUUID)/b.jpg", byteCount: 512)
        _ = try sandbox.createFile(relativeToHome: ".codex/generated_images/\(orphanUUID)/c.png", byteCount: 512)

        let dbBefore = try Data(contentsOf: stateDBURL)
        let report = ScanEngine(homeDirectory: sandbox.homeURL).scan()
        let codex = try XCTUnwrap(report.clientSummaries.first(where: { $0.profile.id == "codex" }))
        let imageItems = Dictionary(
            uniqueKeysWithValues: codex.items
                .filter { $0.ruleID == "codex-generated-images" }
                .map { ($0.fileName, $0) }
        )

        // 命中 session_index.jsonl
        let fromIndex = try XCTUnwrap(imageItems[indexUUID])
        XCTAssertEqual(fromIndex.displayName, "对话图片缓存 · 设计品牌官网主视觉")
        XCTAssertEqual(fromIndex.sessionTitle, "设计品牌官网主视觉")
        XCTAssertTrue(fromIndex.safetyNote.contains("共 2 张图片"))

        // 命中本轮扫描解压的 .jsonl.zst
        let fromZst = try XCTUnwrap(imageItems[zstUUID])
        XCTAssertTrue(fromZst.displayName.contains("对话图片缓存"))
        XCTAssertTrue(fromZst.displayName.contains("帮我生成一组极简科技感应用图标草图"))
        XCTAssertEqual(fromZst.sessionProjectName, "brand-studio")
        XCTAssertTrue(fromZst.safetyNote.contains("共 1 张图片"))

        // 命中 state_5.sqlite 子代理父会话继承
        let fromSubagent = try XCTUnwrap(imageItems[subagentUUID])
        XCTAssertEqual(fromSubagent.displayName, "对话图片缓存 · 开发微信3D弹珠台小游戏（子代理）")
        XCTAssertEqual(fromSubagent.sessionTitle, "开发微信3D弹珠台小游戏（子代理）")
        XCTAssertEqual(fromSubagent.sessionProjectName, "pinball-3d")
        XCTAssertTrue(fromSubagent.safetyNote.contains("共 2 张图片"))

        // 未找到关联会话时给出可读兜底说明，不裸露完整 UUID
        let orphan = try XCTUnwrap(imageItems[orphanUUID])
        XCTAssertEqual(orphan.displayName, "对话图片缓存 · 3 张图片 (44444444)")
        XCTAssertNil(orphan.sessionTitle)
        XCTAssertTrue(orphan.safetyNote.contains("未找到关联会话（可能已删除或归档）"))

        // 严格只读：state_5.sqlite 未被修改，且未生成 -wal/-shm 锁文件
        XCTAssertEqual(try Data(contentsOf: stateDBURL), dbBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDBURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDBURL.path + "-shm"))
    }

    func testCrossClientSessionAssociationCoversAllSupportedAIClients() throws {
        // 1. DeepSeek Harness (.dsh/sessions/<ws>/session-<uuid>/session.v4.jsonl.zstd)
        let dshSessionDir = sandbox.homeURL.appendingPathComponent(
            ".dsh/sessions/default-workspace/session-c3790724-d8f6-44c6-8b91-7953f9823437"
        )
        try writeData(Data(Self.dshZstdBytes), to: dshSessionDir.appendingPathComponent("session.v4.jsonl.zstd"))

        // 2. WorkBuddy (workbuddy.db + ~/WorkBuddy/<ts> + .workbuddy/workspace/sessions/<uuid> + .file-rollback.ndjson)
        let wbSessionID = "55555555-5555-7555-8555-555555555555"
        let wbOrphanID = "66666666-6666-7666-8666-666666666666"
        let wbTaskPath = sandbox.homeURL.appendingPathComponent("WorkBuddy/2026-11-18-11-20-11").path
        try createSQLiteDatabase(
            at: sandbox.homeURL.appendingPathComponent(".workbuddy/workbuddy.db"),
            statements: [
                "CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, title TEXT, custom_title TEXT, updated_at INTEGER);",
                """
                INSERT INTO sessions (id, cwd, title, custom_title, updated_at) VALUES
                ('\(wbSessionID)', '\(wbTaskPath)', '自动标题', '制作星球互动网页', 1795000000);
                """
            ]
        )
        _ = try sandbox.createFile(relativeToHome: "WorkBuddy/2026-11-18-11-20-11/index.html", byteCount: 256)
        _ = try sandbox.createFile(relativeToHome: ".workbuddy/workspace/sessions/\(wbSessionID)/snap.txt", byteCount: 256)
        _ = try sandbox.createFile(relativeToHome: ".workbuddy/workspace/sessions/\(wbOrphanID)/snap.txt", byteCount: 256)
        try writeUTF8(
            #"{"type":"user","message":{"role":"user","content":"<system-reminder data-role=\"user-context\">ignored</system-reminder>"}}"# + "\n"
                + #"{"type":"user","message":{"role":"user","content":"重构回滚日志解析逻辑"}}"# + "\n",
            to: sandbox.homeURL.appendingPathComponent(".workbuddy/projects/-Users-alice-demo/\(wbSessionID).jsonl")
        )
        try writeUTF8("{}\n", to: sandbox.homeURL.appendingPathComponent(".workbuddy/projects/-Users-alice-demo/\(wbSessionID).file-rollback.ndjson"))

        // 3. Claude Code (sessions + .claude/debug/<uuid>.txt 关联与无关联兜底)
        let claudeID = "77777777-7777-7777-8777-777777777777"
        let claudeOrphanID = "88888888-8888-7888-8888-888888888888"
        try writeUTF8(
            #"{"type":"user","cwd":"/Users/alice/workspace/claude-app","message":{"role":"user","content":"优化内存泄漏问题"}}"# + "\n"
                + #"{"type":"custom-title","customTitle":"排查播放器内存泄漏"}"# + "\n",
            to: sandbox.homeURL.appendingPathComponent(".claude/projects/-Users-alice-workspace-claude-app/\(claudeID).jsonl")
        )
        try writeUTF8("debug log", to: sandbox.homeURL.appendingPathComponent(".claude/debug/\(claudeID).txt"))
        try writeUTF8("orphan debug", to: sandbox.homeURL.appendingPathComponent(".claude/debug/\(claudeOrphanID).txt"))

        // 4. Gemini / Antigravity (conversation_summaries.db + brain/<uuid> + orphan)
        let agID = "99999999-9999-7999-8999-999999999999"
        let agOrphanID = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
        try createSQLiteDatabase(
            at: sandbox.homeURL.appendingPathComponent(".gemini/antigravity/conversation_summaries.db"),
            statements: [
                "CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, preview TEXT, workspace_uris TEXT, project_id TEXT);",
                "CREATE TABLE conversations_fts (conversation_id TEXT, title TEXT, workspace TEXT, project TEXT, user_body TEXT);",
                """
                INSERT INTO conversation_summaries VALUES
                ('\(agID)', '重构图片压缩管线', '优化 PNG 体积', '["file:///Users/alice/workspace/media-kit"]', 'media-kit');
                """
            ]
        )
        _ = try sandbox.createFile(relativeToHome: ".gemini/antigravity/brain/\(agID)/plan.md", byteCount: 256)
        _ = try sandbox.createFile(relativeToHome: ".gemini/antigravity/brain/\(agOrphanID)/draft.md", byteCount: 256)

        // 5. OpenCode (opencode.db session_v2 + storage/session/<id> + log/<id>.log)
        let ocID = "ses_opencode_demo_001"
        try createSQLiteDatabase(
            at: sandbox.homeURL.appendingPathComponent(".local/share/opencode/opencode.db"),
            statements: [
                "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, title TEXT, directory TEXT, path TEXT, slug TEXT);",
                "INSERT INTO session_v2 VALUES ('\(ocID)', '迁移 Vite 8 构建配置', '/Users/alice/workspace/web-portal', NULL, 'vite8-migrate');"
            ]
        )
        _ = try sandbox.createFile(relativeToHome: ".local/share/opencode/storage/session/\(ocID)/state.json", byteCount: 128)
        _ = try sandbox.createFile(relativeToHome: ".local/share/opencode/log/\(ocID).log", byteCount: 128)

        // 6. ZCode (tasks-index.sqlite + .zcode/workspace/draft-<uuid>)
        let zcodeDir = sandbox.homeURL.appendingPathComponent(".zcode/workspace/draft-bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb")
        try createSQLiteDatabase(
            at: sandbox.homeURL.appendingPathComponent(".zcode/v2/tasks-index.sqlite"),
            statements: [
                "CREATE TABLE tasks (task_id TEXT, title TEXT, cli_title TEXT, workspace_key TEXT, workspace_path TEXT, root_path TEXT, updated_at INTEGER);",
                "CREATE TABLE projects (project_id TEXT, name TEXT);",
                "INSERT INTO tasks VALUES ('sess_zcode_1', '制作剪纸风格交互官网', '制作剪纸风格交互官网', '\(zcodeDir.path)', '\(zcodeDir.path)', '\(zcodeDir.path)', 1795000000);"
            ]
        )
        _ = try sandbox.createFile(relativeToHome: ".zcode/workspace/draft-bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb/index.html", byteCount: 128)

        // 7. GitHub Copilot CLI (.copilot/session-state/<uuid>/workspace.yaml)
        try writeUTF8(
            "summary: \"修复 OAuth 回调验签失败\"\ncwd: /Users/alice/workspace/auth-gateway\n",
            to: sandbox.homeURL.appendingPathComponent(".copilot/session-state/cccccccc-cccc-7ccc-8ccc-cccccccccccc/workspace.yaml")
        )

        // 8. Jan (jan/threads/<id>/thread.json)
        try writeUTF8(
            #"{"id":"jan_thread_1","title":"本地模型量化对比分析"}"#,
            to: sandbox.homeURL.appendingPathComponent("jan/threads/jan_thread_1/thread.json")
        )

        // 9. Cursor (.cursor/projects/<encoded-path> 解码；含 store.db 的 chats 目录仍受 SafetyGuard 保护)
        _ = try sandbox.createFile(
            relativeToHome: ".cursor/projects/Users-alice-workspace-swiftui-list/agent-transcripts/demo.jsonl",
            byteCount: 128
        )
        let cursorChatDir = sandbox.homeURL.appendingPathComponent(".cursor/chats/projhash/dddddddd-dddd-7ddd-8ddd-dddddddddddd")
        let cursorMetaHex = Data(#"{"name":"排查 SwiftUI 列表卡顿"}"#.utf8).map { String(format: "%02x", $0) }.joined()
        try createSQLiteDatabase(
            at: cursorChatDir.appendingPathComponent("store.db"),
            statements: [
                "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);",
                "INSERT INTO meta VALUES ('0', '\(cursorMetaHex)');"
            ]
        )

        // 10. Claude Desktop (local-agent-mode-sessions/<org>/metadata.json)
        try writeUTF8(
            #"{"title":"整理季度研发路线图"}"#,
            to: sandbox.homeURL.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/org-1/local_eeee/metadata.json")
        )

        // 11. Windsurf Cascade (.codeium/windsurf/cascade/<uuid>.pb)
        let windsurfUUID = "ffffffff-ffff-7fff-8fff-ffffffffffff"
        _ = try sandbox.createFile(relativeToHome: ".codeium/windsurf/cascade/\(windsurfUUID).pb", byteCount: 256)

        let report = ScanEngine(homeDirectory: sandbox.homeURL).scan()
        let byClient = Dictionary(uniqueKeysWithValues: report.clientSummaries.map { ($0.profile.id, $0) })

        // DeepSeek Harness 断言
        let deepseek = try XCTUnwrap(byClient["deepseek"])
        let dshItem = try XCTUnwrap(deepseek.items.first(where: { $0.ruleID == "deepseek-sessions" }))
        XCTAssertEqual(dshItem.sessionTitle, "库存扣减超卖问题排查")
        XCTAssertEqual(dshItem.preferredDisplayTitle, "库存扣减超卖问题排查")
        XCTAssertEqual(dshItem.sessionProjectName, "order-engine")
        XCTAssertTrue(dshItem.displayName.contains("排查高并发下单库存扣减超卖问题"))

        // WorkBuddy 断言（任务目录 + 回滚快照 + 回滚日志 + 过滤 <system-reminder data-role=...> + 无关联兜底）
        let wb = try XCTUnwrap(byClient["workbuddy"])
        let wbTask = try XCTUnwrap(wb.items.first(where: { $0.ruleID == "workbuddy-task-folders" }))
        XCTAssertEqual(wbTask.sessionTitle, "制作星球互动网页")
        XCTAssertEqual(wbTask.preferredDisplayTitle, "制作星球互动网页")

        let wbMatchedSnap = try XCTUnwrap(wb.items.first(where: { $0.ruleID == "workbuddy-workspace-sessions" && $0.fileName == wbSessionID }))
        XCTAssertEqual(wbMatchedSnap.displayName, "文件回滚快照 · 制作星球互动网页")
        XCTAssertEqual(wbMatchedSnap.sessionTitle, "制作星球互动网页")

        let wbOrphanSnap = try XCTUnwrap(wb.items.first(where: { $0.ruleID == "workbuddy-workspace-sessions" && $0.fileName == wbOrphanID }))
        XCTAssertEqual(wbOrphanSnap.displayName, "文件回滚快照 · 1 个文件 (66666666)")
        XCTAssertTrue(wbOrphanSnap.safetyNote.contains("未找到关联会话"))

        let wbSessionFile = try XCTUnwrap(wb.items.first(where: { $0.fileName == "\(wbSessionID).jsonl" }))
        XCTAssertFalse(wbSessionFile.displayName.contains("<system-reminder"))
        XCTAssertTrue(wbSessionFile.displayName.contains("重构回滚日志解析逻辑"))

        let wbRollbackLog = try XCTUnwrap(wb.items.first(where: { $0.fileName == "\(wbSessionID).file-rollback.ndjson" }))
        XCTAssertEqual(wbRollbackLog.sessionTitle, "制作星球互动网页（文件回滚记录）")

        // Claude Code 调试日志关联与兜底断言
        let claude = try XCTUnwrap(byClient["claude-code"])
        let claudeMatchedDebug = try XCTUnwrap(claude.items.first(where: { $0.ruleID == "claude-code-debug" && $0.fileName == "\(claudeID).txt" }))
        XCTAssertEqual(claudeMatchedDebug.displayName, "调试日志 · 排查播放器内存泄漏")
        XCTAssertEqual(claudeMatchedDebug.sessionTitle, "排查播放器内存泄漏")
        XCTAssertEqual(claudeMatchedDebug.sessionProjectName, "claude-app")

        let claudeOrphanDebug = try XCTUnwrap(claude.items.first(where: { $0.ruleID == "claude-code-debug" && $0.fileName == "\(claudeOrphanID).txt" }))
        XCTAssertEqual(claudeOrphanDebug.displayName, "调试日志 (88888888)")
        XCTAssertTrue(claudeOrphanDebug.safetyNote.contains("未找到关联会话"))

        // Gemini / Antigravity brain 断言
        let ag = try XCTUnwrap(byClient["gemini-antigravity"])
        let agMatched = try XCTUnwrap(ag.items.first(where: { $0.fileName == agID }))
        XCTAssertEqual(agMatched.sessionTitle, "重构图片压缩管线")
        XCTAssertEqual(agMatched.sessionProjectName, "media-kit")

        let agOrphan = try XCTUnwrap(ag.items.first(where: { $0.fileName == agOrphanID }))
        XCTAssertEqual(agOrphan.displayName, "会话工作区 (aaaaaaaa)")
        XCTAssertTrue(agOrphan.safetyNote.contains("未找到关联会话"))

        // OpenCode 会话目录 + 日志关联断言
        let oc = try XCTUnwrap(byClient["opencode"])
        let ocSession = try XCTUnwrap(oc.items.first(where: { $0.ruleID == "opencode-file-sessions" }))
        XCTAssertEqual(ocSession.sessionTitle, "迁移 Vite 8 构建配置")
        XCTAssertEqual(ocSession.sessionProjectName, "web-portal")

        let ocLog = try XCTUnwrap(oc.items.first(where: { $0.ruleID == "opencode-logs" }))
        XCTAssertEqual(ocLog.displayName, "运行日志 · 迁移 Vite 8 构建配置")
        XCTAssertEqual(ocLog.sessionTitle, "迁移 Vite 8 构建配置")

        // ZCode 工作区断言
        let zcode = try XCTUnwrap(byClient["zcode"])
        let zcodeItem = try XCTUnwrap(zcode.items.first(where: { $0.ruleID == "zcode-workspace" }))
        XCTAssertEqual(zcodeItem.sessionTitle, "制作剪纸风格交互官网")

        // Copilot CLI 断言
        let copilot = try XCTUnwrap(byClient["copilot"])
        let copilotItem = try XCTUnwrap(copilot.items.first(where: { $0.ruleID == "copilot-session-state" }))
        XCTAssertEqual(copilotItem.sessionTitle, "修复 OAuth 回调验签失败")
        XCTAssertEqual(copilotItem.sessionProjectName, "auth-gateway")

        // Jan 断言
        let jan = try XCTUnwrap(byClient["jan"])
        let janItem = try XCTUnwrap(jan.items.first(where: { $0.ruleID == "jan-threads" }))
        XCTAssertEqual(janItem.sessionTitle, "本地模型量化对比分析")

        // Cursor 项目目录解码与 store.db 安全边界断言
        let cursor = try XCTUnwrap(byClient["cursor"])
        let cursorProjectItem = try XCTUnwrap(cursor.items.first(where: { $0.ruleID == "cursor-projects" }))
        XCTAssertEqual(cursorProjectItem.sessionProjectName, "swiftui-list")
        XCTAssertTrue(cursorProjectItem.displayName.contains("swiftui-list"))
        // 含 store.db 的目录受 SafetyGuard 保护，不会进入待清理列表
        XCTAssertFalse(cursor.items.contains(where: { $0.ruleID == "cursor-chats" }))
        XCTAssertGreaterThan(cursor.skippedProtectedCount, 0)

        // Claude Desktop 断言
        let claudeDesktop = try XCTUnwrap(byClient["claude-desktop"])
        let desktopItem = try XCTUnwrap(claudeDesktop.items.first(where: { $0.ruleID == "claude-desktop-local-agent-sessions" }))
        XCTAssertEqual(desktopItem.sessionTitle, "整理季度研发路线图")

        // Windsurf Cascade 断言
        let windsurf = try XCTUnwrap(byClient["windsurf"])
        let wsItem = try XCTUnwrap(windsurf.items.first(where: { $0.ruleID == "windsurf-cascade-sessions" }))
        XCTAssertEqual(wsItem.displayName, "Cascade 会话 (ffffffff)")
    }

    // MARK: - Helpers

    private func writeUTF8(_ content: String, to url: URL) throws {
        try writeData(Data(content.utf8), to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func createSQLiteDatabase(at url: URL, statements: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        XCTAssertEqual(openResult, SQLITE_OK, "无法创建测试数据库 \(url.path)")
        defer {
            if let db {
                sqlite3_close(db)
            }
        }
        guard let db else { return }
        for sql in statements {
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let message = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
                sqlite3_free(errMsg)
                XCTFail("执行 SQL 失败：\(message)")
            }
        }
    }
}

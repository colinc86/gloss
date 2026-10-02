import Foundation
import Testing
@testable import Remote

struct SFTPCodecTests {
    func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    func data(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    @Test func encodesRequestsAgainstHandBuiltBytes() {
        // INIT version 3: length 5, type 1, uint32 3.
        #expect(hex(SFTPCodec.encode(.initialize(version: 3), id: 0)) == "00000005" + "01" + "00000003")
        // OPEN id=7 path "/a" flags READ attrs empty: length = 1+4+(4+2)+4+4 = 19
        #expect(hex(SFTPCodec.encode(.open(path: "/a", flags: .read, attributes: SFTPAttributes()), id: 7)) == "00000013" + "03" + "00000007" + "00000002" + "2f61" + "00000001" + "00000000")
        // READ id=1 handle "h" offset 0x100000000 length 32768
        #expect(hex(SFTPCodec.encode(.read(handle: Data("h".utf8), offset: 0x1_0000_0000, length: 32768), id: 1)) == "00000016" + "05" + "00000001" + "00000001" + "68" + "0000000100000000" + "00008000")
        // WRITE id=2 handle "h" offset 5 data "xyz"
        #expect(hex(SFTPCodec.encode(.write(handle: Data("h".utf8), offset: 5, data: Data("xyz".utf8)), id: 2)) == "00000019" + "06" + "00000002" + "00000001" + "68" + "0000000000000005" + "00000003" + "78797a")
        // RENAME id=3 "/x" "/y"
        #expect(hex(SFTPCodec.encode(.rename(oldPath: "/x", newPath: "/y"), id: 3)) == "00000011" + "12" + "00000003" + "00000002" + "2f78" + "00000002" + "2f79")
        // EXTENDED id=4 "limits@openssh.com" with no data
        let limits = SFTPCodec.encode(.extended(name: "limits@openssh.com", data: Data()), id: 4)
        #expect(hex(limits) == "0000001b" + "c8" + "00000004" + "00000012" + hex(Data("limits@openssh.com".utf8)))
        // MKDIR with permissions and mtime
        let attrs = SFTPAttributes(permissions: 0o755, atime: 1, mtime: 2)
        #expect(hex(SFTPCodec.encode(.mkdir(path: "/d", attributes: attrs), id: 5)) == "0000001b" + "0e" + "00000005" + "00000002" + "2f64" + "0000000c" + "000001ed" + "00000001" + "00000002")
    }

    @Test func decodesVersionWithExtensions() throws {
        var buffer = data("00000026" + "02" + "00000003" + "00000018" + hex(Data("posix-rename@openssh.com".utf8)) + "00000001" + "31")
        let frame = try #require(try SFTPCodec.decode(from: &buffer))
        #expect(frame.id == nil)
        #expect(frame.reply == .version(3, extensions: ["posix-rename@openssh.com": "1"]))
        #expect(buffer.isEmpty)
    }

    @Test func decodesStatusHandleDataAttrsAndName() throws {
        var buffer = Data()
        buffer += data("00000018" + "65" + "00000009" + "00000002" + "00000007" + hex(Data("No such".utf8)) + "00000000")
        buffer += data("0000000a" + "66" + "00000001" + "00000001" + "41")
        buffer += data("0000000c" + "67" + "00000002" + "00000003" + "616263")
        buffer += data("0000001d" + "69" + "00000003" + "0000000d" + "0000000000000010" + "000001a4" + "00000001" + "00000002")
        // NAME with two entries, the second with ATTRS size only
        buffer += data("00000035" + "68" + "00000004" + "00000002"
            + "00000001" + "2e" + "00000003" + "6c6f6e" + "00000000"
            + "00000005" + "612e747874" + "00000003" + "2d2d2d" + "00000001" + "000000000000002a")
        let status = try #require(try SFTPCodec.decode(from: &buffer))
        #expect(status.id == 9)
        #expect(status.reply == .status(SFTPStatus(code: .noSuchFile, message: "No such", language: "")))
        let handle = try #require(try SFTPCodec.decode(from: &buffer))
        #expect(handle == SFTPFrame(id: 1, reply: .handle(Data("A".utf8))))
        let payload = try #require(try SFTPCodec.decode(from: &buffer))
        #expect(payload == SFTPFrame(id: 2, reply: .data(Data("abc".utf8))))
        let attrs = try #require(try SFTPCodec.decode(from: &buffer))
        guard case .attrs(let decoded) = attrs.reply else { Issue.record("expected attrs"); return }
        #expect(decoded.size == 16 && decoded.permissions == 0o644 && decoded.atime == 1 && decoded.mtime == 2 && decoded.uid == nil)
        #expect(decoded.fileType == .other)
        let names = try #require(try SFTPCodec.decode(from: &buffer))
        guard case .name(let entries) = names.reply else { Issue.record("expected name"); return }
        #expect(entries.map(\.filename) == [".", "a.txt"])
        #expect(entries[1].attributes.size == 42)
        #expect(buffer.isEmpty)
    }

    @Test func partialBuffersAndOversizedLengths() throws {
        var partial = data("00000010" + "65" + "0000")
        #expect(try SFTPCodec.decode(from: &partial) == nil)
        #expect(partial.count == 7, "nothing consumed until a whole packet is present")
        var oversized = data("ffffffff" + "65")
        #expect(throws: SFTPCodecError.oversizedPacket(0xffff_ffff)) { try SFTPCodec.decode(from: &oversized) }
        var unknown = data("00000005" + "ff" + "00000001")
        #expect(throws: SFTPCodecError.unknownType(0xff)) { try SFTPCodec.decode(from: &unknown) }
    }

    @Test func attributesRoundTripEveryFlagCombination() throws {
        let cases: [SFTPAttributes] = {
            var list: [SFTPAttributes] = []
            for mask in 0..<16 {
                var attributes = SFTPAttributes()
                if mask & 1 != 0 { attributes.size = 123 }
                if mask & 2 != 0 { attributes.uid = 501; attributes.gid = 20 }
                if mask & 4 != 0 { attributes.permissions = 0o100644 }
                if mask & 8 != 0 { attributes.atime = 10; attributes.mtime = 20 }
                list.append(attributes)
            }
            var extended = SFTPAttributes(size: 1)
            extended.extended = [("x@example", Data([1, 2]))]
            list.append(extended)
            return list
        }()
        for attributes in cases {
            var writer = BinaryWriter()
            writer.append(attributes)
            var reader = BinaryReader(writer.data)
            let back = try reader.attributes()
            #expect(back == attributes)
            #expect(reader.remaining == 0)
        }
        #expect(SFTPAttributes(permissions: 0o040755).fileType == .directory)
        #expect(SFTPAttributes(permissions: 0o120777).fileType == .symlink)
        #expect(SFTPAttributes(permissions: 0o100600).mode == 0o600)
    }
}

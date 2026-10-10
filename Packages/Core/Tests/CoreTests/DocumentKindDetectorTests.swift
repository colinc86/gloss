import Foundation
import Testing
@testable import Core

struct DocumentKindDetectorTests {
    @Test func classifiesByExtensionAndName() {
        #expect(DocumentKindDetector.kind(forPath: "/a/PLAN.md") == .markdown)
        #expect(DocumentKindDetector.kind(forPath: "/a/dashboard.PNG") == .image)
        for name in ["photo.avif", "scan.jxl", "map.jp2", "favicon.ico", "AppIcon.icns"] {
            #expect(DocumentKindDetector.kind(forPath: "/a/\(name)") == .image, "\(name) opens in the image viewer, which ImageIO decodes for")
        }
        #expect(DocumentKindDetector.kind(forPath: "/a/spec.pdf") == .pdf)
        #expect(DocumentKindDetector.kind(forPath: "/a/data.tsv") == .csv)
        #expect(DocumentKindDetector.kind(forPath: "/a/main.swift") == .code)
        #expect(DocumentKindDetector.kind(forPath: "/a/events.jsonl") == .code)
        #expect(DocumentKindDetector.kind(forPath: "/a/notes.txt") == .text)
        #expect(DocumentKindDetector.kind(forPath: "/a/Makefile") == .code)
        #expect(DocumentKindDetector.kind(forPath: "/a/README") == .text)
        #expect(DocumentKindDetector.kind(forPath: "/a/.zshrc") == .text)
        #expect(DocumentKindDetector.kind(forPath: "/a/budget.numbers") == .file)
        #expect(DocumentKindDetector.kind(forPath: "/a/archive.zip") == .file)
        #expect(DocumentKindDetector.kind(forPath: "https://example.com/docs/index.html") == .web, "a URL is a live page, whatever it ends in")
        #expect(DocumentKindDetector.kind(forPath: "HTTP://localhost:3000/") == .web)
        #expect(DocumentKindDetector.kind(forPath: "/a/http://notaurl.md") == .markdown)
    }

    @Test func sniffsBinaryContent() {
        #expect(DocumentKindDetector.looksLikeText(Data("hello\nworld".utf8)))
        #expect(!DocumentKindDetector.looksLikeText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A])))
        #expect(DocumentKindDetector.looksLikeText(Data("caf\u{E9}".utf8).dropLast()), "a multi-byte character cut at the sample edge is still text")
        #expect(DocumentKindDetector.looksLikeText(Data([0x63, 0x61, 0x66, 0xE9, 0x0A])), "Latin-1 text without control bytes")
        #expect(!DocumentKindDetector.looksLikeText(Data((0..<400).map { UInt8($0 % 31 + 1) })), "NUL-free binary full of control bytes is not text")
        #expect(DocumentKindDetector.looksLikeText(Data()), "an empty file opens as an empty editor")
    }
}

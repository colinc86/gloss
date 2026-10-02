import Foundation
import Testing
@testable import Core

struct DocumentKindDetectorTests {
    @Test func classifiesByExtensionAndName() {
        #expect(DocumentKindDetector.kind(forPath: "/a/PLAN.md") == .markdown)
        #expect(DocumentKindDetector.kind(forPath: "/a/dashboard.PNG") == .image)
        #expect(DocumentKindDetector.kind(forPath: "/a/spec.pdf") == .pdf)
        #expect(DocumentKindDetector.kind(forPath: "/a/data.tsv") == .csv)
        #expect(DocumentKindDetector.kind(forPath: "/a/main.swift") == .code)
        #expect(DocumentKindDetector.kind(forPath: "/a/notes.txt") == .text)
        #expect(DocumentKindDetector.kind(forPath: "/a/Makefile") == .code)
        #expect(DocumentKindDetector.kind(forPath: "/a/README") == .text)
        #expect(DocumentKindDetector.kind(forPath: "/a/.zshrc") == .text)
        #expect(DocumentKindDetector.kind(forPath: "/a/budget.numbers") == .file)
        #expect(DocumentKindDetector.kind(forPath: "/a/archive.zip") == .file)
    }

    @Test func sniffsBinaryContent() {
        #expect(DocumentKindDetector.looksLikeText(Data("hello\nworld".utf8)))
        #expect(!DocumentKindDetector.looksLikeText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A])))
    }
}

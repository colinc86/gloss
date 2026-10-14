import Core
import Foundation
import Testing
@testable import Remote

struct ShellQuoteTests {
    @Test func quotesSingleQuotesTheShellWay() {
        #expect(ShellQuote.single("plain") == "'plain'")
        #expect(ShellQuote.single("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.single("a b\"c$d") == #"'a b"c$d'"#)
        #expect(ShellQuote.command(["rm", "-rf", "--", "/tmp/x y"]) == "'rm' '-rf' '--' '/tmp/x y'")
    }
}

struct ChildProcessTests {
    @Test func capturesOutputAndExitCode() async throws {
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 3"]))
        async let out = process.collectStdout()
        async let err = process.collectStderr()
        #expect(try await process.exitCode == 3)
        #expect(String(decoding: await out, as: UTF8.self) == "out")
        #expect(String(decoding: await err, as: UTF8.self) == "err")
    }

    @Test func pipesStdin() async throws {
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/cat", arguments: [], stdin: .pipe))
        try await process.write(Data("hello stdin".utf8))
        process.closeStdin()
        #expect(String(decoding: await process.collectStdout(), as: UTF8.self) == "hello stdin")
        #expect(try await process.exitCode == 0)
    }

    @Test func drainsLargeOutputWithoutBlocking() async throws {
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x'; head -c 300000 /dev/zero | tr '\\0' 'y' >&2"]))
        async let out = process.collectStdout()
        async let err = process.collectStderr()
        #expect(try await process.exitCode == 0)
        #expect(await out.count == 3_000_000)
        #expect(await err.count == 300_000)
    }

    @Test func terminateStopsASleepingChild() async throws {
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
        process.terminate()
        let code = try await process.exitCode
        #expect(code != 0)
        #expect(!process.isRunning)
    }
}

struct SSHConfigTests {
    func write(_ text: String, name: String, in directory: String) throws -> String {
        let path = "\(directory)/\(name)"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func enumeratesConcreteAliasesAndFollowsIncludes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-sshcfg-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(directory)/conf.d", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try write("Host extra1 extra2\n  User me\n", name: "conf.d/a.conf", in: directory)
        let main = try write("""
        # comment
        Include \(directory)/conf.d/*.conf
        Host *
          ServerAliveInterval 10
        Host devbox work-? # the desktop
          HostName devbox.example
        Host "quoted"
        Match host devbox
          User other
        Host !negated extra1
        """, name: "config", in: directory)
        let aliases = SSHConfig.hostAliases(from: main).map(\.alias)
        #expect(aliases == ["extra1", "extra2", "devbox", "quoted"])
        #expect(SSHConfig.split("HostName=foo.example") == ("HostName", "foo.example"))
        #expect(SSHConfig.split("Host \"a b\"") == ("Host", "a b"))
        #expect(SSHConfig.words("box # old one") == ["box"], "a # word starts a comment, as ssh reads it")
        #expect(SSHConfig.words("box#1 other") == ["box#1", "other"], "a # inside a word is part of it")
    }

    @Test func resolvesThroughSSH() async throws {
        let resolved = try #require(await SSHConfig.resolve("localhost"))
        #expect(resolved.hostName == "localhost")
        #expect(resolved.port == 22)
        // A host added in Settings resolves with its own options, as a connection would.
        let manual = try #require(await SSHConfig.resolve("gloss-added-host", options: ["-o", "HostName=build.example", "-o", "Port=2222", "-o", "User=ci"]))
        #expect(manual.hostName == "build.example" && manual.port == 2222 && manual.user == "ci")
    }

    @Test func aHungMatchExecIsKilledWithSSH() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-sshexec-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let marker = "gloss-hung-\(UUID().uuidString.prefix(8))"
        let config = try write("Match exec \"/bin/sh -c 'sleep 37; true' \(marker)\"\n  User x\n", name: "config", in: directory)
        let started = ContinuousClock.now
        let resolved = await SSHConfig.resolve("somehost", options: ["-F", config], timeout: .milliseconds(500))
        #expect(resolved == nil)
        #expect(ContinuousClock.now - started < .seconds(4))
        try await Task.sleep(for: .milliseconds(200))
        let survivors = try ChildProcess.launch(ChildProcessSpec(executable: "/usr/bin/pgrep", arguments: ["-f", marker]))
        let found = String(decoding: await survivors.collectStdout(), as: UTF8.self)
        #expect(found.isEmpty, "the Match exec shell outlived ssh: \(found)")
    }

    @Test func aConfigThatIncludesItselfIsReadOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-sshloop-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(directory)/conf.d", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // Six files that each include the whole folder: 6^8 reads without a visited set.
        for index in 0..<6 {
            _ = try write("Include \(directory)/conf.d/*\nHost h\(index)\n", name: "conf.d/\(index)", in: directory)
        }
        let main = try write("Include \(directory)/conf.d/*\nInclude \(directory)/config\nHost top\n", name: "config", in: directory)
        let started = ContinuousClock.now
        let aliases = SSHConfig.hostAliases(from: main).map(\.alias)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(Set(aliases) == ["h0", "h1", "h2", "h3", "h4", "h5", "top"])
    }
}

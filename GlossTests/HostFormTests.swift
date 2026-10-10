import Testing
@testable import Gloss

/// The Add Host form refuses what ssh can't use or the database can't keep, saying why.
struct HostFormTests {
    @Test func namesAndPortsSshCanUse() {
        let taken: Set<String> = ["workbox"]
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken) == nil)
        #expect(HostForm.problem(name: " buildbox ", port: "2222", taken: taken) == nil, "surrounding spaces are trimmed")
        #expect(HostForm.problem(name: "build box", port: "", taken: taken) == "A name can't contain spaces.")
        #expect(HostForm.problem(name: "-oProxyCommand=x", port: "", taken: taken) == "A name can't start with a hyphen.", "ssh would read it as an option")
        #expect(HostForm.problem(name: "GitHub", port: "", taken: taken) == "“GitHub” is a name Gloss uses for itself.")
        #expect(HostForm.problem(name: "local", port: "", taken: taken) != nil)
        #expect(HostForm.problem(name: "workbox", port: "", taken: taken) == "Another host is already called “workbox”.")
        #expect(HostForm.problem(name: "buildbox", port: "abc", taken: taken) == "The port is a number from 1 to 65535.", "it used to be dropped without a word")
        #expect(HostForm.problem(name: "buildbox", port: "70000", taken: taken) != nil)
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, hostName: "10.0.0 .5") == "A host name can't contain spaces.")
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, user: "my user") == "A user name can't contain spaces.")
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, identityFile: "/k/My Keys/id") == nil, "a space in a path is quoted for ssh")
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, identityFile: "/k/\"id") != nil)
        #expect(HostForm.problem(name: "", port: "", taken: taken) == nil, "an empty name only leaves Save off")
    }
}

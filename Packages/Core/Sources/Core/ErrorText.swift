import Foundation

extension Error {
    /// What to show a person: the error's own message when it has one (`LocalizedError`), a Swift error's description
    /// otherwise (`"\(error)"` alone printed a case name, `notFound("/x")`, past the message written for it), and
    /// Foundation's localized text for a Cocoa error, whose description is a domain-and-code dump.
    public var userMessage: String {
        if let localized = self as? any LocalizedError, let text = localized.errorDescription { return text }
        let bridged = self as NSError
        if bridged.domain == NSCocoaErrorDomain || bridged.domain == NSPOSIXErrorDomain || bridged.domain == NSURLErrorDomain
            || bridged.domain == NSOSStatusErrorDomain {
            return bridged.localizedDescription
        }
        return "\(self)"
    }
}

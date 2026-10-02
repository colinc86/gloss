import Testing
@testable import Viewers

struct ViewersModuleTests {
    @Test func moduleLoads() {
        #expect(ViewersModule.name == "Viewers")
    }
}

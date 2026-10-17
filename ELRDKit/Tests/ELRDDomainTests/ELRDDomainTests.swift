import Testing
@testable import ELRDDomain

@Suite("ELRDDomain – Grundgerüst")
struct ELRDDomainModuleTests {
    @Test("Modul ist eingebunden")
    func moduleName() {
        #expect(ELRDDomainModule.name == "ELRDDomain")
    }
}

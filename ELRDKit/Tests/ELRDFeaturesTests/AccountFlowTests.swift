import Foundation
import Testing
@testable import ELRDAuth
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDPersistence
import ELRDStore

@Suite("Start und Anmeldung")
@MainActor
struct AccountFlowTests {
    @Test func launchOptions() {
        #expect(AppLaunchOptions(arguments: ["ELRD", "--demo-screen", "login"]).demoScreen == .login)
        #expect(AppLaunchOptions(arguments: ["ELRD", "--demo-screen", "unsinn"]).demoScreen == nil)
        #expect(AppLaunchOptions(arguments: ["ELRD", "--demo-screen"]).demoScreen == nil)
        #expect(AppLaunchOptions(arguments: ["ELRD"]).demoScreen == nil)
    }

    @Test func setupFormValidation() {
        var form = InitialSetupForm()
        #expect(form.problems == [.nameMissing, .passwordTooShort])
        #expect(!form.isValid)
        form.lastName = "  Beispiel "
        form.password = "geheim1"
        #expect(!form.isValid, "Wiederholung fehlt noch")
        form.passwordRepeat = "geheim2"
        #expect(form.problems == [.passwordsDiffer])
        form.passwordRepeat = "geheim1"
        #expect(form.isValid)
    }

    @Test func initials() {
        let full = UserAccount(firstName: "erika", lastName: "Beispiel", role: .admin, createdAt: Date())
        #expect(full.initials == "EB")
        let callsignOnly = UserAccount(firstName: "", lastName: "", callsign: "ELRD 1", role: .commander, createdAt: Date())
        #expect(callsignOnly.initials == "EL")
    }

    @Test(arguments: AppLaunchOptions.DemoScreen.allCases)
    func demoEnvironments(screen: AppLaunchOptions.DemoScreen) async throws {
        let environment = try await AppEnvironment.demo(screen: screen)
        #expect(environment.isDemo)
        #expect(environment.device.numberPrefix == "A")
        switch screen {
        case .setup:
            #expect(environment.userService.needsInitialSetup)
        case .login:
            #expect(environment.userService.directory.activeUsers.count == 3)
            #expect(environment.userService.currentUser == nil)
        case .missions, .newMission, .workspace, .missionDetails, .patients, .patientTiles, .patientDetail, .injuries, .sections, .addUnit, .addPlaceholder, .replacePlaceholder, .map, .mapTopo, .mapObject:
            #expect(environment.userService.currentUser?.displayName == "Erika Beispiel")
            let missions = try MissionOverview.load(from: environment.repository)
            #expect(missions.count == 6)
            #expect(missions.filter { !$0.isClosed }.count == 1, "genau ein laufender Einsatz")
        }
        #expect(environment.demoScreen == screen)
        let masterData = try environment.repository.document(MasterDataSet.self, key: .masterData)
        #expect(masterData?.injuries.count == 59)
    }

    @Test func loginSuggestsLastSignedInUser() {
        var erika = UserAccount(firstName: "Erika", lastName: "Beispiel", role: .admin, createdAt: Date())
        var max = UserAccount(firstName: "Max", lastName: "Muster", role: .commander, createdAt: Date())
        let jana = UserAccount(firstName: "Jana", lastName: "Probe", role: .commander, createdAt: Date())
        #expect(LoginSuggestion.preferred(in: [erika, max, jana])?.id == erika.id, "noch niemand angemeldet: erste Person")
        erika.lastLoginAt = Date(timeIntervalSince1970: 1_000)
        max.lastLoginAt = Date(timeIntervalSince1970: 2_000)
        #expect(LoginSuggestion.preferred(in: [erika, max, jana])?.id == max.id)
        #expect(LoginSuggestion.preferred(in: []) == nil)
    }

    @Test func deviceIdentityIsCreatedOnceAndKept() throws {
        let repository = InMemoryRepository()
        let first = try AppEnvironment.loadOrCreateDevice(in: repository)
        let second = try AppEnvironment.loadOrCreateDevice(in: repository)
        #expect(first == second)
    }

    @Test func masterDataSeedDoesNotOverwrite() throws {
        let repository = InMemoryRepository()
        let custom = MasterDataSet(units: [MasterUnit(callsign: "Eigen", type: .rtw)], revision: 5)
        try repository.saveDocument(custom, key: .masterData, at: Date())
        try AppEnvironment.seedMasterDataIfNeeded(in: repository)
        #expect(try repository.document(MasterDataSet.self, key: .masterData) == custom)
    }
}

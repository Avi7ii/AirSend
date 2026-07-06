import AirSendUpdater
import Foundation

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

@MainActor
private func testInstallIfReadyInvokesStoredImmediateInstallHandler() {
    let installer = PendingUpdateInstaller()
    var didInstall = false

    installer.markReady {
        didInstall = true
    }

    expect(installer.isUpdateReady, "installer should report a downloaded update")
    expect(installer.installIfReady(), "installer should run the stored immediate install handler")
    expect(didInstall, "stored immediate install handler should be invoked")
}

@MainActor
private func testClearResetsReadyStateAndNotifies() {
    let installer = PendingUpdateInstaller()
    var observedReadyStates: [Bool] = []
    installer.onChange = {
        observedReadyStates.append(installer.isUpdateReady)
    }

    installer.markReady {}
    installer.clear()

    expect(observedReadyStates == [true, false], "ready state changes should be reported")
    expect(!installer.isUpdateReady, "clear should reset readiness")
    expect(!installer.installIfReady(), "install should not run after clear")
}

@main
struct AirSendUpdaterSelfTestRunner {
    static func main() async {
        await MainActor.run {
            testInstallIfReadyInvokesStoredImmediateInstallHandler()
            testClearResetsReadyStateAndNotifies()
            print("AirSendUpdaterSelfTests passed")
        }
    }
}

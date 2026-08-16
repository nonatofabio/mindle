import Foundation

var failures = 0
failures += runBrowserDisplaySettingsChecks()
failures += runFileBrowserPresentationChecks()
failures += runSSHTargetChecks()
failures += await runSSHTransportChecks()
failures += runTitleBarDoubleClickChecks()

if failures > 0 {
    print("\nFAILED: \(failures) check(s)")
    exit(1)
}
print("\nALL CHECKS PASSED")
exit(0)

import Foundation

var failures = 0
failures += runFileTreeChecks()
failures += await runGitFileMetadataChecks()
failures += runSSHTargetChecks()
failures += await runSSHTransportChecks()
failures += await runFileBrowserStateChecks()

if failures > 0 {
    print("\nFAILED: \(failures) check(s)")
    exit(1)
}
print("\nALL CHECKS PASSED")
exit(0)

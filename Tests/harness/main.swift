import Foundation

var failures = 0
failures += runFileTreeChecks()
failures += runGitFileMetadataChecks()
failures += runSSHTargetChecks()
failures += runSSHProfileChecks()
failures += runRemoteMarkdownAssetsChecks()
failures += await runSSHTransportChecks()
failures += await runFileBrowserStateChecks()
failures += runTitleBarDoubleClickChecks()

if failures > 0 {
    print("\nFAILED: \(failures) check(s)")
    exit(1)
}
print("\nALL CHECKS PASSED")
exit(0)

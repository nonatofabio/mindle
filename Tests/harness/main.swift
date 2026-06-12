import Foundation

var failures = 0
failures += runSSHTargetChecks()

if failures > 0 {
    print("\nFAILED: \(failures) check(s)")
    exit(1)
}
print("\nALL CHECKS PASSED")
exit(0)

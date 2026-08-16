# Test Results

Environment: macOS 26.6.1 (arm64), Swift 6.3.1.

## Screenshot regression runs

| Run | Command | Result | Duration |
| --- | --- | --- | ---: |
| Red | `./run-screenshot-tests.sh` | Failed: all four baselines were missing | 2.11s |
| Record | `./run-screenshot-tests.sh --record` | Passed; baselines recorded | 1.66s |
| Verify 1 | `./run-screenshot-tests.sh` | Passed | 1.63s |
| Verify 2 | `./run-screenshot-tests.sh` | Passed | 1.77s |
| Verify 3 | `./run-screenshot-tests.sh` | Passed | 1.68s |

The populated light and dark baselines cover the scoped folder header, refresh
affordance, expanded hierarchy, and active-file treatment. The remaining
baselines cover the light empty state and dark error state with retry action.

## Focused validation

| Phase | Command | Result | Duration |
| --- | --- | --- | ---: |
| UI logic red | `./run-tests.sh` | Failed: presentation/settings/title-bar implementations were absent | 0.39s |
| UI logic green | `./run-tests.sh` | Passed: 14 focused UI checks plus the existing harness | 3.21s |
| App build | `./build.sh` | Passed | 16.88s |

These are correctness and screenshot-regression results, not performance
measurements.

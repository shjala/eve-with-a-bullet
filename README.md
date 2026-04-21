# eve-with-a-bullet

An hacky way to quickly run EVE ad-hock integration tests. These scripts
build EVE, boot it under QEMU, onboard via Adam, and give you an SSH
shell with an interactive test runner.

## Setup

Create a `.env` file with your repo path:

```
REPO_ROOT=/path/to/eve
```

Or pass it on every invocation with `--repo-root <path>`.

## Scripts

### run.sh

Build and run EVE from the current repo under QEMU with TPM enabled.
Sets up Adam as the controller, onboards the device, injects an SSH
key, uploads a test binary, and drops you into an interactive test
REPL where you can pick and run individual tests over SSH. You can
also rebuild and re-upload the test binary from within the REPL
without restarting the session, and test a GitHub PR directly with
`--pr <number>`.

### upgrade_to_image.sh

Clones EVE master, builds it, boots it under QEMU, onboards via Adam,
then upgrades to a user-supplied rootfs image by writing it to the
other partition and rebooting. Useful for testing a locally built
rootfs against a clean master baseline.

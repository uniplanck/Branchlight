# Branchlight Release Runbook

This document describes the bounded direct-distribution release path. It does not authorize a release and it does not replace the required real-Mac Finder/XPC acceptance gate.

## Current distribution assumptions

- Product: `Branchlight.app`
- Finder integration: embedded `BranchlightFinderExtension.appex`
- Git mutation runtime: embedded `BranchlightGitService.xpc`
- Core runtime: embedded `BranchlightCore.framework`
- Current version: `0.1.0`
- Current build: `1`
- Minimum macOS: `13.0`
- Direct distribution requires Developer ID signing, Hardened Runtime, Apple notarization, stapling, Gatekeeper assessment, ZIP + DMG packaging, and SHA-256 checksums.

Host, Finder Extension, and Git XPC service must keep the same marketing version and build number.

## CI release-readiness gate

Pull-request CI runs:

```bash
bash scripts/build-release.sh --unsigned
```

This is intentionally unsigned. It verifies that the canonical Release configuration can produce an optimized app containing:

- `Contents/MacOS/Branchlight`
- `Contents/PlugIns/BranchlightFinderExtension.appex`
- `Contents/XPCServices/BranchlightGitService.xpc`
- `Contents/Frameworks/BranchlightCore.framework`

The unsigned gate also creates and verifies a temporary compressed DMG so the distribution container path cannot rot unnoticed. The script validates Host/Finder/XPC version parity, the Finder Sync extension point, and the XPC service type. CI separately checks source coverage, security boundaries, and the release configuration source of truth.

A successful unsigned CI build is not a signed/notarized release acceptance.

## Signed build prerequisites

The signed path is deliberately fail-closed. Set:

```text
BRANCHLIGHT_DEVELOPMENT_TEAM
```

Optional override:

```text
BRANCHLIGHT_CODE_SIGN_IDENTITY
```

If omitted, the script requests `Developer ID Application`.

For notarization, first create an `xcrun notarytool` Keychain profile outside the repository and set:

```text
BRANCHLIGHT_NOTARY_KEYCHAIN_PROFILE
```

Never commit signing certificates, `.p12` files, provisioning profiles, Apple credentials, notary passwords, private keys, or exported Keychain material.

## Signed build

The bounded build command is:

```bash
bash scripts/build-release.sh --signed
```

The script:

1. regenerates the Xcode project from `project.yml`,
2. validates Host/Finder/XPC version parity,
3. archives Release with Hardened Runtime forced on,
4. verifies Host, Finder Extension, and Git XPC signatures,
5. verifies Hardened Runtime on all three executable bundles,
6. packages the staplable app as a ZIP,
7. submits the ZIP to Apple when a notary Keychain profile is configured,
8. staples/validates the app and runs Gatekeeper assessment,
9. rebuilds the ZIP from the stapled app,
10. creates and verifies a compressed DMG,
11. signs the DMG,
12. submits/staples/validates the DMG and runs Gatekeeper open assessment when notarization is configured,
13. writes SHA-256 checksums for both ZIP and DMG.

The script does **not** create a GitHub Release, upload an artifact, tag the repository, merge a pull request, or push `main`.

## Required real-Mac acceptance before publication

CI cannot prove Finder Sync behavior on the user's actual signed installation. Before any public release, validate a signed/notarized build on a real Mac:

- only the intended Branchlight app is installed/running,
- Finder Extension registration is singular and enabled,
- bundled `BranchlightGitService.xpc` launches on demand,
- Host mutations cross the XPC boundary and reconcile against real Git,
- repository badges appear and update after Git changes,
- Finder context menu shows repository intelligence,
- Stage / Unstage / Show Changes intents hand off to the Host,
- Finder callbacks remain responsive on large folders,
- app restart restores monitored repositories,
- Finder restart recovers badges and menus,
- sleep/wake and user-session reactivation refresh cached state,
- File Provider-managed folders display the existing compatibility warning where appropriate,
- GitHub OAuth tokens remain Host-Keychain-only,
- no credentials appear in App Group cache files,
- AI Workbench shows the exact sanitized prompt before provider execution,
- local AI provider output is never automatically applied to Git state.

Mutation failure is reconciliation-first. A lost XPC reply must not be blindly replayed through an in-process fallback because the service may already have changed repository state.

## Publication gate

A release is publishable only when all of the following are true:

- pull-request CI is green,
- signed archive succeeds,
- Host, Finder Extension, and Git XPC all have Hardened Runtime,
- ZIP notarization/app stapling succeeds,
- DMG notarization and stapling succeeds,
- Gatekeeper assessments succeed,
- real-Mac Finder + XPC acceptance succeeds,
- version/build metadata is final,
- release notes are reviewed,
- ZIP and DMG SHA-256 values are recorded,
- the exact artifact intended for publication is the artifact that passed acceptance.

If any gate is missing, the state is `NOT_RELEASED` rather than an inferred success.

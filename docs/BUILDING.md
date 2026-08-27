# Building Branchlight

This guide covers unsigned verification, signed Finder/XPC development builds, and the canonical Release pipeline.

## Project generation is authoritative

`project.yml` is the source of truth for Branchlight targets and build settings. It defines the Host app, Finder Extension, BranchlightCore, tests, and the bundled `BranchlightGitService.xpc` runtime service.

Install XcodeGen and regenerate before opening or building the project after pulling build-graph changes:

```bash
xcodegen generate
```

CI also regenerates the project before every build. The release script regenerates it again itself so a stale checked-in `Branchlight.xcodeproj` cannot silently produce an incomplete release bundle.

Do not commit a personal Development Team identifier or provisioning material into `project.yml` or the generated project.

## Unsigned verification

Apple signing is not required for Core development and CI-style verification.

```bash
xcodegen generate

xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test
```

This compiles the Host, Core, Finder Extension, bundled Git XPC service, and tests without provisioning the Finder runtime.

The app-hosted XPC integration tests exercise the real bundled service process against isolated temporary Git repositories. Coverage includes repository reads, direct XPC stage/unstage, and the Host mutation adapter crossing XPC for stage/commit before read-back reconciliation.

For the optimized Release bundle gate, use the canonical script rather than reproducing its build settings manually:

```bash
bash scripts/build-release.sh --unsigned
```

The script requires XcodeGen, regenerates the project from `project.yml`, builds Release, and verifies that the resulting app contains:

- `Contents/MacOS/Branchlight`
- `Contents/PlugIns/BranchlightFinderExtension.appex`
- `Contents/XPCServices/BranchlightGitService.xpc`
- `Contents/Frameworks/BranchlightCore.framework`

Host, Finder Extension, and Git XPC version/build numbers must match.

## Fully signed Finder + XPC integration

Finder Sync, App Group communication, and final real-machine XPC acceptance require a signing configuration belonging to your Apple Development team.

### 1. Choose your identifiers

The repository uses canonical Branchlight identifiers such as:

- `com.uniplanck.Branchlight`
- `com.uniplanck.Branchlight.Extension`
- `com.uniplanck.Branchlight.GitService`
- `group.com.uniplanck.branchlight`

If those identifiers do not belong to your team, replace them with equivalents owned by that team.

Keep the Host, Finder Extension, and XPC bundle IDs distinct. Host and Finder Extension must continue using the same App Group identifier.

### 2. Generate the project

Run:

```bash
xcodegen generate
```

This is mandatory after target/build-graph changes. Do not rely on an older checked-in project snapshot for signed runtime acceptance.

### 3. Select a Development Team

Open `Branchlight.xcodeproj` in Xcode and select your team where signing requires it, including:

- `Branchlight`
- `BranchlightFinderExtension`
- `BranchlightGitService`

Do not commit your Team ID or provisioning material.

### 4. Configure the App Group

Create or select an App Group owned by your team, enable it for the Host and Finder Extension, and update:

- `BranchlightHost/BranchlightHost.entitlements`
- `BranchlightFinderExtension/BranchlightFinderExtension.entitlements`

with that identifier.

### 5. Build and run

Run the `Branchlight` scheme from Xcode.

The resulting Host application should contain both the Finder Extension and `BranchlightGitService.xpc`. The XPC service is launch-on-demand; merely seeing the bundle is not equivalent to runtime acceptance.

### 6. Enable the Finder extension

If macOS does not enable the extension automatically, enable **Branchlight Finder Extension** in System Settings. The exact location can vary between macOS releases.

### 7. Exercise a repository

Use a disposable or otherwise safe repository for signed runtime acceptance.

Open Branchlight and choose the repository. Confirm that repository state appears in the Host and that Finder badges/menu state are populated from the App Group cache. Finder must not spawn Git, perform GitHub HTTP calls, or connect directly to the Git XPC service.

Then exercise at least these Host actions:

1. Stage a changed file.
2. Unstage it.
3. Stage it again and create a test commit.
4. Refresh and confirm the repository reconciles to the state reported by real Git.
5. If using merge/rebase/cherry-pick/revert acceptance, induce only controlled disposable-repository cases and verify conflict/abort flows.

All Git mutations now cross the bundled XPC boundary and converge on the service-side repository coordinator. Read-only fallback may use the Host implementation, but **mutation fallback/replay is forbidden**. If an XPC mutation times out or loses its reply, refresh/reconcile repository state before any retry because the remote process may already have changed Git state.

Signed acceptance is complete only when both of these are observed on the real Mac:

- Finder Extension behavior works with the signed Host/App Group pair.
- Host mutations succeed through the launch-on-demand bundled XPC service and reconcile correctly after completion/failure.

## Signed Release / notarization

The canonical command is:

```bash
BRANCHLIGHT_DEVELOPMENT_TEAM='<team-id>' \
BRANCHLIGHT_CODE_SIGN_IDENTITY='Developer ID Application' \
bash scripts/build-release.sh --signed
```

When `BRANCHLIGHT_NOTARY_KEYCHAIN_PROFILE` is configured, the script additionally submits the ZIP with `notarytool --wait`, staples the app, validates the staple, runs Gatekeeper assessment, rebuilds the ZIP, and emits its SHA-256 checksum.

Without a notarization profile, the signed pipeline explicitly reports `SIGNED_NOT_NOTARIZED`; it does not pretend notarization occurred.

The repository does not currently claim a generally downloadable Developer ID signed and notarized binary. Public release acceptance requires the real Developer ID / notarization path plus signed Finder and XPC runtime verification on macOS.

# Building Branchlight

This guide explains the two useful build modes for Branchlight: unsigned verification and a fully signed Finder-integrated development build.

## Unsigned verification

If you want to inspect the code, work on the Git engine, modify the SwiftUI host, or run tests, Apple signing is not required.

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test
```

This builds the application targets and runs the test suite without attempting to provision the Finder extension.

## Fully signed Finder integration

Finder Sync and App Group communication need a signing configuration that belongs to your Apple Development team.

### 1. Choose your identifiers

The repository uses canonical Branchlight identifiers such as:

- `com.uniplanck.Branchlight`
- `com.uniplanck.Branchlight.Extension`
- `group.com.uniplanck.branchlight`

If those identifiers do not belong to your team, replace them with your own equivalents.

Keep the host and extension bundle IDs distinct, and use the same App Group in both entitlement files.

### 2. Select a Development Team

Open `Branchlight.xcodeproj` in Xcode and select your team for:

- `Branchlight`
- `BranchlightFinderExtension`

Do not commit your personal Team ID or provisioning material back to the repository.

### 3. Configure the App Group

Create or select an App Group owned by your team, enable it for both targets, and update:

- `BranchlightHost/BranchlightHost.entitlements`
- `BranchlightFinderExtension/BranchlightFinderExtension.entitlements`

with that identifier.

### 4. Build and run

Run the `Branchlight` scheme from Xcode.

The host application should launch and the Finder extension should be embedded in the app bundle.

### 5. Enable the Finder extension

If macOS does not enable the extension automatically, enable **Branchlight Finder Extension** in System Settings. The exact location changes between macOS releases.

### 6. Pick a repository

Open Branchlight and choose a Git repository. The host writes repository snapshots to the shared App Group cache and the Finder extension consumes that cache.

## XcodeGen

`project.yml` is the source project definition used during development. The generated `Branchlight.xcodeproj` is committed, so XcodeGen is optional for normal contributors.

If you do use XcodeGen, install it separately and run:

```bash
xcodegen generate
```

After regeneration, review the project diff carefully and make sure no local Development Team identifier was introduced before committing.

## Signing and distribution

The open-source repository does not currently ship a generally downloadable Developer ID signed and notarized binary.

A local Apple Development build is appropriate for development and Finder runtime testing. Public binary distribution should use a separate Developer ID / notarization pipeline rather than reusing development signing.

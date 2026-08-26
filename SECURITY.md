# Security Policy

Branchlight executes the system Git client against repositories explicitly opened or selected by the user. Security-sensitive reports involving command construction, path handling, Finder intent handling, App Group data exchange, remote-provider credentials, AI context handling, or destructive Git operations are welcome.

## Reporting a vulnerability

Please avoid publishing a working exploit in a public issue before maintainers have had a reasonable chance to investigate it.

For now, open a GitHub issue with the minimum detail needed to request a private follow-up, or use GitHub's private vulnerability reporting feature if it is enabled for this repository.

## Runtime trust boundaries

### Finder Extension

The Finder Extension is intentionally a cache-and-intent client. It must not:

- spawn Git or other subprocesses,
- perform GitHub or other provider HTTP requests,
- own OAuth flows,
- access GitHub credentials from Keychain.

Git state is produced outside Finder callbacks and shared through the App Group cache. CI rejects new Finder source that introduces the prohibited subprocess, network, or credential APIs covered by the architecture gate.

### GitHub credentials

GitHub OAuth tokens belong to the Host application and are stored in the macOS Keychain. They are not persisted in BranchlightCore models, the App Group status cache, or Finder intent files.

The OAuth client ID is configuration, not a secret, but Branchlight does not ship a fabricated or fallback client ID. A real GitHub OAuth application must be configured before live Device Flow acceptance can succeed.

### Intelligent Git context

Repository content is untrusted data, including text that attempts to instruct an AI model. Branchlight builds an explicit context object before provider execution and:

- bounds path, history, and diff context,
- redacts configured sensitive-path classes such as `.env`, key, credential, and secret files,
- marks truncation and redacted paths,
- tells providers to treat repository content as data rather than instructions,
- never automatically applies an AI response to Git state.

Sensitive-path filtering is defense in depth, not a universal secret scanner. The AI Workbench intentionally shows the exact sanitized prompt before any configured provider is run.

### Local AI command provider

The optional local provider is disabled unless `BRANCHLIGHT_AI_EXECUTABLE` explicitly names an absolute executable file. Arguments are supplied as a JSON string array through `BRANCHLIGHT_AI_ARGUMENTS_JSON`; Branchlight does not construct a shell command or invoke `sh -c`.

When enabled, the configured executable is user-trusted code. Branchlight reduces accidental repository access by running it in a fresh temporary working directory with a limited inherited environment, prompt input through a bounded temporary file, timeout/cancellation handling, and bounded stdout/stderr capture. The provider can still access resources available to that executable under the user's macOS account, including resources reachable through inherited `HOME`; do not configure an executable you do not trust.

## Shared cache resilience

App Group cache and pending-intent JSON writes are atomic. If persisted JSON is malformed, Branchlight quarantines the corrupt file instead of repeatedly consuming it, retains only a bounded number of corrupt backups, and resumes from a fresh cache state.

## Scope

Especially useful reports include:

- command/argument injection,
- unsafe path traversal or repository-boundary handling,
- unintended destructive Git behavior,
- Finder Extension trust-boundary problems,
- App Group cache or intent corruption,
- credential leakage or OAuth boundary violations,
- AI context redaction bypasses or unsafe automatic application,
- local provider isolation or output-bound bypasses,
- privilege or sandbox boundary issues.

Branchlight is currently alpha software and has not undergone an external security audit.

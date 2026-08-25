# Security Policy

Branchlight executes the system Git client against repositories explicitly opened or selected by the user. Security-sensitive reports involving command construction, path handling, Finder intent handling, App Group data exchange, or destructive Git operations are welcome.

## Reporting a vulnerability

Please avoid publishing a working exploit in a public issue before maintainers have had a reasonable chance to investigate it.

For now, open a GitHub issue with the minimum detail needed to request a private follow-up, or use GitHub's private vulnerability reporting feature if it is enabled for this repository.

## Scope

Especially useful reports include:

- command/argument injection,
- unsafe path traversal or repository-boundary handling,
- unintended destructive Git behavior,
- Finder Extension trust-boundary problems,
- App Group cache or intent corruption,
- privilege or sandbox boundary issues.

Branchlight is currently alpha software and has not undergone an external security audit.

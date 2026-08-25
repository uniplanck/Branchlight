# Finder Sync boundary

Branchlight treats Finder as a latency-sensitive integration surface.

The Finder extension is responsible for cached badge lookup, contextual menu construction, selection planning, and forwarding user intent to the host. It is not responsible for full repository scans or long-running Git subprocesses.

This rule is deliberate: Finder should not become the lifecycle owner of expensive Git work.

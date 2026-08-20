# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Email **security@tesseractsoftwares.com** with:

- what the issue is, and what an attacker gains
- steps to reproduce, or a proof of concept
- the SDK version and Godot version
- whether it affects the SDK, the Praxsuite gateway, or both

We aim to acknowledge within **2 business days** and to give you an assessment and a fix
timeline within **10 business days**.

If you would like credit in the release notes, say so and tell us how to name you. If you would
rather stay anonymous, that is fine too.

We will not take legal action against good-faith research that follows this policy: report
privately, do not access or modify data belonging to anyone else, and give us a reasonable
window to fix the issue before disclosing it.

## Supported versions

| Version | Supported |
|---|---|
| 1.x | ✅ |
| < 1.0 | ❌ |

## What counts as a vulnerability here

The SDK runs on hardware an attacker controls. That shapes what is a bug and what is simply the
threat model, so please check this list before reporting.

**In scope:**

- The SDK sending a credential somewhere it should not, or logging one unredacted
- `PraxKeyGuard` accepting an `sk_live_` key at any entry point
- `tools/check_no_secrets.gd` failing to catch a secret key that ends up in an exported game
- Sessions stored less carefully than `PraxSessionStore` documents
- A way to make the SDK talk to a host other than the configured gateway
- Anything letting one player's session reach another player's data

**Not vulnerabilities — these are documented properties, not defects:**

- *The publishable key can be extracted from an exported game.* It is designed to be public,
  like a Stripe publishable key. That is why the guidance is to scope it to as little as
  possible and rely on per-player tokens instead.
- *A player can read their own session token from their own device.* Any client-side credential
  store on hardware the owner controls has this ceiling — including
  `PraxSessionStore.EncryptedFile`, whose passphrase your game must be able to compute and a
  player can therefore extract. The mitigation is to make a stolen session worth little: keep
  authority server-side.
- *A modified client can send arbitrary requests.* Assumed. The gateway is the boundary, which
  is why anything valuable belongs behind an endpoint.
- *The editor export warning does not stop an export.* Godot's export API has no hook that can
  cancel one. This is a documented limitation, and `tools/check_no_secrets.gd` is the
  enforceable gate — run it in CI.

If you are unsure which side of that line something falls on, report it. We would rather triage
a non-issue than miss a real one.

## For developers using this SDK

Most incidents involving a backend SDK are configuration, not code. Before shipping:

- No `sk_live_` anywhere in your project. Run the CI gate and let it check:
  `godot --headless --path . --script addons/praxsuite/tools/check_no_secrets.gd`
- Your publishable key scoped to the minimum, ideally **no table scopes at all** — auth routes
  skip table-scope checks, so sign-in works on a credential that can reach nothing
- Per-player tables carry an ownership column with a `__SELF__` row filter on the **table** scope
  **and** a `{{claim:sub}}` default value template on the **column** scope — both, not one
- Currency, inventory and score writes go through gateway endpoints, not client table writes
- `PraxLog.minimum` left at its default in release builds; `VERBOSE` logs request and response
  bodies

The reasoning behind the two isolation settings, including the silent failure when only the row
filter is configured, is in the [README](README.md#per-player-isolation-needs-two-settings).

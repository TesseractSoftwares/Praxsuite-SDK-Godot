# Changelog

All notable changes to the Praxsuite SDK for Godot.

## [1.0.0] - 2026-08-20

First release. Pure GDScript, no dependencies, Godot 4.2+ including non-.NET builds.

### Added

- `Prax` autoload registered by the editor plugin — no scene setup, no build step.
- **Auth**: register, login, logout, password reset, resend confirmation, and the
  unauthenticated `auth/config` read. Concurrent refreshes share one in-flight request, because
  the gateway retires the old refresh token as it issues the new one. Profile fields carry
  forward across a refresh, so a signed-in player never briefly reads as anonymous.
- **Sessions**: in memory by default; `PraxSessionStore.EncryptedFile` persists to `user://`
  under a passphrase you supply, with the limits of that documented rather than implied.
- **Query builder**: select, where, order, limit, offset, group/having, aggregates, related-table
  includes, plus `fetch` / `first` / `count` / `exists`.
- **Writes**: insert, insert_many, update, update_by_id, delete, delete_by_id, upsert. Unscoped
  updates and deletes are refused, as are native columns the backend maintains.
- **Endpoints**: `call_endpoint` / `get_endpoint` for server-authoritative logic.
- **Schema**: read the tables and columns this credential can actually see — the quickest way to
  tell a typo apart from a missing scope.
- **Credential guard**: `sk_live_` keys refused at every entry point, no opt-out. An export-time
  scan warns in the editor, and `tools/check_no_secrets.gd` fails a CI build.
- **Log scrubbing**: keys, JWTs and secret fields removed from every message the SDK emits.
- 81 offline conformance checks, runnable headless with no workspace or network.

### Notes for anyone porting from another Praxsuite SDK

- Errors are **returned, not thrown** — GDScript has no exceptions. Check with `is PraxError`.
- Godot decodes every JSON number as a float, so an Int column arrives as `1.0`. Cast with
  `int()` before using one as an index or an id.
- `Page.total` is `-1` when a total was not requested, so "no rows matched" stays
  distinguishable from "nobody asked".

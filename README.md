# Praxsuite SDK for Godot

Backend for your Godot game: player accounts, saves, leaderboards, inventories, and
server-authoritative logic. Pure GDScript, no dependencies, no build step.

Works in **any** Godot 4.3+ build — including the standard (non-.NET) one that most people use.
If you write C# in Godot you can use the [.NET SDK](https://github.com/TesseractSoftwares/Praxsuite-SDK-DotNet)
instead; this one is for GDScript.

```gdscript
func _ready() -> void:
    Prax.configure("your-workspace-id", "pk_live_...")

    var result = await Prax.auth.login(email, password)
    if result is PraxError:
        show_error(result.message)
        return

    # Only this player's saves come back. The server decides that, not this code.
    var page = await Prax.data.table("Saves").order_by_descending("UpdatedDate").limit(10).fetch()
    for row in page.rows:
        print(row["Slot"], " ", row["Level"])
```

---

## Install

1. Download `praxsuite-godot-<version>.zip` from
   [Releases](https://github.com/TesseractSoftwares/Praxsuite-SDK-Godot/releases), or clone this
   repo.
2. Copy `addons/praxsuite/` into your project's `addons/` folder.
3. **Project → Project Settings → Plugins →** enable **Praxsuite**.

Enabling the plugin registers a `Prax` autoload, which is how you reach the SDK from anywhere.
There is nothing to compile and no NuGet, npm or asset-store dependency.

## Configure

Call `configure()` once, early:

```gdscript
Prax.configure(
    "your-workspace-id",
    "pk_live_...",                          # publishable key
    "https://gateway.praxsuite.com",        # optional; your own tier or a local backend
)
```

Both values come from your workspace under **API Gateway**. `configure()` returns `null` on
success and a `PraxError` if something is wrong, so it is worth checking during development.

### Keeping players signed in

Sessions live in memory by default, so a player signs in each launch. That is the safe default,
not the convenient one. To persist:

```gdscript
Prax.configure(workspace_id, key, PraxRoutes.CLOUD_HOST,
    PraxSessionStore.EncryptedFile.new(OS.get_unique_id()))
```

Read the class docs before you do. Encryption keyed on something your game can compute is
protection against a copied save file and a curious player — never against a determined one.
Anything that must not be forged belongs behind a table scope on the server.

---

## Errors: returned, not thrown

GDScript has no exceptions, so every call returns either its result or a `PraxError`:

```gdscript
var page = await Prax.data.table("Scores").fetch()
if page is PraxError:
    if page.is_rate_limited:      # transient — back off and retry
        ...
    elif page.is_quota_exceeded:  # NOT transient — the workspace owner must upgrade
        ...
    return
```

`code` is stable and safe to branch on. `message` is human-facing and may change.

`is_rate_limited` and `is_quota_exceeded` both arrive as HTTP 429 and mean opposite things — one
is worth retrying and one never will be. That is exactly why they are separate checks.

Reads are retried automatically with backoff on transient failures. Writes are not: retrying a
failed insert is how you get two rows.

---

## Querying

```gdscript
var page = await Prax.data.table("Scores") \
    .select(["Player", "Score"]) \
    .where([PraxFilter.gte("Score", 100), PraxFilter.eq("Season", 3)]) \
    .order_by_descending("Score") \
    .limit(20) \
    .fetch()

print(page.rows.size(), " of ", page.total)   # total is -1 unless you asked for it
```

Nothing is sent until you await a terminal method — `fetch()`, `first()`, `count()`, `exists()`.

`PraxFilter` exposes **only** operators the gateway implements: `eq neq gt gte lt lte like ilike
in is between contains textsearch`. The friendly-sounding ones compile down —
`starts_with` becomes `like "value%"`, `is_null` becomes `is null`. An SDK that offered
`startsWith` as an operator would just produce a 400 on a player's machine.

### Two things about numbers

**Godot decodes every JSON number as a float.** An Int column arrives as `1.0`, not `1`. Cast
before using one as an index or an id:

```gdscript
var level := int(row["Level"])
```

**`total` is `-1` when it was not requested**, not `0` — so "no rows matched" stays
distinguishable from "nobody asked". Call `.with_total_count()` or `.count()` to get a real
number.

### Writes

```gdscript
await Prax.data.insert("Saves", {"Slot": 1, "Level": 12})
await Prax.data.update_by_id("Saves", row_id, {"Level": 13})
await Prax.data.delete("Saves", [PraxFilter.eq("Slot", 1)])
```

`update()` and `delete()` require conditions and refuse without them. Do not set an ownership
column yourself — see below.

---

## The security model, in short

**What belongs in a shipped game: a publishable key (`pk_live_`).** It identifies the workspace
and nothing more. The server decides what it may touch, through the table scopes you configure.

**A secret key (`sk_live_`) is refused at every entry point, with no opt-out flag.** A key inside
a game binary is a key every player has. Enabling the plugin also adds an export-time scan, and
`tools/check_no_secrets.gd` fails a CI build if one is ever committed.

Two things worth understanding before you ship:

**Every credential carries both halves.** There is no publishable-only credential. Whatever tables
you scope to the client credential are reachable by anyone holding the workspace id — and
`/{workspace}/auth/config` is unauthenticated, so the workspace id yields the publishable key.
Give the client credential the narrowest scopes your game needs and keep everything else on a
credential the game never sees.

**Anything a player must not influence belongs in an endpoint.** Currency awards, score
validation, item grants: the game asks for an outcome and the server decides it.

```gdscript
var result = await Prax.endpoints.call_endpoint("submit-score", {"score": score})
```

A trusted score is not a score the client computed carefully. It is a score the client did not
compute at all.

### Per-player isolation needs TWO settings

This is the most damaging misconfiguration in the platform, so it is worth stating plainly.

| Setting | Where | Value | Covers |
|---|---|---|---|
| Row filter | the role's **table** scope | `__SELF__` | select, update, delete |
| Default value template | the ownership **column**'s scope | `{{claim:sub}}` | insert |

The row filter cannot cover inserts, because an insert has no WHERE clause to constrain. If you
configure only the row filter, **inserts succeed with a null owner and the filter then hides
them** — the player saves a record and cannot read it back, with no error raised anywhere.

The default value template also blocks the client from setting the column at all, which is what
makes ownership untamperable. That rejection is the guarantee; do not work around it.

---

## Conformance is the law

Praxsuite has SDKs in several languages. Where they touch the gateway they do **not** get to
disagree. A single normative contract — the internal `Praxsuite-SDK-Conformance` repository —
defines the shared behaviour, and every SDK implements it identically:

1. **The contract is normative.** Where this SDK and the contract differ, this SDK is wrong.
2. **Every rule cites the backend source it derives from.** No rule rests on memory.
3. **Every rule exists because getting it wrong fails silently.** Wrong data, not an error.
4. **A behaviour change is a contract change first.** Not an implementation detail.

The contract is internal and deliberately has no public repository. Its value is that it is
authoritative for us, not that it is browsable — and it cites backend internals that are not
ours to publish. Everything a consumer of this SDK needs to know is in this README.

What it pins down, and why each one earned its place:

- **Operators.** Only the thirteen the parser accepts. A friendlier name is a runtime 400.
- **`meta.total`, never `meta.totalCount`.** Reading the wrong name returns nothing and reports
  zero, silently, forever. One SDK shipped that for months.
- **Three response envelopes.** `/query` is bare, `/auth/*` nests under `.data`, `/files` errors
  are a bare string. Assuming one shape mis-parses the other two.
- **`limit` is clamped up to a minimum of 1.** A zero-row count request quietly returns a row.
- **Secret keys refused, always.** No flag, no override, in any SDK.
- **No client-supplied identity parameter.** The server ignores it, so it would read as a
  security boundary while being decorative.

The whole suite runs offline in a few seconds:

```bash
godot --headless --path . --script addons/praxsuite/tests/run_tests.gd
```

81 checks, no workspace and no network needed.

---

## API surface

| | |
|---|---|
| `Prax.configure(...)` | Point at a workspace. Returns `null` or a `PraxError`. |
| `Prax.auth` | `register` `login` `logout` `ensure_fresh_session` `forgot_password` `verify_reset_code` `reset_password` `resend_confirmation` `get_config` |
| `Prax.data` | `table(name)` → query builder; `insert` `insert_many` `update` `update_by_id` `delete` `delete_by_id` `upsert` `execute` |
| `Prax.endpoints` | `call_endpoint` `get_endpoint` |
| `Prax.schema` | `tables` `table` `columns` `has_table` |
| `PraxFilter` | `eq neq gt gte lt lte like ilike contains text_search starts_with ends_with is_null is_not_null in_list between any_of all_of` |

`Prax.auth` emits `session_changed(session)` and `session_expired()`. Connect to the second one
to send a player back to your title screen rather than discovering the expiry on their next save.

## Requirements

Godot **4.3 or newer**, any build.

That floor is measured, not guessed. CI imports the project and runs the full suite on three engine
builds every commit — 4.3, and 4.7.2 which development happens against, and it used to claim 4.2.
**4.2.2 fails**: its parser doesn't resolve global class names and the `Prax` autoload on a first
import, so `plugin.gd` and every sample fail to load. 4.3 introduced the resolution pass that makes
it work, and there's no workaround worth carrying for an engine build from 2023.

If you're on 4.2, the fix is upgrading Godot.

## Licence

[Praxsuite Open SDK Licence](LICENSE) — source-available, not OSI open source.

Free to use in anything you build, including games you sell. Free to fork, modify and publish
your changes. Not free to resell as an SDK, or to point at a competing backend.

Derived from the Praxsuite SDK — <https://praxsuite.com>

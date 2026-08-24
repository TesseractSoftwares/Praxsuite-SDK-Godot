# Praxsuite SDK for Godot

Backend for your Godot game — player accounts, saves, leaderboards, inventories and
server-authoritative logic. Pure GDScript, zero dependencies, Godot 4.2+.

Enabling the plugin registers a `Prax` autoload, which is how you reach the SDK from anywhere.

```gdscript
func _ready() -> void:
    Prax.configure("your-workspace-id", "pk_live_...")

    var page = await Prax.data.table("Leaderboard") \
        .select(["Player", "Score"]) \
        .order_by_descending("Score") \
        .limit(10) \
        .fetch()

    if page is PraxError:
        push_error(page.message)
        return
    for row in page.rows:
        print(row["Player"], " ", row["Score"])
```

Errors come back as a `PraxError` value rather than being thrown — GDScript has no exceptions, so
check the result.

**Full documentation, the API surface and the security notes live in the repository README:**
<https://github.com/TesseractSoftwares/Praxsuite-SDK-Godot>

This copy is deliberately short. A full duplicate of the repository README would go stale the first
time either one changed, and a stale security note is worse than a link.

Two things worth reading there before you ship, because both fail *silently* rather than erroring:

- **Which key to use.** A game client is not a server you control. Use a `pk_live_` publishable key
  and scope the credential narrowly — a `sk_live_` key inside an exported build is readable by
  anyone who downloads it.
- **Per-user isolation needs TWO settings**, not one: a `__SELF__` row filter on the role's *table*
  scope, and a `{{claim:sub}}` default value template on the ownership *column*. Configure only the
  first and inserts succeed with a null owner, which the filter then hides — the player saves their
  progress and cannot read it back, with no error anywhere.

## Licence

[Praxsuite Open SDK Licence](LICENSE) — source-available, not OSI open source.

Free to use in anything you build, including games you sell. Free to fork, modify and publish your
changes. Not free to resell as an SDK, or to point at a competing backend.

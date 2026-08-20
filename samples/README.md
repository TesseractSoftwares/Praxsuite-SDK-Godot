# Samples

## quickstart

Configure, sign in, write a row, read it back, update it.

1. Open `quickstart/quickstart.gd` and fill in the constants at the top.
2. Create the `Saves` table in your workspace with `Slot` and `Level` number columns, and grant
   your credential access to it.
3. Run `quickstart/quickstart.tscn`.

Output goes to the Godot console. Logging is turned up to `VERBOSE` so you can watch the
requests — leave that out of a shipped game, since it logs request and response bodies.

The sample deliberately never sets an owner column. If the table is configured for per-player
isolation the gateway stamps ownership from the player's token and rejects any attempt to set it,
which is what makes ownership untamperable. See
[the README](../README.md#per-player-isolation-needs-two-settings).

# Contributing

Contributions are welcome — bug reports, fixes, docs, samples, platform support.

Before anything else: **security issues do not go in the issue tracker.** See
[SECURITY.md](SECURITY.md).

## Licence, up front

This SDK is under the [Praxsuite Open SDK Licence](LICENSE) — source-available, not OSI open
source. You can use it free in anything you build, including games you sell, and you can fork and
modify it. You cannot resell the SDK itself or use it to build a competing backend platform.

By contributing, you license your contribution under the same terms and confirm you have the
right to submit it. You keep the copyright in what you wrote.

## Running the tests

The whole suite is offline. No workspace, no credentials, no network:

```bash
godot --headless --path . --script addons/praxsuite/tests/run_tests.gd
```

It exits non-zero on failure, which is what CI checks. It covers the filter compiler, the query
builder, the three response envelopes, error classification, the credential guard and the log
scrubber — the parts where a mistake produces silently wrong data rather than a crash.

There is a second gate that must also pass:

```bash
godot --headless --path . --script addons/praxsuite/tools/check_no_secrets.gd
```

This fails the build if a `sk_live_` key is anywhere in the project. This repo is mirrored to a
public GitHub repo, so a committed key is a published key.

## Things worth knowing before you change code

These have all cost someone time already:

- **Regexes need raw strings.** In an ordinary GDScript string `\b` is a backspace character and
  `\s` is not an escape at all, so `"\b(pk|sk)_live_"` is both wrong and a parse error. Use
  `r"..."`, or `r'...'` when the pattern contains double quotes.
- **Godot's JSON decodes every number as a float.** An Int column arrives as `1.0`, not `1`. Cast
  with `int()` before using a value as an index, a count or an id.
- **`JSON.parse_string` pushes an engine error even when you handle the failure.** Use
  `PraxResult.parse_json_quietly()`, or an HTML error page from a proxy will look like an SDK
  crash in the consumer's console.
- **Guardrails must refuse before the first `await`.** GDScript helps here — calling a coroutine
  without `await` is a *parse* error, so a caller cannot silently ignore a refusal the way they
  can in C# or JavaScript. Keep it that way by returning the error early rather than awaiting
  first and validating after.
- **Nothing may log a credential.** Everything routes through `PraxLog`, which scrubs keys, JWTs
  and password fields. If you add a log line, use `PraxLog`, not `print`.
- **The client is untrusted.** Do not add an API that takes a caller-supplied identity. A
  parameter the server ignores reads like a security boundary while being a comment. Identity
  comes from the player's own token.
- **Zero dependencies is a feature.** Godot ships JSON, HTTP and regex in the engine. The SDK is
  pure GDScript so it works in every Godot build, including the non-.NET one that most people
  use. Please do not add a dependency without discussing it first.

## Conformance

Behaviour shared across the Praxsuite SDKs is not a matter of local judgement — see
[the conformance section of the README](README.md#conformance-is-the-law). If you change how a
filter compiles, how a response is parsed, or how a credential is classified, that is a contract
change, not an implementation change.

## Style

Match the surrounding code. A few conventions the codebase holds to:

- Comments explain *why*, not *what*. If a line needs a comment to say what it does, rename
  something instead.
- Public API gets `##` doc comments, written for someone who has never seen Praxsuite.
- Error messages say what to do next, not just what went wrong.

## Pull requests

1. Fork, branch from `master`
2. Make the change, keeping both gates above green
3. Add a test if you fixed a bug — it should fail before your fix
4. Update `CHANGELOG.md` under Unreleased
5. Open the PR describing what changed and why

Small, focused PRs get reviewed faster than large ones. If you are planning something
substantial, open an issue first so we can agree on the shape before you spend the time.

## Reporting a bug

Use the issue template. The two things that make a report actionable are the **exact error**
(every `PraxError` carries a stable `code` — include it) and a **minimal repro**. Godot version,
SDK version and platform help too.

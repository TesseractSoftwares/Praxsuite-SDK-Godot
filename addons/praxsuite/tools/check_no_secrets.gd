## Fails the build when a Praxsuite secret key is committed. Run it in CI:
##
##   godot --headless --path . --script addons/praxsuite/tools/check_no_secrets.gd
##
## Exits 0 when clean, 1 when a key is found. This is the enforceable half of the export guard -
## Godot's export API has no hook that can cancel an export, so the editor can only warn.
extends SceneTree


func _init() -> void:
	var offenders := PraxSecretScan.scan_project()

	if offenders.is_empty():
		print("No Praxsuite secret keys found.")
		quit(0)
		return

	printerr("A Praxsuite SECRET key (sk_live_) is present in this project:")
	for o in offenders:
		printerr("  - %s" % o)
	printerr("")
	printerr("Revoke that key in your workspace now - assume it is compromised.")
	printerr("Ship a publishable key (pk_live_) instead; a game binary is not a secret.")
	quit(1)

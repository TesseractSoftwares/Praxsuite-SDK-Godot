@tool
## Registers the `Prax` autoload, and scans the project for secret keys on export.
##
## About the export scan: Godot's export API has no hook that can abort an export, so this warns
## as loudly as the editor allows - an error dialog, a push_error, and a line in the output - but
## it cannot stop the build the way the Unity SDK's build guard does. The enforceable version is
## `tools/check_no_secrets.gd`, which exits non-zero and belongs in CI:
##
##   godot --headless --path . --script addons/praxsuite/tools/check_no_secrets.gd
##
## Treat the editor warning as a reminder and the CI check as the gate.
extends EditorPlugin

const AUTOLOAD_NAME := "Prax"
const CLIENT_SCRIPT := "res://addons/praxsuite/prax_client.gd"

var _export_guard: PraxExportGuard = null


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, CLIENT_SCRIPT)

	_export_guard = PraxExportGuard.new()
	add_export_plugin(_export_guard)

	print_rich("[color=green]Praxsuite[/color] SDK enabled. Call [code]Prax.configure(workspace_id, publishable_key)[/code] to begin.")


func _exit_tree() -> void:
	if _export_guard != null:
		remove_export_plugin(_export_guard)
		_export_guard = null
	remove_autoload_singleton(AUTOLOAD_NAME)


class PraxExportGuard extends EditorExportPlugin:

	func _get_name() -> String:
		return "PraxsuiteSecretScan"

	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String,
			_flags: int) -> void:
		var offenders := PraxSecretScan.scan_project()
		if offenders.is_empty():
			return

		var message := "A Praxsuite SECRET key (sk_live_) is present in this project:\n\n"
		for o in offenders:
			message += "  - %s\n" % o
		message += "\nAnyone who downloads this game can read it. Revoke that key in your "
		message += "workspace now, and ship a publishable key (pk_live_) instead.\n"

		# Everything the editor gives us to be noticed with. None of it can cancel the export.
		push_error("[Praxsuite] " + message)
		printerr(message)
		OS.alert(message, "Praxsuite: secret key in exported project")

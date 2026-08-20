## Finds Praxsuite secret keys committed into a project.
##
## Shared by the editor export warning and the CI check, so both agree on what counts.
##
## The pattern deliberately does not match this SDK's own test fixtures, which build fake keys by
## concatenating fragments at runtime for exactly this reason.
class_name PraxSecretScan
extends RefCounted

const SECRET_PATTERN := "sk_live_[A-Za-z0-9]{16,}"

## Text files worth reading. A key pasted into a .tscn or an exported .cfg ships just as readily
## as one in a script.
const EXTENSIONS := ["gd", "cs", "tscn", "tres", "cfg", "json", "txt", "md", "ini", "env"]

## Skipped: the SDK's own tests reference the pattern as a string, and .git is not exported.
const SKIP_PREFIXES := ["res://addons/praxsuite/tests/", "res://.git/"]


static func scan_project() -> PackedStringArray:
	return scan_directory("res://")


static func scan_directory(root: String) -> PackedStringArray:
	var offenders := PackedStringArray()
	var re := RegEx.new()
	re.compile(SECRET_PATTERN)
	_walk(root, re, offenders)
	return offenders


static func _walk(path: String, re: RegEx, offenders: PackedStringArray) -> void:
	for prefix in SKIP_PREFIXES:
		if path.begins_with(prefix):
			return

	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue

		var full := path.path_join(entry) if not path.ends_with("/") else path + entry

		if dir.current_is_dir():
			_walk(full, re, offenders)
		elif EXTENSIONS.has(entry.get_extension().to_lower()):
			var skip := false
			for prefix in SKIP_PREFIXES:
				if full.begins_with(prefix):
					skip = true
			if not skip:
				var file := FileAccess.open(full, FileAccess.READ)
				if file != null:
					var found := re.search(file.get_as_text())
					file.close()
					if found != null:
						# The key itself is never printed. Reporting where it is, is enough.
						offenders.append(full)

		entry = dir.get_next()
	dir.list_dir_end()

## Where a session lives between launches.
##
## The default is memory only: nothing is written to disk, and the player signs in each launch.
## That is the safe default rather than the convenient one, so persistence is something you ask
## for explicitly.
##
## What the encrypted store actually protects against:
##   - Another process, or a curious player, reading the refresh token out of a plain file.
##   - A save file copied off the device being replayed elsewhere, IF your passphrase is
##     device-derived rather than a constant.
##
## What it does NOT protect against: a determined player on their own machine. Any passphrase
## your game can compute, a player can extract from the same binary. Treat a persisted refresh
## token as "inconvenient to steal", never "safe". Anything that must not be forged belongs
## behind a table scope on the server, not behind this file.
class_name PraxSessionStore
extends RefCounted


## Discards the session when the game closes. The default.
class Memory extends RefCounted:
	var _session: PraxSession = null

	func load_session() -> PraxSession:
		return _session

	func save_session(session: PraxSession) -> void:
		_session = session

	func clear() -> void:
		_session = null


## Persists to an encrypted file under user://.
##
## The passphrase is yours to supply, and there is no default - a shared default passphrase
## would be worse than plaintext, because it would look like protection. Derive it from
## something device-specific (OS.get_unique_id() is a reasonable start) so a copied save file
## does not travel.
class EncryptedFile extends RefCounted:
	var _path: String
	var _passphrase: String

	func _init(passphrase: String, path: String = "user://praxsuite_session.dat") -> void:
		assert(not passphrase.is_empty(),
			"PraxSessionStore.EncryptedFile needs a passphrase. Derive one from OS.get_unique_id() if you have nothing better - see the class documentation for what this does and does not protect.")
		_passphrase = passphrase
		_path = path

	func load_session() -> PraxSession:
		if not FileAccess.file_exists(_path):
			return null

		var file := FileAccess.open_encrypted_with_pass(_path, FileAccess.READ, _passphrase)
		if file == null:
			# A changed passphrase, a corrupt file, or a save from another device. None of those
			# are worth a crash - the player just signs in again.
			PraxLog.warn("Could not read the stored session; it will be discarded and the player asked to sign in.")
			clear()
			return null

		var text := file.get_as_text()
		file.close()

		var parsed: Variant = PraxResult.parse_json_quietly(text)
		if not (parsed is Dictionary):
			clear()
			return null

		return PraxSession.from_dictionary(parsed)

	func save_session(session: PraxSession) -> void:
		if session == null or not session.is_valid:
			clear()
			return

		var file := FileAccess.open_encrypted_with_pass(_path, FileAccess.WRITE, _passphrase)
		if file == null:
			PraxLog.warn("Could not write the session to %s; it stays in memory for this run only." % _path)
			return

		file.store_string(JSON.stringify(session.to_dictionary()))
		file.close()

	func clear() -> void:
		if FileAccess.file_exists(_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))

class_name UserDataMigration
extends RefCounted
## Copy only preferences when a project rename creates its new user:// folder.
## Existing new-version preferences always win; logs and sessions are not copied.
const PREVIOUS_PROJECT_DIRECTORY := "灰烬王国 · 中世纪乱斗"
const PREFERENCE_FILES: PackedStringArray = ["settings.cfg", "lobby_preferences.cfg"]

static func migrate(previous_directory: String, current_directory: String) -> Error:
	for filename: String in PREFERENCE_FILES:
		var source := previous_directory.path_join(filename)
		var destination := current_directory.path_join(filename)
		if FileAccess.file_exists(destination) or not FileAccess.file_exists(source):
			continue
		var error := DirAccess.copy_absolute(source, destination)
		if error != OK:
			return error
	return OK

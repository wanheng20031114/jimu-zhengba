extends SceneTree
## Verify a renamed game preserves preferences without copying unrelated data.
var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _write(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(value)

func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://.local/rename-migration-%d" % OS.get_process_id())
	var previous := directory.path_join("previous")
	var current := directory.path_join("current")
	assert(DirAccess.make_dir_recursive_absolute(previous) == OK)
	assert(DirAccess.make_dir_recursive_absolute(current) == OK)
	_write(previous.path_join("settings.cfg"), "[keys]\n全军=\"F2\"\n")
	_write(previous.path_join("lobby_preferences.cfg"), "[lobby]\nname=\"指挥官\"\n")
	_write(previous.path_join("session.cfg"), "unrelated session data")
	check(UserDataMigration.migrate(previous, current) == OK, "initial migration succeeds")
	for filename: String in UserDataMigration.PREFERENCE_FILES:
		check(FileAccess.get_file_as_string(current.path_join(filename)) == FileAccess.get_file_as_string(previous.path_join(filename)), "UTF-8 preferences preserved: " + filename)
	check(not FileAccess.file_exists(current.path_join("session.cfg")), "unrelated session data is not copied")
	_write(current.path_join("settings.cfg"), "new-version settings")
	check(UserDataMigration.migrate(previous, current) == OK, "repeat startup succeeds")
	check(FileAccess.get_file_as_string(current.path_join("settings.cfg")) == "new-version settings", "new-version settings win")
	check(FileAccess.get_file_as_string(previous.path_join("settings.cfg")).contains("全军"), "legacy preferences remain unchanged")
	check(UserDataMigration.migrate(directory.path_join("missing"), current) == OK, "fresh install succeeds without legacy directory")
	# These are the exact flat directories and files created by this test.
	for folder: String in [previous, current]:
		for filename: String in DirAccess.get_files_at(folder):
			check(DirAccess.remove_absolute(folder.path_join(filename)) == OK, "test file cleanup")
		check(DirAccess.remove_absolute(folder) == OK, "test directory cleanup")
	check(DirAccess.remove_absolute(directory) == OK, "test root cleanup")
	print("USER_DATA_MIGRATION_RESULT ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

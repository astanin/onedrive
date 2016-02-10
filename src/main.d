import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio;
import config, itemdb, monitor, onedrive, sync, util;


void createSyncDir(string syncDirFullPath) {
    if (!exists(syncDirFullPath)) {
        mkdirRecurse(syncDirFullPath);
    } else if (isFile(syncDirFullPath)) {
        writeln(syncDirFullPath, " is a file, should be a directory.");
        throw new Exception("sync_dir is a file, should be a directory.");
    }
}


void main(string[] args)
{
	// always print log messages
	stdout = stderr;

	bool monitor, resync, verbose;
	try {
		auto opt = getopt(
			args,
			"monitor|m", "Keep monitoring for local and remote changes.", &monitor,
			"resync", "Forget the last saved state, perform a full sync.", &resync,
			"verbose|v", "Print more details, useful for debugging.", &verbose
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter(
				"Usage: onedrive [OPTION]...\n\n" ~
				"no option    Sync and exit.",
				opt.options
			);
			return;
		}
	} catch (GetOptException e) {
		writeln(e.msg);
		writeln("Try 'onedrive -h' for more information.");
		return;
	}

	string configDirName = expandTilde(environment.get("XDG_CONFIG_HOME", "~/.config")) ~ "/onedrive";
	string configFile1Path = "/etc/onedrive.conf";
	string configFile2Path = "/usr/local/etc/onedrive.conf";
	string configFile3Path = configDirName ~ "/config";
	string refreshTokenFilePath = configDirName ~ "/refresh_token";
	string statusTokenFilePath = configDirName ~ "/status_token";
	string databaseFilePath = configDirName ~ "/items.db";

	if (!exists(configDirName)) mkdir(configDirName);

	if (resync) {
		if (verbose) writeln("Deleting the saved status ...");
		if (exists(databaseFilePath)) remove(databaseFilePath);
		if (exists(statusTokenFilePath)) remove(statusTokenFilePath);
	}

	if (verbose) writeln("Loading config ...");
	auto cfg = config.Config(configFile1Path, configFile2Path, configFile3Path);

	if (verbose) writeln("Initializing the OneDrive API ...");
	bool online = testNetwork();
	if (!online && !monitor) {
		writeln("No network connection");
		return;
	}
	auto onedrive = new OneDriveApi(cfg, verbose);
	onedrive.onRefreshToken = (string refreshToken) {
		std.file.write(refreshTokenFilePath, refreshToken);
	};
	try {
		string refreshToken = readText(refreshTokenFilePath);
		onedrive.setRefreshToken(refreshToken);
	} catch (FileException e) {
		onedrive.authorize();
	}

	if (verbose) writeln("Opening the item database ...");
	auto itemdb = new ItemDatabase(databaseFilePath);

	string syncDir = expandTilde(cfg.get("sync_dir"));
	if (verbose) writeln("All operations will be performed in: ", syncDir);
        createSyncDir(syncDir);
	chdir(syncDir);

	if (verbose) writeln("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, onedrive, itemdb, configDirName, verbose);
	sync.onStatusToken = (string statusToken) {
		std.file.write(statusTokenFilePath, statusToken);
	};
	string statusToken;
	try {
		statusToken = readText(statusTokenFilePath);
	} catch (FileException e) {
		// swallow exception
	}
	sync.init(statusToken);
	if (online) performSync(sync);

	if (monitor) {
		if (verbose) writeln("Initializing monitor ...");
		Monitor m;
		m.onDirCreated = delegate(string path) {
			if (verbose) writeln("[M] Directory created: ", path);
			try {
				sync.scanForDifferences(path);
			} catch(SyncException e) {
				writeln(e.msg);
			}
		};
		m.onFileChanged = delegate(string path) {
			if (verbose) writeln("[M] File changed: ", path);
			try {
				sync.scanForDifferences(path);
			} catch(SyncException e) {
				writeln(e.msg);
			}
		};
		m.onDelete = delegate(string path) {
			if (verbose) writeln("[M] Item deleted: ", path);
			try {
				sync.deleteByPath(path);
			} catch(SyncException e) {
				writeln(e.msg);
			}
		};
		m.onMove = delegate(string from, string to) {
			if (verbose) writeln("[M] Item moved: ", from, " -> ", to);
			try {
				sync.uploadMoveItem(from, to);
			} catch(SyncException e) {
				writeln(e.msg);
			}
		};
		m.init(cfg, verbose);
		// monitor loop
		immutable auto checkInterval = dur!"seconds"(45);
		auto lastCheckTime = MonoTime.currTime();
		while (true) {
			m.update(online);
			auto currTime = MonoTime.currTime();
			if (currTime - lastCheckTime > checkInterval) {
				lastCheckTime = currTime;
				online = testNetwork();
				if (online) {
					performSync(sync);
					// discard all events that may have been generated by the sync
					m.update(false);
				}
				GC.collect();
			} else {
				Thread.sleep(dur!"msecs"(100));
			}
		}
	}
}

// try to synchronize the folder three times
void performSync(SyncEngine sync)
{
	int count;
	do {
		try {
			sync.applyDifferences();
			sync.scanForDifferences(".");
			count = -1;
		} catch (SyncException e) {
			if (++count == 3) throw e;
			else writeln(e.msg);
		}
	} while (count != -1);
}

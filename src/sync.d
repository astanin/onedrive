import std.exception: ErrnoException;
import std.algorithm, std.datetime, std.file, std.json, std.path, std.regex;
import std.stdio, std.string;
import std.array;
import config, itemdb, onedrive, upload, util;

private string uploadStateFileName = "resume_upload";
// threshold after which files will be uploaded using an upload session
private long thresholdFileSize = 10 * 2^^20; // 10 Mib

private bool isItemFolder(const ref JSONValue item)
{
	return (("folder" in item.object) !is null);
}

private bool isItemFile(const ref JSONValue item)
{
	return (("file" in item.object) !is null);
}

private bool isItemDeleted(const ref JSONValue item)
{
	return (("deleted" in item.object) !is null);
}

private bool testCrc32(string path, const(char)[] crc32)
{
	if (crc32) {
		string localCrc32 = computeCrc32(path);
		if (crc32 == localCrc32) return true;
	}
	return false;
}

class SyncException: Exception
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @nogc @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

final class SyncEngine
{
	private Config cfg;
	private OneDriveApi onedrive;
	private ItemDatabase itemdb;
	private bool verbose;
	private Regex!char skipDir, skipFile;
	private UploadSession session;
	// token representing the last status correctly synced
	private string statusToken;
	// list of items to skip while applying the changes
	private string[] skippedItems;
	// list of items to delete after the changes has been downloaded
	private string[] pathsToDelete;
        // id of the root item
        private string rootId;

	void delegate(string) onStatusToken;

	this(Config cfg, OneDriveApi onedrive, ItemDatabase itemdb, string configDirName, bool verbose)
	{
		assert(onedrive && itemdb);
		this.cfg = cfg;
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		//this.configDirName = configDirName;
		this.verbose = verbose;
		skipDir = wild2regex(cfg.get("skip_dir"));
		skipFile = wild2regex(cfg.get("skip_file"));
		session = UploadSession(onedrive, configDirName ~ "/" ~ uploadStateFileName, verbose);
	}

	void init(string statusToken = null)
	{
		this.statusToken = statusToken;
		// check if there is an interrupted upload session
		if (session.restore()) {
			writeln("Continuing the upload session ...");
			auto item = session.upload();
			saveItem(item);
		}
	}

	void applyDifferences()
	{
		if (verbose) writeln("Applying differences ...");
		try {
                        applyDifferencesOwned();
                        applyDifferencesRemote();
		} catch (ErrnoException e) {
			throw new SyncException(e.msg, e);
		} catch (FileException e) {
			throw new SyncException(e.msg, e);
		} catch (OneDriveException e) {
			throw new SyncException(e.msg, e);
		}
		// delete items in pathsToDelete
		if (pathsToDelete.length > 0) deleteItems();
		// empty the skipped items
		skippedItems.length = 0;
		assumeSafeAppend(skippedItems);
	}

        // top-level items owned by the user
        private void applyDifferencesOwned() {
                applyDifferencesWhileHasMore(sTok => onedrive.viewChangesByPath("/", sTok));
        }

        // remote shared folders which user has added to his/her drive
        // https://dev.onedrive.com/misc/working-with-links.htm
        private void applyDifferencesRemote() {
                JSONValue changes;
                auto sharedFolders = onedrive.getSharedFolders(statusToken);
                if (verbose) writeln("sharedFolders = ", sharedFolders);
                string[] topLevelSharedIds;
                foreach (d; sharedFolders["value"].array) {
                    topLevelSharedIds ~= d["id"].str;
                }
                if (verbose) writeln("topLevelSharedIds = ", topLevelSharedIds);
                foreach (d; sharedFolders["value"].array) {
                        string remoteId = d["remoteItem"]["id"].str;
                        bool isASharedFolder = !find(topLevelSharedIds, remoteId).empty();
                        applyDifferencesWhileHasMore(sTok => onedrive.viewChangesById(remoteId, sTok),
                                                     isASharedFolder);
                }
        }

        private void applyDifferencesWhileHasMore(
                        JSONValue delegate(const string statusToken) getChanges,
                        bool isASharedFolder=false
                        ) {
                JSONValue changes;
                do {
                        changes = getChanges(statusToken);
                        foreach (item; changes["value"].array) {
                                applyDifference(item, isASharedFolder);
                        }
                        statusToken = changes["@changes.token"].str;
                        onStatusToken(statusToken);
                } while (changes["@changes.hasMoreChanges"].type == JSON_TYPE.TRUE);
        }

	private void applyDifference(JSONValue item, bool isASharedFolder=false)
	{
		string id = item["id"].str;
		string name = item["name"].str;
		string eTag = item["eTag"].str;
		string parentId = item["parentReference"]["id"].str;

                // HACK: recognize the root directory
                if (name == "root" && parentId[$ - 1] == '0' && parentId[$ - 2] == '!') {
                        parentId = null;
                        rootId = id;
                }

                // TODO: use local root's ID for top-level shared remote folders
                if (isASharedFolder) {
                        // FIXME: don't do it for nested folders!!!
                        parentId = rootId;
                }

		if (verbose) writeln(id, " ", name, " parentId=", parentId);

		// skip unwanted items early
		if (skippedItems.find(parentId).length != 0) {
			skippedItems ~= id;
                        if (verbose) writeln("Skipping the item.");
			return;
		}

		// rename the local item if it is unsynced and there is a new version of it
		Item oldItem;
		string oldPath;
		bool cached = itemdb.selectById(id, oldItem);
		if (cached && eTag != oldItem.eTag) {
			oldPath = itemdb.computePath(id);
			if (!isItemSynced(oldItem, oldPath)) {
				if (verbose) writeln("The local item is unsynced, renaming");
				if (exists(oldPath)) safeRename(oldPath);
				cached = false;
			}
		}

		// compute the path of the item
		string path;
                if (isASharedFolder) {
                        path = "./" ~ name;
                } else if (parentId) {
			path = itemdb.computePath(parentId) ~ "/" ~ name;
		} else {
			path = ".";
		}

                if (verbose) writeln("path = ", path);

		ItemType type;
		if (isItemDeleted(item)) {
			if (verbose) writeln("The item is marked for deletion");
			if (cached) {
				itemdb.deleteById(id);
				pathsToDelete ~= oldPath;
			}
			return;
		} else if (isItemFile(item)) {
			type = ItemType.file;
			if (!path.matchFirst(skipFile).empty) {
				if (verbose) writeln("Filtered out");
				return;
			}
		} else if (isItemFolder(item)) {
			type = ItemType.dir;
			if (!path.matchFirst(skipDir).empty) {
				if (verbose) writeln("Filtered out");
				skippedItems ~= id;
				return;
			}
		} else {
			if (verbose) writeln("The item is neither a file nor a directory, skipping");
			skippedItems ~= id;
			return;
		}

		string cTag;
                try {
                        cTag = item["cTag"].str;
                } catch (JSONException e) {
                        // cTag is not returned if the Item is a folder
                        // https://dev.onedrive.com/resources/item.htm
                        cTag = "";
                }

		string mtime = item["fileSystemInfo"]["lastModifiedDateTime"].str;

		string crc32;
		if (type == ItemType.file) {
			try {
				crc32 = item["file"]["hashes"]["crc32Hash"].str;
			} catch (JSONException e) {
				if (verbose) writeln("The hash is not available");
			}
		}

		Item newItem = {
			id: id,
			name: name,
			type: type,
			eTag: eTag,
			cTag: cTag,
			mtime: SysTime.fromISOExtString(mtime),
			parentId: parentId,
			crc32: crc32
		};

		if (!cached) {
			applyNewItem(newItem, path);
		} else {
			applyChangedItem(oldItem, newItem, path);
		}

		// save the item in the db
		if (oldItem.id) {
			itemdb.update(id, name, type, eTag, cTag, mtime, parentId, crc32);
		} else {
			itemdb.insert(id, name, type, eTag, cTag, mtime, parentId, crc32);
		}
	}

	private void applyNewItem(Item item, string path)
	{
		if (exists(path)) {
			if (isItemSynced(item, path)) {
				if (verbose) writeln("The item ", path, " is already present");
				// ensure the modified time is correct
				setTimes(path, item.mtime, item.mtime);
				return;
			} else {
				if (verbose) writeln("The local item ", path, " is out of sync, renaming ...");
				safeRename(path);
			}
		}
		final switch (item.type) {
		case ItemType.file:
			writeln("Downloading: ", path);
			onedrive.downloadById(item.id, path);
			break;
		case ItemType.dir:
			writeln("Creating directory: ", path);
			mkdir(path);
			break;
		}
		setTimes(path, item.mtime, item.mtime);
	}

	private void applyChangedItem(Item oldItem, Item newItem, string newPath)
	{
		assert(oldItem.id == newItem.id);
		assert(oldItem.type == newItem.type);

		if (oldItem.eTag != newItem.eTag) {
			string oldPath = itemdb.computePath(oldItem.id);
			if (oldPath != newPath) {
				writeln("Moving: ", oldPath, " -> ", newPath);
				if (exists(newPath)) {
					if (verbose) writeln("The destination is occupied, renaming ...");
					safeRename(newPath);
				}
				rename(oldPath, newPath);
			}
			if (newItem.type == ItemType.file && oldItem.cTag != newItem.cTag) {
				writeln("Downloading: ", newPath);
				onedrive.downloadById(newItem.id, newPath);
			}
			setTimes(newPath, newItem.mtime, newItem.mtime);
		} else {
			if (verbose) writeln("The item has not changed");
		}
	}

	// returns true if the given item corresponds to the local one
	private bool isItemSynced(Item item, string path)
	{
		if (!exists(path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path);
				import core.time: Duration;
				item.mtime.fracSecs = Duration.zero; // HACK
				if (localModifiedTime == item.mtime) {
					return true;
				} else {
					if (verbose) writeln("The local item has a different modified time ", localModifiedTime, " remote is ", item.mtime);
				}
				if (testCrc32(path, item.crc32)) {
					return true;
				} else {
					if (verbose) writeln("The local item has a different hash");
				}
			} else {
				if (verbose) writeln("The local item is a directory but should be a file");
			}
			break;
		case ItemType.dir:
			if (isDir(path)) {
				return true;
			} else {
				if (verbose) writeln("The local item is a file but should be a directory");
			}
			break;
		}
		return false;
	}

	private void deleteItems()
	{
		if (verbose) writeln("Deleting files ...");
		foreach_reverse (path; pathsToDelete) {
			if (exists(path)) {
				if (isFile(path)) {
					remove(path);
					writeln("Deleted file: ", path);
				} else {
					try {
						rmdir(path);
						writeln("Deleted directory: ", path);
					} catch (FileException e) {
						// directory not empty
					}
				}
			}
		}
		pathsToDelete.length = 0;
		assumeSafeAppend(pathsToDelete);
	}

	// scan the given directory for differences
	public void scanForDifferences(string path)
	{
		try {
			if (verbose) writeln("Uploading differences ...");
			Item item;
			if (itemdb.selectByPath(path, item)) {
				uploadDifferences(item);
			}
			if (verbose) writeln("Uploading new items ...");
			uploadNewItems(path);
		} catch (ErrnoException e) {
			throw new SyncException(e.msg, e);
		} catch (FileException e) {
			throw new SyncException(e.msg, e);
		} catch (OneDriveException e) {
			throw new SyncException(e.msg, e);
		}
	}

	private void uploadDifferences(Item item)
	{
		if (verbose) writeln(item.id, " ", item.name);
		string path = itemdb.computePath(item.id);
		final switch (item.type) {
		case ItemType.dir:
			if (!path.matchFirst(skipDir).empty) {
				if (verbose) writeln("Filtered out");
				break;
			}
			uploadDirDifferences(item, path);
			break;
		case ItemType.file:
			if (!path.matchFirst(skipFile).empty) {
				if (verbose) writeln("Filtered out");
				break;
			}
			uploadFileDifferences(item, path);
			break;
		}
	}

	private void uploadDirDifferences(Item item, string path)
	{
		assert(item.type == ItemType.dir);
		if (exists(path)) {
			if (!isDir(path)) {
				if (verbose) writeln("The item was a directory but now is a file");
				uploadDeleteItem(item, path);
				uploadNewFile(path);
			} else {
				if (verbose) writeln("The directory has not changed");
				// loop trough the children
				foreach (Item child; itemdb.selectChildren(item.id)) {
					uploadDifferences(child);
				}
			}
		} else {
			if (verbose) writeln("The directory has been deleted");
			uploadDeleteItem(item, path);
		}
	}

	private void uploadFileDifferences(Item item, string path)
	{
		assert(item.type == ItemType.file);
		if (exists(path)) {
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path);
				import core.time: Duration;
				item.mtime.fracSecs = Duration.zero; // HACK
				if (localModifiedTime != item.mtime) {
					if (verbose) writeln("The file last modified time has changed");
					string id = item.id;
					string eTag = item.eTag;
					if (!testCrc32(path, item.crc32)) {
						if (verbose) writeln("The file content has changed");
						writeln("Uploading: ", path);
						JSONValue response;
						if (getSize(path) <= thresholdFileSize) {
							response = onedrive.simpleUpload(path, path, eTag);
						} else {
							response = session.upload(path, path, eTag);
						}
						saveItem(response);
						id = response["id"].str;
						/* use the cTag instead of the eTag because Onedrive changes the
						 * metadata of some type of files (ex. images) AFTER they have been
						 * uploaded */
						eTag = response["cTag"].str;
					}
					uploadLastModifiedTime(id, eTag, localModifiedTime.toUTC());
				} else {
					if (verbose) writeln("The file has not changed");
				}
			} else {
				if (verbose) writeln("The item was a file but now is a directory");
				uploadDeleteItem(item, path);
				uploadCreateDir(path);
			}
		} else {
			if (verbose) writeln("The file has been deleted");
			uploadDeleteItem(item, path);
		}
	}

	private void uploadNewItems(string path)
	{
		if (isDir(path)) {
			if (path.matchFirst(skipDir).empty) {
				Item item;
				if (!itemdb.selectByPath(path, item)) {
					uploadCreateDir(path);
				}
				auto entries = dirEntries(path, SpanMode.shallow, false);
				foreach (DirEntry entry; entries) {
					uploadNewItems(entry.name);
				}
			}
		} else {
			if (path.matchFirst(skipFile).empty) {
				Item item;
				if (!itemdb.selectByPath(path, item)) {
					uploadNewFile(path);
				}
			}
		}
	}

	private void uploadCreateDir(const(char)[] path)
	{
		writeln("Creating remote directory: ", path);
		JSONValue item = ["name": baseName(path).idup];
		item["folder"] = parseJSON("{}");
		auto res = onedrive.createByPath(path.dirName ~ "/", item);
		saveItem(res);
	}

	private void uploadNewFile(string path)
	{
		writeln("Uploading: ", path);
		JSONValue response;
		if (getSize(path) <= thresholdFileSize) {
			response = onedrive.simpleUpload(path, path);
		} else {
			response = session.upload(path, path);
		}
		saveItem(response);
		string id = response["id"].str;
		string cTag = response["cTag"].str;
		SysTime mtime = timeLastModified(path).toUTC();
		/* use the cTag instead of the eTag because Onedrive changes the
		 * metadata of some type of files (ex. images) AFTER they have been
		 * uploaded */
		uploadLastModifiedTime(id, cTag, mtime);
	}

	private void uploadDeleteItem(Item item, const(char)[] path)
	{
		writeln("Deleting remote item: ", path);
		try {
			onedrive.deleteById(item.id, item.eTag);
		} catch (OneDriveException e) {
			if (e.code == 404) writeln(e.msg);
			else throw e;
		}
		itemdb.deleteById(item.id);
	}

	private void uploadLastModifiedTime(const(char)[] id, const(char)[] eTag, SysTime mtime)
	{
		JSONValue mtimeJson = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": mtime.toISOExtString()
			])
		];
		auto res = onedrive.updateById(id, mtimeJson, eTag);
		saveItem(res);
	}

	private void saveItem(JSONValue item)
	{
		string id = item["id"].str;
		ItemType type;
		if (isItemFile(item)) {
			type = ItemType.file;
		} else if (isItemFolder(item)) {
			type = ItemType.dir;
		} else {
			assert(0);
		}
		string name = item["name"].str;
		string eTag = item["eTag"].str;
		string cTag = item["cTag"].str;
		string mtime = item["fileSystemInfo"]["lastModifiedDateTime"].str;
		string parentId = item["parentReference"]["id"].str;
		string crc32;
		if (type == ItemType.file) {
			try {
				crc32 = item["file"]["hashes"]["crc32Hash"].str;
			} catch (JSONException e) {
				// swallow exception
			}
		}
		itemdb.upsert(id, name, type, eTag, cTag, mtime, parentId, crc32);
	}

	void uploadMoveItem(string from, string to)
	{
		writeln("Moving remote item: ", from, " -> ", to);
		Item fromItem, toItem, parentItem;
		if (!itemdb.selectByPath(from, fromItem)) {
			throw new SyncException("Can't move an unsynced item");
		}
		if (itemdb.selectByPath(to, toItem)) {
			// the destination has been overridden
			uploadDeleteItem(toItem, to);
		}
		if (!itemdb.selectByPath(to.dirName, parentItem)) {
			throw new SyncException("Can't move an item to an unsynced directory");
		}
		JSONValue diff = ["name": baseName(to)];
		diff["parentReference"] = JSONValue([
			"id": parentItem.id
		]);
		auto res = onedrive.updateById(fromItem.id, diff, fromItem.eTag);
		saveItem(res);
		string id = res["id"].str;
		string eTag = res["eTag"].str;
		uploadLastModifiedTime(id, eTag, timeLastModified(to).toUTC());
	}

	void deleteByPath(const(char)[] path)
	{
		Item item;
		if (!itemdb.selectByPath(path, item)) {
			throw new SyncException("Can't delete an unsynced item");
		}
		try {
			uploadDeleteItem(item, path);
		} catch (OneDriveException e) {
			if (e.code == 404) writeln(e.msg);
			else throw e;
		}
	}
}

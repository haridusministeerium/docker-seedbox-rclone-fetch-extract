# Seedbox data fetcher & processor

Dockerised service periodically pulling and post-processing data from a remote
seedbox.

Note data is synced unidirectionally, and if already downloaded & processed
asset gets deleted on the remote, then it's also nuked locally. This is generally
the preferred method, as \*arr service (or whatever other media manager you happen
to use) should be responsible for torrent removal upon successful import anyways.

It's also important to know if an already-downloaded source file is modified at the
remote (apart from deletion), then those modifications will no longer be reflected locally.


## Rationale

This service aims to solve a common issue with the servarr projects around data import
(+ also provides extraction and merging of DVD .VOB files) described [here](https://forums.sonarr.tv/t/slow-transfer-from-remote-machine-fails-import/29013).
TL;DR of it is if \*arr is monitoring a directory and expecting say full season worth
of files, but by the time it goes to check/import only half of episodes have been
downloaded from your remote seedbox, then only those episodes present would be imported.

We solve this by using rclone to first download assets into an intermediary
directory not monitored by \*arr services, optionally process them, and then
move them atomically to a destination directory that \*arr expects them in.

servarrs' completed download handling is documented/described [here](https://wiki.servarr.com/en/sonarr/settings#completed-download-handling);
archived asset handling isn't described in much detail, but can be found [here](https://wiki.servarr.com/en/sonarr/troubleshooting#packed-torrents).


## Configuration

### Required environment variables

- `REMOTE`: your configured rclone remote;
- `SRC_DIR`: path to the source directory on your remote to pull data from;
- `DEST_FINAL`: path to the mounted directory in container to finally move pulled
   data to; note this would be the directory monitored by your \*arr services et al;

### Optional environment variables

- `DEST_INITIAL`: path to the mounted dir in container where rclone initially downloads
   data to; if not defined, then a directory is created inside `$DEST_FINAL`;
   it's recommended you define this. Also make sure it lies on the same
   filesystem as `DEST_FINAL`, so `mv` command is atomic;
- `DEPTH`: sets the depth level at which files are searched/synced at; defaults to 1;
   see below for closer depth explanation;
- `RM_EMPTY_PARENT_DIRS`: set to any non-empty value to delete empty parent dirs;
   used only if DEPTH > 1;
- `CRON_PATTERN`: cron pattern to be used to execute the syncing script;
   eg `*/10 * * * *` to execute every 10 minutes; defaults to every 5 min;
- `SKIP_EXTRACT`: set to any non-empty value to skip archived file extraction;
- `SKIP_MERGE_VOB`: set to any non-empty value to skip merging DVD .VOB
   files into a single .mkv file;
- `SKIP_ARCHIVE_RM`: set to any non-empty value to skip removal of archives 
   that were successfully extracted;
- `SKIP_VOB_RM`: set to any non-empty value to skip removal of merged .VOB DVD files;
- `SKIP_LOCAL_RM`: set to any non-empty value to skip removing assets in 
   `$DEST_FINAL` whose counterpart has been removed on the remote;
- `RCLONE_FLAGS`: semicolon-separated options to use with all `rclone` commands;
   note this _overwrites_ the default rclone flags altogether, so make sure you
   know what you're doing;
- `RCLONE_OPTS`: semicolon-separated _additional_ options to be passed to all
  `rclone` commands; useful eg if you want to override the `--bwlimit` option
  (which defaults to 20M) or increase logging verbosity;
- `WATCHDIR_DEST`: path to the watchdir on your remote;
- `WATCHDIR_SRC`: path to the watchdir mounted in container;
- `PGID`: group id; defaults to `100` (users)
- `PUID`: user id; defaults to `99` (nobody)

### Required mountpoints & files

- `DEST_FINAL` (& `DEST_INITIAL` if env var is defined) directories need to be backed
  by mounted directory (or directories if they reside on different mountpoints)
   - same for `WATCHDIR_SRC`, if defined
- mount point to configuration root dir at `/config` also needs to be provided;
- valid rclone config file `rclone.conf` needs to be present in `/config` mount
  dir; this conf needs to define the remote referenced by `REMOTE` env var;


## Example docker command:

    docker run -d \
        --name seedbox-fetcher \
        -e REMOTE=seedbox \
        -e SRC_DIR=files/complete \
        -e DEST_INITIAL=/data/rclone-tmp \
        -e DEST_FINAL=/data/complete \
        -e PUID=1000 \
        -v /host/dir/downloads/torrents:/data \
        -v $HOME/.config/seedbox-fetcher:/config \
        layr/seedbox-rclone-fetch-extract


## On syncing logic and `DEPTH` env var

`DEPTH` env var selects the depth level in relation to `SRC_DIR` in which files&dirs 
are downloaded/removed from. If any of replicated/downloaded nodes get deleted on
the remote server, they will also be deleted from `DEST_FINAL`.

If additional file or dir gets written into an already-downloaded directory, then this
addition wouldn't be downloaded, as downloaded nodes are considered finalized, meaning
no _changes_ to them are replicated, only their removal. This applies also for child
removals -- ie if a child file in an already-replicated directory is removed on
remote, then this removal won't be reflected in our local copy.

In other words, download/remove happens _only_ if addition/removal is detected at given `DEPTH`. 

Say your `SRC_DIR` on the remote server looks like:

```bash
$ tree SRC_DIR
SRC_DIR/
├── dir1
│   ├── dir12
│   │   └── file121
│   └── file1
├── dir2
│   └── file2
└── file3
```

### DEPTH=1 (default)

If `DEPTH=1`, then `dir1/`, `dir2/` & `file3` would be replicated
to `DEST_FINAL`. If any of them gets deleted on the remote server, it will also be
deleted from `DEST_FINAL`. If additional file or dir gets written into or removed from
`dir1/` or `dir2/`, then this addition or removal wouldn't be downloaded.

Replicated copy would look like an exact copy of the remote:

```bash
$ tree DEST_FINAL
DEST_FINAL/
├── dir1
│   ├── dir12
│   │   └── file121
│   └── file1
├── dir2
│   └── file2
└── file3
```

Now let's say `file3` and `file2` were removed on remote, and `newfile` was
written into `dir1/`. After sync our local copy would look like:

```bash
$ tree DEST_FINAL
DEST_FINAL/
├── dir1
│   ├── dir12
│   │   └── file121
│   └── file1
└── dir2
    └── file2
```

Note `file3` removal was reflected in our local copy as expected. But `newfile`
addition nor `file2` removal weren't. This is because their parent directories
(`dir1/` and `dir2/` respectively) had already been replicated, and thus are considered
finalized.

### DEPTH=2

If `DEPTH=2`, then `dir12/`, `file1` & `file2` would be replicated to
`DEST_FINAL` while _preserving the original directory structure_ - meaning parent
directories from the `SRC_DIR` root will be created also on DEST_FINAL. If any of them gets
deleted on the remote server, it will also be deleted from `DEST_FINAL`. If additional
file or dir gets written into or removed from `dir12/`, then this addition or removal
wouldn't be downloaded.
Note `file3` is completely ignored by the service, as it sits at `depth=1` level.

Replicated copy would look like:

```bash
$ tree DEST_FINAL
DEST_FINAL/
├── dir1
│   ├── dir12
│   │   └── file121
│   └── file1
└── dir2
    └── file2
```

Now let's say `file121` and `file2` were removed on remote, and `newfile` was
written into `dir1/dir12/`. After sync our local copy would look like:

```bash
$ tree DEST_FINAL
DEST_FINAL/
├── dir1
│   ├── dir12
│   │   └── file121
│   └── file1
└── dir2
```

Note `file2` removal was reflected in our local copy as expected. But `newfile`
addition nor `file121` removal weren't. This is because their parent directory
`dir1/dir12/` had already been replicated, and thus is considered finalized.

If you want empty parent directories (`dir2/` in above example) to be cleaned up,
then set `RM_EMPTY_PARENT_DIRS` env var to a non-empty value.


## Debugging

Sometimes it's useful to debug rclone/config issues directly from the
container shell. If you're doing so, make sure to run all commands as `abc`
user, otherwise you may accidentally mess up some files' ownership. e.g.:

```bash
su abc -s /bin/sh -c 'rclone lsf -vvv --max-depth 1 --config /config/rclone.conf  your-remote:'
su abc -s /bin/sh -c /sync.sh
```

## See also

- rclone mount (+ optionally mergerFS) systemd services: [see this discord](https://discord.com/channels/427913240316477443/427914848702038026/1460040373681389672)


## TODO

- notification systems
- set up logrotate
- healthchecks
- do we need `--tpslimit` and/or `--checkers` option?
- confirm optimal `--transfers` opt;
- confirm `common.sh/has_enough_space()` works as intended
- skip downloads of assets that wouldn't fit on local filesystem; eg similar to
  has_enough_space(), but for downloading, not extracting;
- find a better way for compiling `copy` command - atm we're escaping filenames for
  the `--filter +` flags; `--files-from` might be an option, but unsure whether
  it'd pull the whole dir if only dir -- as opposed to its contents -- is listed;


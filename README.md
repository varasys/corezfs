# corezfs

## ZFS on CoreOS
This is a script to compile and install ZFS on CoreOS. It is meant to be installed on a fresh clean CoreOS instance.

This script was written on CoreOS stable (1353.7.0), but in theory, will work on any version / channel (ie. stable, beta, alpha).

[CoreOS](https://coreos.com/os/docs/latest) is a minimal linux distribution designed for running containers but does not currently come with support for ZFS.

[ZFS](http://zfsonlinux.org) is a very performant filesystem that supports snapshots, clones, native nfs and cifs support, and incremental backups.

The motivation for this script is to be able to mount a ZFS filesystem to use as persistant storage on a Kubernetes controller node running CoreOS.

This script allows the ZFS filesystem to be used with CoreOS by compiling ZFS from source. Note that the script does not change the filesystem that CoreOS is mounted on, it allows additional block devices to use the ZFS file system.

The script downloads the CoreOS build environment and then starts a temporary container running the build-environment to download and build ZFS. The container bind mounts /lib/modules and /usr/local and installs ZFS onto those volumes so ZFS is available to CoreOS after compilation is completed and the temporary container is deleted.

Because the /lib/modules (where the ZFS kernal drivers need to be installed) and /usr/local (where the ZFS user space utilities are installed) are read-only on CoreOS, a read-write filesystem overlay is provided for both these directories.

The standard systemd unit files included in the ZFS source code are installed.

At the completion of the installation the zfs module should be loaded and user space tools in the PATH, and zfs mounts should persist across reboots.

The following directories are used for the overlays where the zfs files are installed (which means that whatever is in these folders is overlayed or merged into the root CoreOS filesystem):

1. /opt/modules  
2. /opt/usr/local

## References
This script is adapted from the instructions from:

1. https://coreos.com/os/docs/latest/kernel-modules.html  
2. https://github.com/zfsonlinux/zfs/wiki/Building-ZFS

## Installation
To install ZFS clone this repository and then run the install-zfs.sh script as root (and optionally delete the repository after installation).
```bash
git clone https://github.com/varasys/corezfs.git
cd corezfs
sudo ./install-zfs.sh
cd ../
sudo rm -rf corezfs # delete this folder since it is unneeded and 3GB+ after compiling ZFS
```

## Uninstallation
There is no uninstaller. CoreOS instances are generally sacrifical and get thrown away and re-built as needed.

## Issues

1. This should really be baked into CoreOS (so hopefully this script is just a temporary stop-gap solution until the CoreOS developers include ZFS support natively)  
2. It is uncertain whether the kernel drivers will continue to work after a CoreOS update, or whether the script needs to be re-run to re-build them (one reason it should be baked into CoreOS)  

## Using ZFS
There is plenty of other documentation about using ZFS on the internet.

A good starting point is https://pthree.org/2012/04/17/install-zfs-on-debian-gnulinux/.

Here are some quick start instructions. Note that the `zfs` and `zpool` commands must be run as root (shown here with `sudo` command prefix).

### Create a pool from a block device (ie. /dev/disk/by-id/scsi0)
A "pool" allows one or more devices to be combined into a single storage pool. The man pages discuss how to create raid arrays, etc. when using more than one block device. The following will create a pool called "zfs-pool" with a single device.

`sudo zpool create zfs-pool /dev/disk/by-id/scsi0`

The following command will show a list of pools.

`sudo zpool list`

### Create a filesystem
Filesystems are created within the pool. This is what allows different functionality for different parts of your overall filesystem. For instance, in the same pool some filesystems can be read-only, or some can be case-insensative.

The following will create a filesystem called "uncompressed" and a second filesystem called "compressed" which is compressed with the lz4 algorithm, and a third filesystem called "nested" which is an uncompressed filesystem within the compressed filesystem (to demonstrate nesting filesystems with different options).

Note that the ZFS documentation recommends to always use lz4 compression (apparently the benefits of reading/writing less to disk override the cost of computing the compression), but that also compression is not used by default, and must be turned on with the `-o compression=lz4` option as shown below.

```bash
sudo zfs create zfs-pool/uncompressed
sudo zfs create -o compression=lz4 zfs-pool/compressed
sudo zfs create -o compression=none zfs-pool/compressed/nested
```

The `-o` command line argument is used to set the options for each filesystem. A list of all available options can be seen by running `sudo zfs get`. There is also a `sudo zfs set` command which can be used to set options. Refer to the manpage for all available options.

### Mounting filesystems
By default when a new pool is created a mountpoint (ie. directory) for the pool is created in the os root filesystem, and the zfs filesystems are automatically mounted at that mountpoint.

After creating the filesystems in the example above, the following directories will exist:

- /zfs-pool/uncompressed  
- /zfs-pool/compressed  
- /zfs-pool/compressed/nested

There are a couple ways to change the mount behavior (such as not automatically mounting at boot, or changing the mount location) which are clearly documented in the ZFS man pages.

### Snapshots and Clones
One of the great features of ZFS is the ability to take snapshots and make clones.

A snapshot is a read-only exact copy of a filesystem from a specific point in time (when the snapshot was taken).

A clone is an exact copy of a snapshot, but unlike a snapshot is both read/write.

A simplistic way to think about it is that a snapshot is a backup, and if you want to restore a backup you "clone" it.

### Send and Receive
Another great feature of ZFS is the send and receive commands which allow incremental changes between two different snapshots be dumped/restored to/from a file, or more likely transferred over a network in an incredibly effecient way.

### Why make filesystems [instead of just nesting directories]?
When a filesystem is mounted, it behaves like a normal filesystem and can contain files and directories.

But note also that ZFS filesystems can be nested.

So in some installations, it is reasonable that there is only one ZFS filesystem, but in this case, everything will either have to be compressed or uncompressed (same with any other options), and it is only possible to take snapshots of the entire complete filesystem.

Making multiple filesystems allows fine grained control over different options for different things, so for example, if you had a server which included directories for both persistant data and also ephemeral cache (ie. requires space, but can be rebuilt if lost and doesn't need to be backed-up), you would probably create the following two filesystems:

```bash
sudo zfs create -o compression=lz4 zfs-pool/data
sudo zfs create -o compression=lz4 zfs-pool/cache
```

This will allow you to take snapshots of the data filesystem (and not include the cache filesystem).

If the cache folder were inside the data folder then I think the best solution is something like the following.

```bash
sudo zfs create -o compression=lz4 zfs-pool/data
sudo zfs create -o compression=lz4 -o mountpoint=/zfs-pool/data/cache zfs-pool/cache
```

Snapshots don't take up alot of space (almost nothing), but there are also lots of various options that you may want to set which would cause you to set up a ZFS filesystem for it. It is also pretty easy to end up with several thousands of snapshots (especially when testing a backup rotation system) and the more there are the slower the ZFS user space tools work (ie. the `zfs list -t snapshot` command will take longer to list all of the snapshots).

Also, alot of the options are inherited and actions such as snapshooting can work recursively (ie. include all sub-filesystems), so when there are special cases like the cache case above, it usually works out better to not actually nest the ZFS filesystems (instead change the mountpoint to make them nested in the os filesystem).

### Next Steps
Like most things, ZFS is fairly straightforward once you understand what the designers had in mind, but the devil is in the details, and it is recommended to read the complete documentation.

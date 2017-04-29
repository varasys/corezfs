# corezfs

## ZFS on CoreOS
This is a script to compile and install ZFS on CoreOS. It is meant to be installed on a fresh clean CoreOS instance. Although it can be run manually, it is envisioned that it is typically used as part of an automated provisioning process.

[CoreOS](https://coreos.com/os/docs/latest) is a linux distribution designed specifically for running containers but does not currently come with support for ZFS.

[ZFS](http://zfsonlinux.org) is a very performant filesystem that supports error checking, snapshots, clones, native nfs and cifs support, and incremental backups.

The motivation for this script is to be able to mount a ZFS filesystem to use as persistent storage on a Kubernetes controller node running CoreOS.

This script was written on CoreOS stable (1353.7.0), but in theory, will work on any version / channel (ie. stable, beta, alpha). It installs the latest release of ZFS on Linux which is based on OpenZFS and consists of a repository [zfs](https://github.com/zfsonlinux/zfs) which includes the upstream OpenZFS implementation and a repository [spl](https://github.com/zfsonlinux/spl) which is a shim to run OpenZFS on Linux.

This script compiles ZFS from source and creates some overlays to put the kernel modules and user space tools. Note that the script does not effect the filesystem that CoreOS is mounted on, it allows additional block devices to be mounted using the ZFS file system.

The script downloads the CoreOS build environment and then starts a temporary container running the build-environment to download and build ZFS. The container bind mounts /lib/modules (where the ZFS kernel drivers are installed) and /usr/local (where the ZFS user space utilities are installed) and installs ZFS onto those volumes so ZFS is available to CoreOS after the build completes and the temporary container is deleted.

Because the /lib/modules and /usr/local directories are read-only on CoreOS, a read-write filesystem overlay is provided for both these directories.

The standard systemd unit files included in the ZFS source code are installed, and two additional systemd unit files are provided to mount the overlays as needed.

At the completion of the installation the zfs module should be loaded and user space tools in the PATH, and zfs mounts should persist across reboots (if there is a zpool.cache file; see issues section).

The following directories are used for the overlays where the zfs files are installed (which means that whatever is in these folders is overlaid or merged into the root CoreOS filesystem):

1. /opt/modules  
2. /opt/usr/local

Hopefully this script will allow more people to experiment with ZFS on CoreOS to gain enough support that the CoreOS developers will bake it into CoreOS (note that this implementation does not gracefully handle updates to the CoreOS OS).

## References
This script is adapted from the instructions from:

1. https://coreos.com/os/docs/latest/kernel-modules.html  
2. https://github.com/zfsonlinux/zfs/wiki/Building-ZFS

## Installation
To install ZFS clone this repository and run the install-zfs.sh script as root (it is envisioned this would normally be run as part of an automatic provisioning process).

To install the latest released version:

```bash
mkdir corezfs
curl -L https://api.github.com/repos/varasys/corezfs/tarball | tar -zxv -C corezfs --strip-components=1
sudo ./corezfs/install-zfs.sh
```

To install a specific version (in this case v0.1.0):

```bash
mkdir corezfs
curl -L https://github.com/varasys/corezfs/archive/v0.1.0.tar.gz | tar -zxv -C corezfs --strip-components=1
sudo ./corezfs/install-zfs.sh
```

The installation requires about 350 MB of downloaded files, and during installation, the corezfs folder will grow to around 3GB, so it must be run from a location with this much free space.

If the installation is successful, the script will clean-up after itself by deleting the "corezfs" directory, but the original contents of the corezfs folder (including this readme) will be copied to the /usr/local/share/corezfs folder for future reference.

## Uninstallation
There is no uninstaller. CoreOS instances are generally sacrificial and get thrown away and re-built as needed.

## Issues

1. This should really be baked into CoreOS (so hopefully this script is just a temporary stop-gap solution until the CoreOS developers include ZFS support natively)  
2. It is uncertain whether the kernel drivers will continue to work after a CoreOS update, or whether the script needs to be re-run to re-build them (further support for why it should be baked into CoreOS)  
3. This script would be much better and robust as a Makefile, but `make` is not included in CoreOS. I understand that the CoreOS developers only included a minimum of tools in CoreOS, but I would like to gain support for including `make` so that things like this could be implemented as Makefiles (especially for making it easier to try out things like this before they are officially included in CoreOS).  
4. This script tries to faithfully duplicate the stock ZFS installation with no customization from the upstream ZoL source. The upstream ZoL maintainers created two different systemd unit files to import zpools at boot. One method scans the /dev/disk/by-id/ directory for available pools and tries to import them. The second method imports zpools from the /usr/local/etc/zfs/zpool.cache file. By default the systemd unit file for the first method is disabled, and the systemd unit file for the second method is enabled. There are a couple issues with this:  

    - The upstream zfs-import-cache.service unit file includes a `ConditionPathExists=/usr/local/etc/zfs/zpool.cache` clause so it won't run unless that file exists, and further, when it does run it has a hard-coded dependency on that file
    - That file isn't created as part of the default ZoL installation
    - That file isn't created when a new pool is created (ie. `zpool create pool /dev/disk/by-id/scsi0`)
    - There is actually meant to be one file per ZPool, so even if that file existed for one zpool, any additional zpools wouldn't be loaded since the systemd unit file only loads the pool defined in the cache file
    
    Ultimately this means that *By default, ZPools aren't imported  on reboot*. Use one of the work-arounds below to import ZPools in reboot:
    
     1. One workaround is to disable importing by cache file and instead scan the /dev/disk/by-id/ directory on each boot:
         
         ```bash
         sudo systemctl disable --now zfs-import-cache.service
         sudo systemctl enable --now zfs-import-scan.service
         ```
           
     2. A second workaround is to manually create the cache file after creating the ZPool (but this only works if there is only one ZPool since the zfs-import-cache-service systemd unit file is still hard coded to just the single cache file):
         
         ```bash
         sudo zpool create pool-01 /dev/disk/by-id/scsi0
         sudo zpool set cachefile=/usr/local/etc/zfs/zpool.cache pool-01 
         ```
     
     3. If you need more than one ZPool create a cache for each (see the work-around above) for each, and then edit the /etc/systemd/system/zfs-import-cache.service file to load each (including commenting out the two lines shown below).
         
         ```bash
         [Unit]
         ...
         #ConditionPathExists=/usr/local/etc/zfs/zpool.cache
         
         [Service]
         ...
         #ExecStart=/usr/local/sbin/zpool import -c /usr/local/etc/zfs/zpool.cache -aN
         ExecStart=/usr/local/sbin/zpool import -c /usr/local/etc/zfs/pool-01.cache -aN; \
                   /usr/local/sbin/zpool import -c /usr/local/etc/zfs/pool-02.cache -aN; \
                   /usr/local/sbin/zpool import -c /usr/local/etc/zfs/pool-03.cache -aN
         ```

## Using ZFS
There is plenty of other documentation about using ZFS on the internet.

A good starting point is https://pthree.org/2012/04/17/install-zfs-on-debian-gnulinux/.

Here are some quick start instructions. Note that the `zfs` and `zpool` commands must be run as root (shown here with `sudo` command prefix).

One of the keys to understating ZFS is understanding the following terms:

- **ZPool** is an "aggregation" of one or more devices which act as a single storage pool (optionally implementing some form of RAID)  
- **OS Filesystem** is the filesystem on the operating system (starting at /)  
- **ZFS Filesystems** are filesystems allocated in a ZPool

The reason for emphasizing that the OS Filesystem and ZFS Filesystem are different is because by default ZFS Filesystems are mounted in the OS Filesystem using the mount-point which is the ZFS Filesystem name with a leading slash (/). So by default a ZFS filesystem called "zfs-pool/my-dir" will be mounted at "/zfs-pool/my-dir". This default behavior along with ZFS's use of the term "Filesystem" can make it confusing to describe how ZFS works.

In reality, every ZFS Filesystem has an option called "mount-point" which by default is set to the name of the ZFS Filesystem with a leading slash, but could be set to anything (or nothing in which case the ZFS Filesystem can't be mounted on the OS Filesystem).

### Create a ZPool from a block device
A ZPool allows one or more devices to be combined into a single storage pool. The man pages discuss how to create raid arrays, etc. when using more than one block device. The following will create a pool called "zfs-pool" with a single device (replace "scsi0" with the actual name of the device in the /dev/disk/by-id/ directory).

`sudo zpool create zfs-pool /dev/disk/by-id/scsi0`

The following command will show a list of pools.

`sudo zpool list`

### Create a ZFS Filesystem
ZFS Filesystems are created within a ZPool in order to allocate storage space with associated options (ie. read-only or case-insensitive or compressed). ZFS Filesystems can be nested (for instance, a read/write ZFS Filesystem can be nested within a read-only ZFS Filesystem).

The following will create a ZFS Filesystem called "uncompressed", a second ZFS Filesystem called "compressed" which is compressed with the lz4 algorithm, and a third ZFS Filesystem nested under the second called "nested" which is read-only (note that even though the "nested" filesystem does not explicitly set the compression flag, it will be inherited from the "compressed" filesystem).

```bash
sudo zfs create zfs-pool/uncompressed
sudo zfs create -o compression=lz4 zfs-pool/compressed
sudo zfs create -o readonly=true zfs-pool/compressed/nested
```

The following command will show a list of ZFS filesystems.

`sudo zfs list`

Note that the ZFS documentation recommends to always use lz4 compression (apparently the benefits of reading/writing less to disk override the cost of computing the compression), but that also compression is not used by default, and must be turned on with the `-o compression=lz4` option as shown above.

The `-o` command line argument is used to set the options for each filesystem. There are many options, and a full list of all available options can be seen by running `sudo zfs get`. There is also a `sudo zfs set` command which can be used to set options. Refer to the manpage for all available options.

### Mounting ZFS Filesystems on the OS Filesystem
By default when a new pool is created a mount-point (ie. directory) for the pool is created in the os root filesystem, and the zfs filesystems are automatically mounted at that mount-point.

After creating the filesystems in the example above, the following directories will exist:

- /zfs-pool/uncompressed  
- /zfs-pool/compressed  
- /zfs-pool/compressed/nested  

### Snapshots and Clones
One of the great features of ZFS is the ability to take snapshots and make clones.

A snapshot is a read-only exact copy of a filesystem from a specific point in time (when the snapshot was taken).

A clone is an exact copy of a snapshot, but unlike a snapshot is both read/write.

A simplistic way to think about it is that a snapshot is a backup, and if you want to restore a backup you "clone" it back into existence.

### NFS and CIFS
ZFS has built-in support for serving filesystems over nfs and cifs (by setting different options for the filesystem). Refer to the zfs man page for details.

### Send and Receive
Another great feature of ZFS is the send and receive commands which allow incremental changes between two different snapshots be dumped/restored to/from a file, or more likely transferred over a network in an incredibly efficient way.

### Why make filesystems [instead of just nesting directories]?
When a filesystem is mounted, it behaves like a normal filesystem and can contain files and directories.

But note also that ZFS filesystems can be nested.

So in some installations, it is reasonable that there is only one ZFS filesystem, but in this case, everything will either have to be compressed or uncompressed (same with any other options), and it is only possible to take snapshots of the entire complete filesystem.

Making multiple filesystems allows fine grained control over different options for different things, so for example, if you had a server which included directories for both persistent data and also ephemeral cache (ie. requires space, but can be rebuilt if lost and doesn't need to be backed-up), you would probably create the following two filesystems:

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

This keeps the cache out of the data hierarchy in the ZPool, but mounts it in the correct location under the data hierarchy in the OS Filesystem.

Snapshots don't take up a lot of space (almost nothing), but there are also lots of various options that you may want to set which would cause you to set up a ZFS filesystem for it. It is also pretty easy to end up with several thousands of snapshots (especially when testing a backup rotation system) and the more there are the slower the ZFS user space tools work (ie. the `zfs list -t snapshot` command will take longer to list all of the snapshots).

Also, alot of the options are inherited and actions such as snapshotting can work recursively (ie. include all sub-filesystems), so when there are special cases like the cache case above, it usually works out better to not actually nest the ZFS filesystems (instead change the mount-point to make them nested in the os filesystem).

### Next Steps
Like most things, ZFS is fairly straightforward once you understand what the designers had in mind, but the devil is in the details, and it is recommended to read the complete documentation.

This introduction is not exhaustive, but hopefully it provides enough of a high level overview that the more detailed information at https://pthree.org/2012/04/17/install-zfs-on-debian-gnulinux/ is easier understood.

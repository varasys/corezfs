# corezfs

## ZFS on CoreOS
This is a script to compile and install ZFS on CoreOS. It is meant to be installed on a fresh clean CoreOS instance. Although it can be run manually, it is envisioned that it is typically used as part of an automated provisioning process.

## Installation
To build and install ZFS on Linux on CoreOS download the script to the target machine and run it with the install command:
```bash
sudo ./corezfs install
```

After the script completes zfs kernel modules should be loaded, and user tools installed.

The script will create an archive file which can be used to install zfs on other CoreOS instances without having to rebuild it on each instance. The archive filename will indicate which CoreOS version the archive file is targeted for.

To install zfs on another instance using the archive file, copy the corezfs script and archive file to the target machine and run:
```bash
sudo ./corezfs install
```

The script will automatically look for an archive file in the current directory with the target CoreOS version in the filename and install it if found, otherwise it will build a new archive file for the target system and install it.


## Introduction
[CoreOS](https://coreos.com/os/docs/latest) is a light weight linux distribution designed specifically for running containers but does not currently come with support for ZFS. The idea is the only thing CoreOS does is coordinate containers and all work is performed inside containers. CoreOS is also very focused on reliability, clustering and federating with support for things like kubernetes baked in.

[ZFS](http://zfsonlinux.org) is a very performant filesystem that supports error checking, snapshots, clones, native nfs and cifs support, and incremental backups. The ZFS on Linux project is a port of OpenZFS for Linux.

Because the design philosophy of CoreOS is to be a minimal "container orchestration" tool, it is locked down very tightly and most of the file system is read only, which presents a problem for software which requires kernel modules (both because containers need special permissions to communicate with the kernel, and because the CoreOS kernel modules folder is read only).

This script downloads a CoreOS development environment and runs it in a container to build zfs and create the archive file. The archive file is a tar file containing an /etc/ directory containing zfs configuration information, and an /opt/corezfs/usr directory which is overlaid over the /usr filesystem and contains the kernel modules and binaries. A systemd unit file called zfs-overlay.service (included in the /etc/ directory of the archive file) mounts the overlay at startup.

This script was written on CoreOS stable (1465.7.0), but in theory, will work on any version / channel (ie. stable, beta, alpha). It installs the latest release of ZFS on Linux which is based on OpenZFS and consists of a repository [zfs](https://github.com/zfsonlinux/zfs) which includes the upstream OpenZFS implementation and a repository [spl](https://github.com/zfsonlinux/spl) which is a shim to run OpenZFS on Linux.

Note that the script does not effect the filesystem that CoreOS is mounted on, it allows additional block devices to be mounted using the ZFS file system.

Hopefully this script will allow more people to experiment with ZFS on CoreOS to gain enough support that the CoreOS developers will bake it into CoreOS (note that this implementation does not gracefully handle updates to the CoreOS OS).

## References
This script is adapted from the instructions from:

1. https://coreos.com/os/docs/latest/kernel-modules.html  
2. https://github.com/zfsonlinux/zfs/wiki/Building-ZFS

## Issues

1. This should really be baked into CoreOS (so hopefully this script is just a temporary stop-gap solution until the CoreOS developers include ZFS support natively)  
2. It is uncertain whether the kernel drivers will continue to work after a CoreOS update, or whether the script needs to be re-run to re-build them (further support for why it should be baked into CoreOS). It is recommended to turn off CoreOS automatic updates to ensure that an automatic update does not result an incompatibility with the kernel drivers.  
	
## Using ZFS

There are some good resources for using zfs at:
- https://www.csparks.com/ZFS%20Without%20Tears.html.
- https://pthree.org/2012/04/17/install-zfs-on-debian-gnulinux

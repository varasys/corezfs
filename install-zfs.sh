#!/bin/bash

function error_exit {
    echo "$(basename $0): ${1:-"Unknown Error"}" 1>&2
    exit 1
}

[ "$EUID" -eq 0 ] || error_exit "Script must be run as root"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

. /usr/share/coreos/release
. /usr/share/coreos/update.conf
[ -e /etc/coreos/update.conf ] && . /etc/coreos/update.conf

ARCHIVE="${DIR}/${2:-corezfs_$COREOS_RELEASE_BOARD_$COREOS_RELEASE_VERSION_${GROUP:-stable}}.tar.gz"

function prepare_build_script {
	cat > /opt/usr/local/sbin/build-zfs.sh <<-"EOF"
	#!/bin/bash

	function error_exit
	{
		echo "$(basename $0): ${1:-"Unknown Error"}" 1>&2
		exit 1
	}

	[ "$EUID" -eq 0 ] || error_exit "Script must be run as root"

	emerge-gitclone \
	&& (. /usr/share/coreos/release; \
	git -C /var/lib/portage/coreos-overlay checkout build-${COREOS_RELEASE_VERSION%%.*}) \
	||  error_exit "$LINENO: Error installing emerge-gitclone"

	emerge -gKv coreos-sources \
	&& gzip -cd /proc/config.gz > /usr/src/linux/.config \
	&& make -C /usr/src/linux modules_prepare \
	|| error_exit "$LINENO: Error installing coreos-sources"

	emerge sys-devel/automake sys-devel/autoconf sys-devel/libtool \
	|| error_exit "$LINENO: Error installing development tools"

	mkdir spl \
	&& curl -L https://api.github.com/repos/zfsonlinux/spl/tarball \
	| tar -zxv -C spl --strip-components=1 \
	|| error_exit "$LINENO: Error cloning spl repository"
	cd spl
	./autogen.sh || error_exit "$LINENO: Error running autogen.sh for spl"
	./configure --prefix /usr/local || error_exit "$LINENO: Error configuring spl"
	make -j$(nproc) || error_exit "$LINENO: Error making spl"
	make install || error_exit "$LINENO: Error installing spl"
	cd ../
	mkdir zfs \
	&& curl -L https://api.github.com/repos/zfsonlinux/zfs/tarball \
	| tar -zxv -C zfs --strip-components=1 \
	|| error_exit "$LINENO: Error cloning zfs repository"
	cd zfs
	./autogen.sh || error_exit "$LINENO: Error running autogen.sh for zfs"
	./configure \
		--disable-sysvinit \
		--with-systemdunitdir=/usr/local/systemd/system \
		--with-systemdpresetdir=/usr/local/systemd/system-preset \
	|| error_exit "$LINENO: Error configuring zfs"
	make -j$(nproc) || error_exit "$LINENO: Error making zfs"
	make install || error_exit "$LINENO: Error installing zfs"
	EOF
	chmod +x /opt/usr/local/sbin/build-zfs.sh
}

function delete_build_script {
	rm -f /opt/usr/local/sbin/build-zfs.sh
}

function download_dev_env {
	if [ ! -e "$DIR/coreos_developer_container.bin" ]; then
		url="http://${GROUP:-stable}.release.core-os.net/$COREOS_RELEASE_BOARD/$COREOS_RELEASE_VERSION/coreos_developer_container.bin.bz2"
		gpg2 --recv-keys 48F9B96A2E16137F && \
		curl -L "$url" |
			tee >(bzip2 -d > "$DIR/coreos_developer_container.bin") |
			gpg2 --verify <(curl -Ls "$url.sig") - \
		|| error_exit "$LINENO: Error downloading coreos_developer_container from $url"
	fi
}

function launch_dev_env {
	sudo systemd-nspawn \
		--ephemeral \
		--read-only \
		--tmpfs=/usr/src \
		--chdir=/usr/src \
		--bind=/lib/modules \
		--bind=/usr/local \
		--image="$DIR/coreos_developer_container.bin" \
		build-zfs.sh \
		|| error_exit "$LINENO: Error running development container"
}

function create_systemd_units {
	cat > /opt/usr/local/etc/systemd/system/lib-modules.mount <<-EOF
	[Unit]
	Description=ZFS Kernel Modules
	ConditionPathExists=/opt/modules
	Before=zfs.service

	[Mount]
	Type=overlay
	What=overlay
	Where=/lib/modules
	Options=lowerdir=/lib/modules,upperdir=/opt/modules,workdir=/opt/.modules.wd

	[Install]
	WantedBy=zfs.service
	EOF

	cat > /opt/usr/local/etc/systemd/system/usr-local.mount <<-EOF
	[Unit]
	Description=ZFS User Tools
	ConditionPathExists=/opt/usr/local
	Before=zfs.service

	[Mount]
	Type=overlay
	What=overlay
	Where=/usr/local
	Options=lowerdir=/usr/local,upperdir=/opt/usr/local,workdir=/opt/usr/.local.wd

	[Install]
	WantedBy=zfs.target
	EOF

	cat > /opt/usr/local/etc/systemd/system/zfs.service <<-EOF
	[Unit]
	Description=ZFS Kernel Modules
	Before=zfs-import-cache.service
	Before=zfs-import-scan.service

	[Service]
	Type=oneshot
	RemainAfterExit=yes
	ExecStart=/usr/sbin/modprobe zfs

	[Install]
	WantedBy=zfs.target
	EOF

	cat > /opt/usr/local/etc/systemd/system-preset/40-overlays.preset <<-EOF
	enable usr-local.mount
	enable lib-modules.mount
	enable zfs.service
	EOF
}

case $1 in
	build)
		rm -rf /opt		
		mkdir -p /opt/{modules,.modules.wd,usr/{local/{share/corezfs,sbin,etc/systemd/{system,system-preset}},.local.wd}} \
		|| error_exit "$LINENO: Error creating overlay directories"
		cp -a "{$DIR}/*" /opt/usr/local/share/corezfs
		prepare_build_script
		download_dev_env
		launch_dev_env
		delete_build_script
		create_systemd_units
		if [ $2 != "--no-archive" ]; then
			tar -zcvhf "${ARCHIVE}" -C / --exclude=/opt/.modules.wd/* --exclude=/opt/usr/.local.wd opt
		fi
		;;
	install)
		if [ -e "$ARCHIVE" ]; then
			tar -zxvhf "$ARCHIVE" -C / \
			|| error_exit "$LINENO: Error extracting $ARCHIVE"
		fi
		tar -cvh -C /opt/usr/local/systemd * | tar -xvh -C /etc/systemd \
		|| error_exit "$LINENO: Error installing systemd unit files}"
		
		systemctl daemon-reload \
		&& systemctl start lib-modules.mount usr-local.mount \
		|| error_exit "$LINENO: Error mounting overlays}"
		
		ldconfig || error_exit "$LINENO: Error reloading shared libraries"
		depmod || error_exit "$LINENO: Error running depmod"
		
		ls /opt/usr/local/systemd/system/* | xargs systemctl preset || error_exit "$LINENO: Error presetting systemd zfs units"
		systemctl start zfs.target || error_exit "$LINENO: Error starting zfs.target systemd unit"
		;;
	*)
		cat <<-EOF
		Usage: sudo ./corezfs/install-zfs.sh
					Install zfs and create archive file with default name
		       sudo 
		EOF
		;;
esac
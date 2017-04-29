#!/bin/bash

function error_exit
{
    echo "$(basename $0): ${1:-"Unknown Error"}" 1>&2
    exit 1
}

[ "$EUID" -eq 0 ] || error_exit "Script must be run as root"

mkdir -p /opt/{modules,modules.wd,usr/{local/sbin,local.wd}} \
|| error_exit "$LINENO: Error creating overlay directories"

cat > /opt/usr/local/sbin/build-zfs.sh <<\EOF
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

git clone https://github.com/zfsonlinux/spl.git || error_exit "$LINENO: Error cloning spl repository"
cd spl
./autogen.sh || error_exit "$LINENO: Error running autogen.sh for spl"
./configure --prefix /usr/local || error_exit "$LINENO: Error configuring spl"
make -j$(nproc) || error_exit "$LINENO: Error making spl"
make install || error_exit "$LINENO: Error installing spl"
cd ../
git clone https://github.com/zfsonlinux/zfs.git || error_exit "$LINENO: Error cloning zfs repository"
cd zfs
./autogen.sh || error_exit "$LINENO: Error running autogen.sh for zfs"
./configure \
    --disable-sysvinit \
    --with-systemdunitdir=/usr/local/etc/systemd/system \
    --with-systemdpresetdir=/usr/local/etc/systemd/system-preset \
    --prefix /usr/local \
|| error_exit "$LINENO: Error configuring zfs"
make -j$(nproc) || error_exit "$LINENO: Error making zfs"
make install || error_exit "$LINENO: Error installing zfs"
EOF
chmod +x /opt/usr/local/sbin/build-zfs.sh

cat > /etc/systemd/system/lib-modules.mount <<EOF
[Unit]
Description=ZFS Kernel Modules
ConditionPathExists=/opt/modules
Before=zfs-import-cache.service
Before=zfs-import-scan.service

[Mount]
Type=overlay
What=overlay
Where=/lib/modules
Options=lowerdir=/lib/modules,upperdir=/opt/modules,workdir=/opt/modules.wd

[Install]
RequiredBy=zfs-import-cache.service
RequiredBy=zfs-import-scan.service
EOF

cat > /etc/systemd/system/usr-local.mount <<EOF
[Unit]
Description=ZFS User Tools
ConditionPathExists=/opt/usr/local
Before=zfs-import-cache.service
Before=zfs-import-scan.service

[Mount]
Type=overlay
What=overlay
Where=/usr/local
Options=lowerdir=/usr/local,upperdir=/opt/usr/local,workdir=/opt/usr/local.wd

[Install]
RequiredBy=zfs-import-cache.service
RequiredBy=zfs-import-scan.service
EOF

systemctl daemon-reload || error_exit "$LINENO: Error reloading systemd units"
systemctl enable --now lib-modules.mount || error_exit "$LINENO: Error mounting /lib/modules overlay" 
systemctl enable --now usr-local.mount || error_exit "$LINENO: Error mounting /usr/local overlay"

if [ ! -f coreos_developer_container.bin ]; then
    . /usr/share/coreos/release
    . /usr/share/coreos/update.conf
    . /etc/coreos/update.conf  # This might not exist.
    url="http://${GROUP:-stable}.release.core-os.net/$COREOS_RELEASE_BOARD/$COREOS_RELEASE_VERSION/coreos_developer_container.bin.bz2"
    gpg2 --recv-keys 48F9B96A2E16137F && \
    curl -L "$url" |
        tee >(bzip2 -d > coreos_developer_container.bin) |
        gpg2 --verify <(curl -Ls "$url.sig") - \
    || error_exit "$LINENO: Error downloading coreos_developer_container from $url"
fi

sudo systemd-nspawn \
    --ephemeral \
    --tmpfs=/usr/src \
    --chdir=/usr/src \
    --bind=/lib/modules \
    --bind=/usr/local \
    --image=coreos_developer_container.bin \
    build-zfs.sh \
    || error_exit "$LINENO: Error running development container"

rm -rf /opt/usr/local/sbin/build-zfs.sh
ldconfig || error_exit "$LINENO: Error reloading shared libraries"
depmod || error_exit "$LINENO: Error refreshing module dependencies"
rsync -av /usr/local/etc/* /etc/
systemctl daemon-reload || error_exit "$LINENO: Error running systemctl daemon-reload"
systemctl enable --now zfs.target || error_exit "$LINENO: Error starting zfs.target systemd unit"
cd ../
rm -rf corezfs

#!/usr/bin/env bash


export debconf_locales="locales	locales/default_environment_locale	select	en_US.UTF-8
locales	locales/locales_to_be_generated	select	en_US.UTF-8 UTF-8"

#Force root
[[ "$(id -u)" != 0 ]] && exec sudo "$0" "$@"

Main() {
    local target="$1"

    debootstrap --include=git,lvm2,bc,pv,parallel,qemu-utils,rsync stretch "$target"
    chroot "$target" bash -c debconf-set-selections < <(echo "$debconf_locales")
    #https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=697765
    chroot "$target" bash -c "DEBIAN_FRONTEND=noninteractive apt-get -y install locales"

    XZ_OPT=-4T0 tar -Jcf bcrm.tar.xz -C "$target" .
}

bash -n $(readlink -f $0) && Main "$@" #self check and run


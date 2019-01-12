#! /usr/bin/env bash

# Copyright (C) 2017-2019 Marcel Lautenbach
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License asublished by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Thisp rogram is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with thisrogram.  If not, see <http://www.gnu.org/licenses/>.

F_PART_LIST='part_list'
F_VGS_LIST='vgs_list'
F_LVS_LIST='lvs_list'
F_PVS_LIST='pvs_list'
F_SECTORS_SRC='sectors'
F_SECTORS_USED='sectors_used'
F_PART_TABLE='part_table'
F_CHESUM='check.md5'
F_LOG='/tmp/bcrm.log'

SCRIPTNAME=$(basename "$0")
PIDFILE="/var/run/$SCRIPTNAME"

declare CLONE_DATE=$(date '+%d%m%y')
export LVM_SUPPRESS_FD_WARNINGS=true

declare -A MNTJRNL
declare -A FILESYSTEMS MOUNTS NAMES PARTUUIDS UUIDS TYPES PUUIDS2UUIDS
declare -A SRC_LFS DESTS SRC2DEST PSRC2PDEST NSRC2NDEST

declare SPUUIDS=() SUUIDS=()
declare DPUUIDS=() DUUIDS=()
declare SFS=() LMBRS=() SRCS=() LDESTS=() LSRCS=() PVS=() VG_DISKS=()

declare VG_SRC_NAME
declare VG_SRC_NAME_CLONE

declare HAS_GRUB=false #If the cloned system uses GRUB
declare HAS_EFI=false #If the cloned system is UEFI enabled
declare SYS_HAS_EFI=false #If the currently running system has UEFI
declare IS_LVM=false
declare PVALL=false #Use all PVS for LVM
declare IS_CHECKSUM=false #-c
declare INTERACTIVE=false #Show Progress (if pv is installed)

declare LUKS_LVM_NAME=lukslvm_$CLONE_DATE
declare SECTORS=0
declare MIN_RESIZE=2048

USAGE="
Usage: $(basename $0) -s <source> -d <destination> [options]

-c] [-x] [-H <hostname>] [-n <name>] [-e <passphrase>] [-u] [-p] [-m <sizee in MB>] [-q] [-h]

Options:
    -c \t\t\t\t Create/Validate checksums
    -x \t\t\t\t Use compression (compression ration about 1:3, but very slow!)
    -H, --hostname \t\t Set hostname

    -n, --new-vg-name \t\t LVM only: Define new volume group name
    -e, --encrypt-with-password  LVM only: Create encrypted disk with supplied passphrase.

    -u \t\t\t\t Convert to UEFI
    -p \t\t\t\t LVM only: Use all disks found on destination as PVs for VG
    -m, --resize-threshold \t Do not resize partitions smaller than the size provided (default 2048)

    -q \t\t\t\t Quiet, do not show any output
    -h, --help \t\t\t Show this help text
"

### DEBUG ONLY

printarr() { #{{{
    declare -n __p="$1"
    for k in "${!__p[@]}"; do printf "%s=%s\n" "$k" "${__p[$k]}"; done
} #}}}

### FOR LATER USE

setHeader() { #{{{
    tput csr 2 $(($(tput lines) - 2))
    tput cup 0 0
    tput el
    echo "$1"
    tput el
    echo -n "$2"
    tput cup 3 0
} #}}}

### PRIVATE - only used by PUBLIC functions

# By convention methods ending with a '_' overwrite or wrap commands with the same name.

echo_() { #{{{
    exec 1>&3 #restore stdout
    echo "$1"
    exec 3>&1 #save stdout
    exec > $F_LOG 2>&1 #again all to the log
} #}}}

mount_() { #{{{
    local cmd="mount"

    local OPTIND
    local src="$1"
    local path="/mnt/$src"
    shift

    while getopts ':p:t:' option; do
        case "$option" in
        t)
            cmd+=" -t $OPTARG"
            ;;
        p)
            path="$OPTARG"
            ;;
        :)
            printf "missing argument for -%s\n" "$OPTARG" >&2
            ;;
        ?)
            printf "illegal option: -%s\n" "$OPTARG" >&2
            ;;
        esac
    done
    shift $((OPTIND - 1))

    mkdir -p "$path"
    { $cmd "$src" "$path" && MNTJRNL["$src"]="$path"; } || return 1
} #}}}

umount_() { #{{{
    local OPTIND
    local cmd="umount"
    while getopts ':R' option; do
        case "$option" in
        R)
            cmd+=" -R"
            ;;
        :)
            printf "missing argument for -%s\n" "$OPTARG" >&2
            ;;
        \?)
            printf "illegal option: -%s\n" "$OPTARG" >&2
            ;;
        esac
    done
    shift $((OPTIND - 1))

    if [[ $# -eq 0 ]]; then
        for m in "${MNTJRNL[@]}"; do $cmd -l "$m"; done
        return 0
    fi

    if [[ "${MNTJRNL[$1]}" ]]; then
        $cmd "${MNTJRNL[$1]}" && unset MNTJRNL["$1"] || exit_ 1
    fi
} #}}}

exit_() { #{{{
    [[ -n $2 ]] && message -n -t "$2"
    Cleanup $1
} #}}}

encrypt() { #{{{
    { echo ';' | sfdisk "$DEST" && sfdisk -Vq; } || return 1 #delete all partitions and create one for the whole disk.
    sleep 3
    ENCRYPT_PART=$(sfdisk -qlo device $DEST | tail -n 1)
    echo -n "$1" | cryptsetup luksFormat $ENCRYPT_PART -
    echo -n "$1" | cryptsetup open $ENCRYPT_PART $LUKS_LVM_NAME --type luks -
} #}}}

message() { #{{{
    local OPTIND
    local status
    local text=
    local update=false
    clor_cancel=$(tput bold; tput setaf 3)
    clr_yes=$(tput setaf 2)
    clor_no=$(tput setaf 1)
    clr_rmso=$(tput sgr0)

    exec 1>&3 #restore stdout
    #prepare
    while getopts ':nucyt:' option; do
        case "$option" in
        t)
            text=" $OPTARG"
            ;;
        y)
            status="${clr_yes}✔${clr_rmso}"
            tput rc
            ;;
        n)
            status="${clor_no}✘${clr_rmso}"
            tput rc
            ;;
        u)
            update=true
            ;;
        c)
            status="${clor_cancel}➤${clr_rmso}"
            tput sc
            ;;
        :)
            exit_ 5 "Method call error: \t${FUNCNAME[0]}()\tMissing argument for $OPTARG"
            ;;
        ?)
            exit_ 5 "Method call error: \t${FUNCNAME[0]}()\tIllegal option: $OPTARG"
            ;;
        esac
    done
    shift $((OPTIND - 1))
    status="${status}"

    #execute
    {
        [[ -n $status ]] && echo -e -n "$status"
        [[ -n $text ]] && echo -e -n "$text" && tput el
        echo
    }
    [[ $update == true ]] && tput rc
    tput civis
    exec 3>&1 #save stdout
    exec >> $F_LOG 2>&1 #again all to the log
} #}}}

expand_disk() { #{{{
    local ss=$(if [[ -d $1 ]]; then cat $1/$F_SECTORS_SRC; else blockdev --getsz $1; fi)
    local ds=$(blockdev --getsz $2)

    local expand_factor=$(echo "scale=2; $ds / $ss" | bc)
    local size new_size
    local pdata=$(if [[ -f "$3" ]]; then cat "$3"; else echo "$3"; fi)

    while read -r e; do
        size=
        new_size=

        if [[ $e =~ ^/ ]]; then
            echo "$e" | grep -qE 'size=\s*([0-9])' &&
                size=$(echo "$e" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
        fi

        if [[ -n "$size" ]]; then
            [[ $(($size / 2 / 1024)) -le $MIN_RESIZE ]] && continue
            new_size=$(echo "scale=2; $size * $expand_factor" | bc) &&
                pdata=$(sed "s/$size/${new_size%%.*}/" < <(echo "$pdata"))
        fi
    done < <(if [[ -f "$pdata" ]]; then cat "$pdata"; else echo "$pdata"; fi)

    #Remove fixed offsets and only apply size values. We assume the extended partition ist last!
    pdata=$(sed 's/start=\s*\w*,//g' < <(echo "$pdata"))
    #When a field is absent or empty the default value of size indicates "as much as asossible";
    #Therefore we remove the size for extended partitions
    pdata=$(sed '/type=5/ s/size=\s*\w*,//' < <(echo "$pdata"))
    #and the last partition
    pdata=$(sed '$ s/size=\s*\w*,//g' < <(echo "$pdata"))
    pdata=$(sed '/last/d' < <(echo "$pdata"))

    #return
    echo "$pdata"
} #}}}

mbr2gpt() { #{{{
    local efisysid='C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
    local dest="$1"
    local overlap=$(echo q | gdisk "$dest" | grep -P '\d*\s*blocks!' | awk '{print $1}')
    local pdata=$(sfdisk -d "$dest")

    if [[ $overlap > 0 ]]; then
        local sectors=$(echo "$pdata" | tail -n 1 | grep -o -P 'size=\s*(\d*)' | awk '{print $2}')
        flock $dest sfdisk "$dest" < <(echo "$pdata" | sed -e "$ s/$sectors/$((sectors - overlap))/")
    fi

    blockdev --rereadpt "$dest"
    flock $dest sgdisk -z "$dest"
    flock $dest sgdisk -g "$dest"
    blockdev --rereadpt "$dest"

    local pdata=$(sfdisk -d "$dest")
    local fstsctr=$(echo "$pdata" | grep -o -P 'size=\s*(\d*)' | awk '{print $2}' | head -n 1)
    pdata=$(echo "$pdata" | sed -e "s/$fstsctr/$((fstsctr - 1024000))/")
    pdata=$(echo "$pdata" | grep 'size=' | sed -e 's/^[^,]*,//; s/uuid=[a-Z0-9-]*,\{,1\}//')
    pdata=$(echo -e "size=1024000, type=${efisysid}\n${pdata}")
    flock $dest sfdisk "$dest" < <(echo "$pdata")
    blockdev --rereadpt "$dest"
} #}}}

create_m5dsums() { #{{{
    # find "$1" -type f \! -name '*.md5' -print0 | xargs -0 md5sum -b > "$1/$2"
    pushd "$1" || return 1
    find . -type f \! -name '*.md5' -print0 | parallel --no-notice -0 md5sum -b >"$2"
    popd || return 1
    validate_m5dsums "$1" "$2" || return 1
} #}}}

validate_m5dsums() { #{{{
    pushd "$1" || return 1
    md5sum -c "$2" --quiet || return 1
    popd || return 1
} #}}}

set_dest_uuids() { #{{{
    DPUUIDS=() DUUIDS=() DNAMES=()
    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mnt <<<"$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $UEFI == true && $PARTTYPE == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] && continue
        [[ $PARTTYPE == 0x5 || $TYPE == crypt || $FSTYPE == crypto_LUKS || $FSTYPE == LVM2_member ]] && continue
        [[ -n $UUID ]] && DESTS[$UUID]="$NAME"
        [[ ${PVS[@]} =~ $NAME ]] && continue
        DPUUIDS+=($PARTUUID)
        DUUIDS+=($UUID)
        DNAMES+=($NAME)
    done < <(lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" $([[ $PVALL == true ]] && echo ${PVS[@]}) | sort -n | uniq | grep -vE '\bdisk|\bUUID=""')
} #}}}

set_src_uuids() { #{{{
    SPUUIDS=() SUUIDS=() SNAMES=()
    local n=0
    local plist

    if [[ $UEFI == true && $n -eq 0 ]]; then
        SFS[$n]=vfat
        n=$((n + 1))
    fi

    if [[ -n $1 ]]; then
        plist=$(cat "$1")
    else
        plist=$(lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" ${VG_DISKS[@]})
    fi

    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mountpoint <<<"$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"

        [[ ($TYPE == part && $FSTYPE == LVM2_member || $FSTYPE == crypto_LUKS) && $ENCRYPT ]] && continue
        [[ $FSTYPE == crypto_LUKS ]] && FSTYPE=ext4 && LMBRS[$n]="$UUID"
        [[ $PARTTYPE == 0x5 || $TYPE == crypt || $FSTYPE == crypto_LUKS ]] && continue
        [[ $TYPE == part && $FSTYPE != LVM2_member ]] && SFS[$n]="$FSTYPE" && n=$((n + 1))
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $FSTYPE == LVM2_member ]] && LMBRS[$n]="$UUID" && n=$((n + 1)) && continue
        SPUUIDS+=($PARTUUID)
        SUUIDS+=($UUID)
        SNAMES+=($NAME)
        [[ -b $SRC ]] && count "$KNAME"
    done < <(echo "$plist" | sort -n | uniq | grep -v 'disk')
} #}}}

init_srcs() { #{{{
    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mountpoint <<<"$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $FSTYPE == LVM2_member || $FSTYPE == swap || $TYPE == crypt || $FSTYPE == crypto_LUKS ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $TYPE == lvm && -z $1 ]] && LSRCS+=($NAME)
        [[ $TYPE == part ]] && SRCS+=($NAME)
        FILESYSTEMS[$NAME]="$FSTYPE"
        PARTUUIDS[$NAME]="$PARTUUID"
        UUIDS[$NAME]="$UUID"
        TYPES[$NAME]="$TYPE"
        [[ -n $UUID ]] && NAMES[$UUID]=$NAME
        [[ -n $PARTUUID ]] && NAMES[$PARTUUID]=$NAME
        [[ -n $UUID && -n $PARTUUID ]] && PUUIDS2UUIDS[$PARTUUID]="$UUID"
    done < <( if [[ -n $1 ]]; then cat "$1";
              else lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" ${VG_DISKS[@]} | sort -n | uniq | grep -v 'disk';
              fi )
} #}}}

is_partition() { #{{{
    read -r name parttype type fstype <<<$(lsblk -Ppo NAME,PARTTYPE,TYPE,FSTYPE "$1" | grep "$2")
    eval "$name" "$parttype" "$type" "$fstype"
    [[ $PARTTYPE == 0x5 || $TYPE == disk || $TYPE == crypt || $FSTYPE == crypto_LUKS ]] && return 0
    return 1
} #}}}

vg_extend() { #{{{
    local dest=$DEST
    local src=$SRC
    PVS=()

    if [[ -d $SRC ]]; then
        src=$(df -P "$SRC" | tail -1 | awk '{print $1}')
    fi

    while read -r e; do
        read -r name type <<<"$e"
        [[ -n $(lsblk -no mountpoint $name 2>/dev/null) ]] && continue
        echo ';' | flock $name sfdisk -q $name && sfdisk $name -Vq
        local part=$(lsblk $name -lnpo name,type | grep part | awk '{print $1}')
        pvcreate -f $part && vgextend $1 $part
        PVS+=($part)
    done < <(lsblk -po name,type | grep disk | grep -Ev "$dest|$src")
} #}}}

vg_disks() { #{{{
    for f in $(pvs --no-headings -o pv_name,lv_dm_path | grep -E "${1}\-\w+" | awk '{print $1}' | uniq); do
        VG_DISKS+=($(lsblk -pnls $f | grep disk | awk '{print $1}'))
    done
} #}}}

disk_setup() { #{{{
    if [[ $UEFI == true ]]; then
        for v in ${SFS[@]}; do local sfs+=($v); done
        SFS=(${SFS[@]})
    fi

    local n=0
    while read -r e; do
        read -r name parttype <<<"$e"
        eval "$name"
        [[ -n ${LMBRS[$n]} ]] && pvcreate -f "$NAME" && continue
        [[ -n ${SFS[${n}]} && ${SFS[${n}]} == swap ]] && mkswap -f "$NAME" && continue
        [[ -n ${SFS[$n]} ]] && mkfs -t "${SFS[$n]}" "$NAME"
        n=$((n + 1))
    done < <(lsblk -Ppo NAME,PARTTYPE "$DEST" | grep -E '[0-9$]' | sort -n | grep -v 'PARTTYPE="0x5"')
    sleep 3
} #}}}

boot_setup() { #{{{
    local p=$(declare -p "$1")
    eval "declare -A sd=${p#*=}" #redeclare p1 A-rray

    local path=(
        "/cmdline.txt"
        "/etc/fstab"
        "/grub/grub.cfg"
        "/boot/grub/grub.cfg"
        "/etc/initramfs-tools/conf.d/resume"
    )

    for k in "${!sd[@]}"; do
        for d in "${DESTS[@]}"; do
            sed -i "s|$k|${sd[$k]}|" \
                "/mnt/$d/${path[0]}" "/mnt/$d/${path[1]}" \
                "/mnt/$d/${path[2]}" "/mnt/$d/${path[3]}" \
                2>/dev/null

            #resume file might be wrong, so we just set it explicitely
            if [[ -e /mnt/$d/${path[4]} ]]; then
                local uuid fstype
                read -r uuid fstype <<<$(lsblk -Ppo uuid,fstype "$DEST" | grep 'swap')
                echo "RESUME=$uuid" >$"/mnt/$d/${path[4]}"
            fi
        done
    done
} #}}}

grub_setup() { #{{{
    local d=${DESTS[${SRC2DEST[${MOUNTS['/']}]}]}
    mount "$d" "/mnt/$d"

    sed -i -E "/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*||" "/mnt/$d/etc/default/grub"
    sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=n/' "/mnt/$d/etc/default/grub"
    sed -i 's/^/#/' "/mnt/$d/etc/crypttab"

    for f in sys dev dev/pts proc run; do
        mount --bind "/$f" "/mnt/$d/$f"
    done

    #TODO order, e.g first /boot, then /boot/efi.
    for m in "${!MOUNTS[@]}"; do
        [[ "$m" == / ]] && continue
        [[ "$m" =~ ^/ ]] && mount "${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}" "/mnt/$d/$m"
    done

    if [[ $UEFI == true && $HAS_EFI == true ]]; then
        while read -r e; do
            read -r name uuid parttype <<<"$e"
            eval "$name" "$uuid" "$parttype"
        done < <(lsblk -pPo name,uuid,parttype $DEST | grep -i 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b')

        echo -e "${uuid}\t/boot/efi\tvfat\tumask=0077\t0\t1" >>"/mnt/$d/etc/fstab"
        mkdir -p /mnt/$d/boot/efi && mount $uuid /mnt/$d/boot/efi
    fi

    [[ $HAS_EFI == true && $SYS_HAS_EFI == false ]] && return 1

    if [[ $HAS_EFI == true ]]; then
        local apt_pkgs="grub-efi-amd64"
    else
        local apt_pkgs="binutils"
    fi

    pkg_install "$d" "$apt_pkgs" || return 1

    create_rclocal "/mnt/$d"
    umount -Rl "/mnt/$d"
    return 0
} #}}}

crypt_setup() { #{{{
    local d=${DESTS[${SRC2DEST[${MOUNTS['/']}]}]}
    mount "$d" "/mnt/$d"

    for f in sys dev dev/pts proc run; do
        mount --bind "/$f" "/mnt/$d/$f"
    done

    for m in "${!MOUNTS[@]}"; do
        [[ "$m" == / ]] && continue
        [[ "$m" =~ ^/ ]] && mount "${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}" "/mnt/$d/$m"
    done

    printf '%s' '#!/bin/sh
    exec /bin/cat /${1}' >/mnt/$d/home/dummy && chmod +x /mnt/$d/home/dummy

    printf '%s' '#!/bin/sh
	set -e

	PREREQ=\"\"

	prereqs()
	{
		echo "$PREREQ"
	}

	case $1 in
	prereqs)
		prereqs
		exit 0
		;;
	esac

	. /usr/share/initramfs-tools/hook-functions

	cp -a /crypto_keyfile.bin $DESTDIR/crypto_keyfile.bin
	mkdir -p $DESTDIR/home
	cp -a /home/dummy $DESTDIR/home

	exit 0' >"/mnt/$d/etc/initramfs-tools/hooks/lukslvm" && chmod +x "/mnt/$d/etc/initramfs-tools/hooks/lukslvm"

    dd oflag=direct bs=512 count=4 if=/dev/urandom of="/mnt/$d/crypto_keyfile.bin"
    echo -n "$1" | cryptsetup luksAddKey "$ENCRYPT_PART" "/mnt/$d/crypto_keyfile.bin" -
    chmod 000 "/mnt/$d/crypto_keyfile.bin"

    # local dev=$(lsblk -asno pkname /dev/mapper/$LUKS_LVM_NAME | head -n 1)
    echo "$LUKS_LVM_NAME UUID=$(cryptsetup luksUUID "$ENCRYPT_PART") /crypto_keyfile.bin luks,keyscript=/home/dummy" >"/mnt/$d/etc/crypttab"

    sed -i -E "/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*[^\"]||" "/mnt/$d/etc/default/grub"

    grep -q 'GRUB_CMDLINE_LINUX' "/mnt/$d/etc/default/grub" &&
        sed -i -E "/GRUB_CMDLINE_LINUX=/ s|\"(.*)\"|\"cryptdevice=UUID=$(cryptsetup luksUUID $ENCRYPT_PART):$LUKS_LVM_NAME \1\"|" "/mnt/$d/etc/default/grub" ||
        echo "GRUB_CMDLINE_LINUX=cryptdevice=UUID=$(cryptsetup luksUUID $ENCRYPT_PART):$LUKS_LVM_NAME" >>"/mnt/$d/etc/default/grub"

    grep -q 'GRUB_ENABLE_CRYPTODISK' "/mnt/$d/etc/default/grub" &&
        sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=y/' "/mnt/$d/etc/default/grub" ||
        echo "GRUB_ENABLE_CRYPTODISK=y" >>"/mnt/$d/etc/default/grub"

    pkg_install "$d" "lvm2 cryptsetup keyutils binutils grub2-common grub-pc-bin" || return 1
    create_rclocal "/mnt/$d"
    umount -lR "/mnt/$d"
} #}}}

pkg_install() { #{{{
    chroot "/mnt/$1" sh -c "
        apt-get install -y $2 &&
        grub-install $DEST &&
        update-grub &&
        update-initramfs -u -k all" || return 1
} #}}}

create_rclocal() { #{{{
    mv "$1/etc/rc.local" "$1/etc/rc.local.bak" 2>/dev/null
    printf '%s' '#! /usr/bin/env bash
    update-grub
    rm /etc/rc.local
    mv /etc/rc.local.bak /etc/rc.local 2>/dev/null
    sleep 10
    reboot' >"$1/etc/rc.local"
    chmod +x "$1/etc/rc.local"
} #}}}

count() { #{{{
    local x=$(swapon --show=size,name --bytes --noheadings | grep $1 | sed -e 's/\s+*.*//')
    SECTORS=$(($(df -k --output=used $KNAME | tail -n -1) + $SECTORS))
    SECTORS=$(($(echo ${x:=0} / 1024 | bc) + $SECTORS))
} #}}}

mounts() { #{{{
    for x in "${SRCS[@]}" "${LSRCS[@]}"; do
        local sdev=$x
        local sid=${UUIDS[$sdev]}

        mkdir -p "/mnt/$sdev"

        mount_ "$sdev"

        f[0]='cat /mnt/$sdev/etc/fstab | grep "^UUID" | sed -e "s/UUID=//" | tr -s " " | cut -d " " -f1,2'
        f[1]='cat /mnt/$sdev/etc/fstab | grep "^PARTUUID" | sed -e "s/PARTUUID=//" | tr -s " " | cut -d " " -f1,2'
        f[2]='cat /mnt/$sdev/etc/fstab | grep "^/" | tr -s " " | cut -d " " -f1,2'

        if [[ -f /mnt/$sdev/etc/fstab ]]; then
            for ((i = 0; i < ${#f[@]}; i++)); do
                while read -r e; do
                    read -r name mnt <<<"$e"
                    if [[ -n ${NAMES[$name]} ]]; then
                        MOUNTS[$mnt]="$name" && MOUNTS[$name]="$mnt"
                    elif [[ -n ${PUUIDS2UUIDS[$name]} ]]; then
                        MOUNTS[$mnt]="${PUUIDS2UUIDS[$name]}" && MOUNTS[${PUUIDS2UUIDS[$name]}]="$mnt"
                    elif [[ -n ${UUIDS[$name]} ]]; then
                        MOUNTS[$mnt]="${UUIDS[$name]}" && MOUNTS[${UUIDS[$name]}]="$mnt"
                    fi
                done < <(eval "${f[$i]}")
            done
        fi

        umount_ "$sdev"
    done
} #}}}

usage() { #{{{
    printf "%b\n" "$USAGE"
    exit_ 1
} #}}}

### PUBLIC - To be used in Main() only

Cleanup() { #{{{
    {
        umount_
        [[ $VG_SRC_NAME_CLONE ]] && vgchange -an $VG_SRC_NAME_CLONE
        [[ $ENCRYPT ]] && cryptsetup close /dev/mapper/$LUKS_LVM_NAME
    } &> /dev/null

    exec 1>&3 2>&4
    tput cnorm
    exec 200>&-
    exit ${1:-0} #Make sure we really exit the script!
} #}}}

To_file() { #{{{
    if [ -n "$(ls -A "$DEST")" ]; then return 1; fi

    pushd "$DEST" >/dev/null || return 1

    _save_disk_layout() { #{{{
        local snp=$(sudo lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role | grep 'snap' | sed -e 's/^\s*//' | awk '{print $1}')
        [[ -z $snp ]] && snp="NOSNAPSHOT"

        {
            pvs --noheadings -o pv_name,vg_name,lv_active | grep 'active$' | uniq | sed -e 's/active$//;s/^\s*//' >$F_PVS_LIST
            vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free,lv_active | grep 'active$' | uniq | sed -e 's/active$//;s/^\s*//' >$F_VGS_LIST
            lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role | grep -v 'snap' | grep 'active public.*' | sed -e 's/active public.*//;s/^\s*//' >$F_LVS_LIST
            blockdev --getsz "$SRC" >$F_SECTORS_SRC
            sfdisk -d "$SRC" >$F_PART_TABLE
        }

        sleep 3 #IMPORTANT !!! So changes by sfdisk can settle.
        #Otherwise resultes from lsblk might still show old values!
        lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" | uniq | grep -v "$snp" >$F_PART_LIST
    } #}}}

    message -c -t "Creating backup of disk layout"
    {
        _save_disk_layout
        init_srcs
        set_src_uuids
        mounts
    }
    message -y

    local VG_SRC_NAME=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | awk '{print $2}')
    if [[ -z $VG_SRC_NAME ]]; then
        while read -r e g; do
            grep -q ${SRC##*/} < <(dmsetup deps -o devname $e | sed 's/.*(\(\w*\).*/\1/g') && VG_SRC_NAME=$g
        done < <(pvs --noheadings -o pv_name,vg_name | xargs)
    fi

    #TODO remove this extra counter and do a simpler loop
    local g=0
    for x in SRCS LSRCS; do
        eval declare -n s="$x"

        for ((i = 0; i < ${#s[@]}; i++)); do
            local sdev=${s[$i]}
            local sid=${UUIDS[$sdev]}
            local spid=${PARTUUIDS[$sdev]}
            local fs=${FILESYSTEMS[$sdev]}
            local type=${TYPES[$sdev]}
            local mount=${MOUNTS[$sid]}

            local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | awk '{print $1}')
            local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${VG_SRC_NAME}" | uniq | awk '{print $2}')

            [[ -z ${FILESYSTEMS[$sdev]} ]] && continue
            local tdev=$sdev

            {
                if [[ $x == LSRCS && ${#LMBRS[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                    local tdev='snap4clone'
                    lvremove -f "${VG_SRC_NAME}/$tdev"
                    lvcreate -l100%FREE -s -n snap4clone "${VG_SRC_NAME}/$lv_src_name"
                    sleep 3
                    mount_ "/dev/${VG_SRC_NAME}/$tdev" -p "/mnt/$tdev"
                else
                    mount_ "$sdev" -t "${FILESYSTEMS[$sdev]}"
                fi
            }

            cmd="tar --warning=none --directory=/mnt/$tdev --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* --atime-preserve --numeric-owner --xattrs"
            [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

            if [[ $INTERACTIVE == true ]]; then
                message -u -c -t "Creating backup for $sdev in $ddev [ scan ]"
                local size=$(du --bytes --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* -s /mnt/$tdev | awk '{print $1}')
                cmd="$cmd -Scpf - . | pv --interval 0.5 --numeric -s $size | split -b 1G - ${g}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_} "

                while read -r e; do
                    [[ $e -ge 100 ]] && e=100 #Just a precaution
                    message -u -c -t "Creating backup for $sdev in $ddev [ $(printf '%02d%%' $e) ]"
                done < <(eval "$cmd" 2>&1) #Note that with pv stderr holds the current percentage value!
                message -u -c -t "Creating backup for $sdev in $ddev [ $(printf '%02d%%' 100) ]" #In case we very faster than the update interval of pv, especially when at 98-99%.
            else
                message -c -t "Creating backup for $sdev in $ddev"
                {
                    cmd="$cmd -Scpf - . | split -b 1G - ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_} "
                    eval "$cmd"
                }
            fi

            {
                umount_ "/dev/${VG_SRC_NAME}/$tdev"
                lvremove -f "${VG_SRC_NAME}/$tdev"
            }
            message -y
            g=$((g + 1))
        done

        for ((i = 0; i < ${#s[@]}; i++)); do umount_ "${s[$i]}"; done
    done

    popd >/dev/null || return 1
    echo $SECTORS >"$DEST/$F_SECTORS_USED"
    if [[ $IS_CHECKSUM == true ]]; then
        message -c -t "Creating checksums"
        {
            create_m5dsums "$DEST" "$F_CHESUM" || return 1
        }
        message -y
    fi
    return 0
} #}}}

Clone() { #{{{
    local OPTIND
    local _RMODE=false

    while getopts ':r' option; do
        case "$option" in
        r)
            _RMODE=true
            ;;
        :)
            printf "missing argument for -%s\n" "$OPTARG" >&2
            return 1
            ;;
        \?)
            printf "illegal option: -%s\n" "$OPTARG" >&2
            return 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    _lvm_setup() { #{{{
        local size s1 s2
        local dest=$1

        vgcreate "$VG_SRC_NAME_CLONE" $(pvs --noheadings -o pv_name,vg_name | grep -Ev '(\w+)\s*(\w+)$')
        [[ $PVALL == true ]] && vg_extend "$VG_SRC_NAME_CLONE"

        while read -r e; do
            read -r vg_name vg_size vg_free <<<"$e"
            [[ $vg_name == "$VG_SRC_NAME" ]] && s1=$((${vg_size%%.*} - ${vg_free%%.*}))
            [[ $vg_name == "$VG_SRC_NAME_CLONE" ]] && s2=${vg_size%%.*}
        done < <(if [[ $_RMODE == true ]]; then
            cat $SRC/$F_VGS_LIST
        else
            vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free
        fi)

        denom_size=$((s1 < s2 ? s2 : s1))

        # It might happen that a volume is so small, that it is only 0% in size. In this case we assume the
        # lowest possible value: 1%. This also means we have to decrease the maximum possible size. E.g. two volumes
        # with 0% and 100% would have to be 1% and 99% to make things work.
        local max_size=100

        while read -r e; do
            read -r lv_name vg_name lv_size vg_size vg_free lv_role <<<"$e"
            [[ $lv_role =~ snapshot ]] && continue
            size=$(echo "$lv_size * 100 / $denom_size" | bc)

            if ((s1 < s2)); then
                lvcreate --yes -L"${lv_size}" -n "$lv_name" "$VG_SRC_NAME_CLONE"
            else
                ((size == 0)) && size=1 && max_size=$((max_size - size))
                ((size == 100)) && size=$((size - max_size))
                lvcreate --yes -l${size}%VG -n "$lv_name" "$VG_SRC_NAME_CLONE"
            fi
        done < <(if [[ $_RMODE == true ]]; then
            cat $SRC/$F_LVS_LIST
        else
            lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_role
        fi)

        while read -r e; do
            read -r kname name fstype type <<<"$e"
            eval "$kname" "$name" "$fstype" "$type"
            [[ $TYPE == 'lvm' ]] && SRC_LFS[${NAME##*-}]=$FSTYPE
        done < <(if [[ -d $SRC ]]; then cat $SRC/$F_PART_LIST; else lsblk -Ppo KNAME,NAME,FSTYPE,TYPE "$SRC" ${VG_DISKS[@]}; fi)

        while read -r e; do
            read -r kname name fstype type <<<"$e"
            eval "$kname" "$name" "$fstype" "$type"
            { [[ "${SRC_LFS[${NAME##*-}]}" == swap ]] && mkswap -f "$NAME"; } || mkfs -t "${SRC_LFS[${NAME##*-}]}" "$NAME"
        done < <(lsblk -Ppo KNAME,NAME,FSTYPE,TYPE "$DEST" ${PVS[@]} | uniq | grep ${VG_SRC_NAME_CLONE/-/--}); : 'The
        device mapper doubles hyphens in a LV/VG names exactly so it can distinguish between hyphens _inside_ an LV or
        VG name and a hyphen used as separator _between_ them.'
    } #}}}

    _prepare_disk() { #{{{
        if hash lvm 2>/dev/null; then
            # local vgname=$(vgs -o pv_name,vg_name | eval grep "'${DEST}|${VG_DISKS/ /|}'" | awk '{print $2}')
            local vgname=$(vgs -o pv_name,vg_name | grep "${DEST}" | awk '{print $2}')
            vgreduce --removemissing "$vgname"
            vgremove -f "$vgname"
        fi

        dd oflag=direct if=/dev/zero of="$DEST" bs=512 count=100000
        dd oflag=direct bs=512 if=/dev/zero of="$DEST" count=4096 seek=$(($(blockdev --getsz $DEST) - 4096))

        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"

        sleep 3

        if [[ $ENCRYPT ]]; then
            encrypt "$ENCRYPT"
        else
            local a="$(if [[ $_RMODE == true ]]; then cat $SRC/$F_PART_TABLE; else sfdisk -d $SRC; fi)"

            flock "$DEST" sfdisk --force "$DEST" < <(expand_disk "$SRC" "$DEST" "$a")
            flock "$DEST" sfdisk -Vq "$DEST" || return 1
        fi
        sleep 1
        blockdev --rereadpt "$DEST"

        [[ $UEFI == true ]] && mbr2gpt $DEST
    } #}}}

    _finish() { #{{{
        [[ -f /mnt/$ddev/etc/hostname && -n $HOST_NAME ]] && echo $HOST_NAME >/mnt/$ddev/etc/hostname
        [[ -f /mnt/$ddev/grub/grub.cfg || -f /mnt/$ddev/grub.cfg || -f /mnt/$ddev/boot/grub/grub.cfg ]] && HAS_GRUB=true
        [[ -d /mnt/$ddev/EFI ]] && HAS_EFI=true
        [[ ${#SRC2DEST[@]} -gt 0 ]] && boot_setup "SRC2DEST"
        [[ ${#PSRC2PDEST[@]} -gt 0 ]] && boot_setup "PSRC2PDEST"
        [[ ${#NSRC2NDEST[@]} -gt 0 ]] && boot_setup "NSRC2NDEST"

        umount_ "$sdev"
        umount_ "$ddev"
    } #}}}

    _from_file() { #{{{
        declare -A files
        pushd "$SRC" >/dev/null || return 1

        for file in [0-9]*; do
            files[${file::-2}]=1
        done

        #Now, we are ready to restore files from previous backup images
        for file in ${!files[@]}; do
            read -r i uuid puuid fs type dev mnt <<<"${file//./ }"
            local ddev=${DESTS[${SRC2DEST[$uuid]}]}

            MOUNTS[${mnt//_/\/}]="$uuid"

            if [[ -n $ddev ]]; then
                mount_ "$ddev" -t "$fs"
                pushd "/mnt/$ddev" >/dev/null || return 1

                cmd="tar -xf - -C /mnt/$ddev"
                [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

                if [[ $fs == vfat ]]; then
                    fakeroot cat "${SRC}/${file}"* | eval "$cmd"
                else
                    if [[ $INTERACTIVE == true ]]; then
                        local size=$(du --bytes -c "${SRC}/${file}"* | tail -n1 | awk '{print $1}')
                        while read -r e; do
                            [[ $e -ge 100 ]] && e=100
                            message -u -c -t "Restoring $file [ $(printf '%02d%%' $e) ]"
                            #Note that with pv stderr holds the current percentage value!
                        done < <((cat "${SRC}/${file}"* | pv --interval 0.5 --numeric -s "$size" | eval "$cmd") 2>&1)
                        message -u -c -t "Restoring $file [ $(printf '%02d%%' 100) ]"
                    else
                        message -c -t "Restoring $file"
                        cat "${SRC}/${file}"* | eval "$cmd"
                    fi
                fi

                popd >/dev/null || return 1
                _finish 2>/dev/null
            fi
            message -y
        done

        popd >/dev/null || return 1
        return 0
    } #}}}

    _clone() { #{{{
        for dev in SRCS LSRCS; do
            eval declare -n s="$dev"

            for ((i = 0; i < ${#s[@]}; i++)); do
                local sdev=${s[$i]}
                local sid=${UUIDS[$sdev]}
                local ddev=${DESTS[${SRC2DEST[$sid]}]}

                [[ -z ${FILESYSTEMS[$sdev]} ]] && continue

                mkdir -p "/mnt/$ddev" "/mnt/$sdev"

                local tdev=$sdev

                [[ -d /mnt/$sdev/EFI ]] && HAS_EFI=true
                [[ $SYS_HAS_EFI == false && $HAS_EFI == true ]] && exit_ 1 "Cannot clone UEFI system. Current running system does not support UEFI."

                {
                    if [[ $dev == LSRCS && ${#LMBRS[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                        local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | awk '{print $1}')
                        local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${VG_SRC_NAME}" | uniq | awk '{print $2}')
                        tdev='snap4clone'
                        mkdir -p "/mnt/$tdev"
                        lvremove -q -f "${VG_SRC_NAME}/$tdev"
                        lvcreate -l100%FREE -s -n snap4clone "${VG_SRC_NAME}/$lv_src_name" &&
                            sleep 3 &&
                            mount_ "/dev/${VG_SRC_NAME}/$tdev" -p "/mnt/$tdev" || return 1
                    else
                        mount_ "$sdev"
                    fi
                }

                mount_ "$ddev"

                if [[ $INTERACTIVE == true ]]; then
                    message -u -c -t "Cloning $sdev to $ddev [ scan ]"
                    local size=$(
                        rsync -aSXxH --stats --dry-run "/mnt/$tdev/" "/mnt/$ddev" |
                            grep -oP 'Number of files: \d*(,\d*)*' |
                            cut -d ':' -f2 |
                            tr -d ' ' |
                            sed -e 's/,//'
                    )

                    while read -r e; do
                        [[ $e -ge 100 ]] && e=100
                        message -u -c -t "Cloning $sdev to $ddev [ $(printf '%02d%%' $e) ]"
                    done < <((rsync -vaSXxH "/mnt/$tdev/" "/mnt/$ddev" | pv --interval 0.5 --numeric -le -s "$size" 3>&2 2>&1 1>&3) 2>/dev/null)
                    message -u -c -t "Cloning $sdev to $ddev [ $(printf '%02d%%' 100) ]"
                else
                    message -c -t "Cloning $sdev to $ddev"
                    {
                        rsync -aSXxH "/mnt/$tdev/" "/mnt/$ddev"
                    } >/dev/null
                fi
                {
                    sleep 3
                    umount_ "/dev/${VG_SRC_NAME}/$tdev"
                    [[ $dev == LSRCS ]] && lvremove -q -f "${VG_SRC_NAME}/$tdev"

                    _finish
                }
                message -y
            done
        done

        return 0
    } #}}}

    if [[ $_RMODE == true && $IS_CHECKSUM == true ]]; then
        message -c -t "Validating checksums"
        {
            validate_m5dsums "$SRC" "$F_CHESUM" || { message -n && exit_ 1; }
        }
        message -y
    fi

    message -c -t "Cloning disk layout"
    {
        local f=$([[ $_RMODE == true ]] && echo $SRC/$F_PART_LIST)
        _prepare_disk #First collect what we have in our backup
        init_srcs $f
        set_src_uuids $f #Then create the filesystems and PVs

        if [[ $ENCRYPT ]]; then
            pvcreate "/dev/mapper/$LUKS_LVM_NAME"
            sleep 3
            _lvm_setup "/dev/mapper/$LUKS_LVM_NAME"
            sleep 3
        else
            disk_setup
            if [[ ${#LMBRS[@]} -gt 0 ]]; then
                _lvm_setup "$DEST"
                sleep 3
            fi
        fi

        set_dest_uuids #Now collect what we have created

        if [[ ${#SUUIDS[@]} != "${#DUUIDS[@]}" || ${#SPUUIDS[@]} != "${#DPUUIDS[@]}" || ${#SNAMES[@]} != "${#DNAMES[@]}" ]]; then
            echo >&2 "Source and destination tables for UUIDs, PARTUUIDs or NAMES did not macht. This should not happen!"
            return 1
        fi

        for ((i = 0; i < ${#SUUIDS[@]}; i++)); do SRC2DEST[${SUUIDS[$i]}]=${DUUIDS[$i]}; done
        for ((i = 0; i < ${#SPUUIDS[@]}; i++)); do PSRC2PDEST[${SPUUIDS[$i]}]=${DPUUIDS[$i]}; done
        for ((i = 0; i < ${#SNAMES[@]}; i++)); do NSRC2NDEST[${SNAMES[$i]}]=${DNAMES[$i]}; done

        [[ $_RMODE == false ]] && mounts
    }
    message -y

    #Check if destination is big enough.
    local cnt
    [[ $_RMODE == true ]] && SECTORS=$(cat $SRC/$F_SECTORS_USED)
    [[ -b $DEST ]] && cnt=$(echo $(blockdev --getsize64 /dev/loop0) / 1024 | bc)
    [[ -d $DEST ]] && cnt=$(df -k --output=avail $DEST | tail -n -1)
    ((cnt - SECTORS <= 0)) && exit_ 10 "Require $((SECTORS / 1024))M but destination is only $((cnt / 1024))M"

    if [[ $_RMODE == true ]]; then
        _from_file || return 1
    else
        _clone || return 1
    fi

    if [[ $HAS_GRUB == true ]]; then
        message -c -t "Installing Grub"
        {
            if [[ $ENCRYPT ]]; then
                crypt_setup $ENCRYPT || return 1
            else
                grub_setup || return 1
            fi
        }
        message -y
    fi
    return 0
} #}}}

Main() { #{{{
    _validate_block_device() { #{{{
        local t=$(lsblk --nodeps --noheadings -o TYPE $1)
        ! [[ $t =~ disk|loop ]] && exit_ 1 "Invalid block device. $1 is not a disk."
    } #}}}

    trap Cleanup INT TERM EXIT
    echo >$F_LOG

    exec 3>&1 4>&2
    tput sc

    #Force root
    [[ "$(id -u)" != 0 ]] && exec sudo "$0" "$@"

    hash pv && INTERACTIVE=true
    SYS_HAS_EFI=$([[ -d /sys/firmware/efi ]] && echo true || echo false)

    #Make sure BASH is the right version so we can use array references!
    v=$(echo "${BASH_VERSION%.*}" | tr -d '.')
    ((v < 43)) && exit_ 1 "ERROR: Bash version must be 4.3 or greater!"

    #Lock the script, only one instance is allowed to run at the same time!
    exec 200>"$PIDFILE"
    flock -n 200 || exit_ 1 "Another instance with PID $pid is already running!"
    pid=$$
    echo $pid 1>&200

    PKGS=(awk lvm rsync tar flock bc blockdev fdisk sfdisk)

    option=$(getopt \
        -o 'huqcxps:d:e:n:m:H:' \
        --long 'help,hostname:,encrypt-with-password:,new-vg-name:,resize-threshold:' \
        -n "$(basename "$0" \
    )" -- "$@")

    eval set -- "$option"

    while true; do
        case "$1" in
        '-h'|'--help')
            usage;
            shift 1; continue
            ;;
        '-s')
            SRC=$(readlink -m $2);
            shift 2; continue
            ;;
        '-d')
            DEST=$(readlink -m $2);
            shift 2; continue
            ;;
        '-n'|'--new-vg-name')
            VG_SRC_NAME_CLONE=$2;
            shift 2: continue
            ;;
        '-e'|'--encrypt-with-password')
            ENCRYPT=$2;
            PKGS+=(cryptsetup);
            shift 2; continue
            ;;
        '-H'|'--hostname')
            HOST_NAME=$2;
            shift 2; continue
            ;;
        '-u')
            UEFI=true;
            shift 1; continue
            ;;
        '-p')
            PVALL=true;
            shift 1; continue
            ;;
        '-q')
            exec &>/dev/null;
            shift 1; continue
            ;;
        '-c')
            IS_CHECKSUM=true;
            PKGS+=(parallel);
            shift 1; continue
            ;;
        '-x')
            export XZ_OPT=-4T0;
            PKGS+=(xz);
            shift 1; continue
            ;;
        '-m'|'--resize-threshold')
            export MIN_RESIZE="${2:-2048}";
            shift 2; continue
            ;;
		'--')
			shift; break
            ;;
        *)
            usage
            ;;
        esac
    done


    local packages=()
    #Inform about ALL missing but necessary tools.
    for c in ${PKGS[@]}; do
        hash $c 2>/dev/null || {
            case "$c" in
            lvm)
                packages+=(lvm2)
                ;;
            *)
                packages+=($c)
                ;;
            esac
            abort='exit_ 1'
        }
    done

    [[ -n $abort ]] && message -n -t "ERROR: Some packages missing. Please install packages ${packages[@]}."
    eval "$abort"

    [[ -z $SRC || -z $DEST ]] &&
        usage

    [[ -d $SRC && ! -b $DEST ]] &&
        exit_ 1 "$DEST is not a valid block device."

    [[ ! -b $SRC && -d $DEST ]] &&
        exit_ 1 "$SRC is not a valid block device."

    [[ ! -d $SRC && ! -b $SRC && -b $DEST ]] &&
        exit_ 1 "Invalid device or directory: $SRC"

    [[ -b $SRC && ! -b $DEST && ! -d $DEST ]] &&
        exit_ 1 "Invalid device or directory: $DEST"

    for d in "$SRC" "$DEST"; do
        [[ -b $d ]] && _validate_block_device $d
    done

    [[ $SRC == $DEST ]] &&
        exit_ 1 "Source and destination cannot be the same!"

    [[ $UEFI == true && $SYS_HAS_EFI == false ]] && exit_ 1 "Cannot convert to UEFI because system booted in legacy mode. Check your UEFI firmware settings!"

    [[ -n $(lsblk -no mountpoint $DEST 2>/dev/null) ]] && exit_ 1 "Invalid device condition. Some or all partitions of $DEST are mounted."

    [[ $PVALL == true && -n $ENCRYPT ]] && exit_ 1 "Encryption only supported for simple LVM setups with a single PV!"

    #Make sure source or destination folder are not mounted on the same disk to backup to or restore from.
    for d in "$SRC" "$DEST"; do
        if [[ -d $d ]]; then
            #get disk dev, e.g. /dev/sda. Not sure what to when type is vboxsf ... Ignoring errors for the moment.
            d=$(lsblk -lnpso NAME,TYPE $(mount | grep -E "$d\s" | awk '{print $1}') 2>/dev/null | grep 'disk' | awk '{print $1}')
            [[ $d == $SRC || $d == $DEST ]] && exit_ 1 "Source and destination cannot be the same!"
        fi
    done

    #Check that all expected files exists when restoring
    if [[ -d $SRC ]]; then
        [[ -s $SRC/$F_CHESUM && $IS_CHECKSUM == true ||
            -s $SRC/$F_PART_LIST &&
            -s $SRC/$F_SECTORS_SRC &&
            -s $SRC/$F_SECTORS_USED &&
            -s $SRC/$F_PART_TABLE ]] || exit_ 2 "Cannot restore dump, one or more meta files are missing or empty."
        if [[ $IS_LVM == true ]]; then
            [[ -s $SRC/$F_VGS_LIST &&
            -s $SRC/$F_LVS_LIST &&
            -s $SRC/$F_PVS_LIST ]] || exit_ 2 "Cannot restore dump, one or more meta files for LVM are missing or empty."
        fi
    fi

    VG_SRC_NAME=$(echo $(if [[ -d $SRC ]]; then cat $SRC/$F_PVS_LIST; else pvs --noheadings -o pv_name,vg_name | grep "$SRC"; fi) | awk '{print $2}' | uniq)

    if [[ -z $VG_SRC_NAME ]]; then
        while read -r e g; do
            grep -q ${SRC##*/} < <(dmsetup deps -o devname $e | sed 's/.*(\(\w*\).*/\1/g') && VG_SRC_NAME=$g
        done < <(if [[ -d $SRC ]]; then cat $SRC/$F_PVS_LIST; else pvs --noheadings -o pv_name,vg_name; fi)
    fi

    [[ -n $VG_SRC_NAME ]] && vg_disks $VG_SRC_NAME && IS_LVM=true

    [[ -z $VG_SRC_NAME_CLONE ]] && VG_SRC_NAME_CLONE=${VG_SRC_NAME}_${CLONE_DATE}

    exec > $F_LOG 2>&1

    #main
    echo_ "Backup started at $(date)"
    if [[ -b $SRC && -b $DEST ]]; then
        Clone || exit_ 1
    elif [[ -d "$SRC" && -b $DEST ]]; then
        Clone -r || exit_ 1
    elif [[ -b "$SRC" && -d $DEST ]]; then
        To_file || exit_ 6 "Destination not empty!"
    fi
    echo_ "Backup finished at $(date)"
} #}}}

Main "$@"

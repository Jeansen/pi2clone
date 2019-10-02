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

export LC_ALL=en_US.UTF-8
export LVM_SUPPRESS_FD_WARNINGS=true
export XZ_OPT= #Make sure no compression is in place, can be set with -z. See Main()

# CONSTANTS
#----------------------------------------------------------------------------------------------------------------------
declare F_SCHROOT='bcrm.tar.xz'
declare F_PART_LIST='part_list'
declare F_VGS_LIST='vgs_list'
declare F_LVS_LIST='lvs_list'
declare F_PVS_LIST='pvs_list'
declare F_SECTORS_SRC='sectors'
declare F_SECTORS_USED='sectors_used'
declare F_PART_TABLE='part_table'
declare F_CHESUM='check.md5'
declare F_LOG='/tmp/bcrm.log'

declare SCHROOT_HOME=/tmp/dbs
declare BACKUP_FOLDER=/tmp/bcrm/backup
declare SCRIPTNAME=$(basename "$0")
declare SCRIPTPATH=$(dirname "$0")
declare PIDFILE="/var/run/$SCRIPTNAME"
declare SRC_NBD=/dev/nbd0
declare DEST_NBD=/dev/nbd1
declare CLONE_DATE=$(date '+%d%m%y')
declare SNAP4CLONE='snap4clone'
declare MNTPNT=/mnt/bcrm #Do not use /tmp! It will be excluded on backups!
declare LUKS_LVM_NAME=lukslvm_$CLONE_DATE

# GLOBALS
#----------------------------------------------------------------------------------------------------------------------
declare -A CHG_SYS_FILES    #Container for system files that needed to be changed during execution
                            #Key = original file path, Value = MD5sum

declare -A MNTJRNL MOUNTS
declare -A FILESYSTEMS NAMES PARTUUIDS UUIDS TYPES PUUIDS2UUIDS DESTS
declare -A SRC2DEST PSRC2PDEST NSRC2NDEST

declare SPUUIDS=() SUUIDS=()
declare DPUUIDS=() DUUIDS=()
declare LMBRS=() SRCS=() LSRCS=() PVS=() VG_DISKS=()

# FILLED BY OR BECAUSE OF PROGRAM ARGUMENTS
#----------------------------------------------------------------------------------------------------------------------
declare PKGS=() #Will be filled with a list of packages that will be needed, depending on given arguments

declare DEST_IMG=""
declare IMG_TYPE=""
declare IMG_SIZE=""
declare SRC=""
declare DEST=""
declare VG_SRC_NAME_CLONE=""
declare ENCRYPT_PWD=""
declare HOST_NAME=""
declare LVM_EXPAND="" #Name of the LV to expand.

declare UEFI=false
declare NO_SWAP=false
declare CREATE_LOOP_DEV=false
declare PVALL=false
declare SPLIT=false
declare IS_CHECKSUM=false
declare SCHROOT=false

declare MIN_RESIZE=2048 #In 1M units
declare SWAP_SIZE=0
declare BOOT_SIZE=0
declare LVM_EXPAND_BY=0 #How much % of free space to use from a VG, e.g. when a dest disk is larger than a src disk.

# CHECKS FILLED IN MAIN
#----------------------------------------------------------------------------------------------------------------------
declare VG_SRC_NAME=""

declare INTERACTIVE=false
declare HAS_GRUB=false
declare HAS_EFI=false     #If the cloned system is UEFI enabled
declare SYS_HAS_EFI=false #If the currently running system has UEFI
declare IS_LVM=false

declare EXIT=0
declare SECTORS=0

# DEBUG ONLY
#----------------------------------------------------------------------------------------------------------------------

printarr() { #{{{
    declare -n __p="$1"
    for k in "${!__p[@]}"; do printf "%s=%s\n" "$k" "${__p[$k]}"; done
} #}}}

#----------------------------------------------------------------------------------------------------------------------
# PRIVATE - only used by PUBLIC functions
#----------------------------------------------------------------------------------------------------------------------

#UNUSED
is_partition() { #{{{
    read -r name parttype type fstype <<<$(lsblk -Ppo NAME,PARTTYPE,TYPE,FSTYPE "$1" | grep "$2")
    eval "$name" "$parttype" "$type" "$fstype"
    [[ $PARTTYPE == 0x5 || $TYPE == disk || $TYPE == crypt || $FSTYPE == crypto_LUKS ]] && return 0
    return 1
} #}}}

# By convention methods ending with a '_' wrap shell functions or commands with the same name.

echo_() { #{{{
    exec 1>&3 #restore stdout
    echo "$1"
    exec 3>&1         #save stdout
    exec >$F_LOG 2>&1 #again all to the log
} #}}}

mount_() { #{{{
    local cmd="mount"

    local OPTIND
    local src="$1"
    local path="${MNTPNT}/$src"
    shift

    while getopts ':p:t:b' option; do
        case "$option" in
        t)
            cmd+=" -t $OPTARG"
            ;;
        p)
            path="$OPTARG"
            ;;
        b)
            cmd+=" --bind"
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

    [[ ! -d "$path" ]] && mkdir -p "$path"
    { $cmd "$src" "$path" && MNTJRNL["$src"]="$path"; } || return 1
} #}}}

umount_() { #{{{
    local OPTIND
    local cmd="umount -l"
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

# $1: <exit code>
# $2: <message>
exit_() { #{{{
    [[ -n $2 ]] && message -n -t "$2"
    EXIT=${1:-0}
    Cleanup
} #}}}

#----------------------------------------------------------------------------------------------------------------------

logmsg() { #{{{
    printf "===> $1"
} #}}}

usage() { #{{{
    local -A usage

    printf "\nUsage: $(basename $0) -s <source> -d <destination> [options]\n\n"

    printf "\nOPTIONS"
    printf "\n-------\n\n"
    printf "  %-3s %-30s %s\n"   "-s," "--source"                "The source device or folder to clone or restore from"
    printf "  %-3s %-30s %s\n"   "-d," "--destination"           "The destination device or folder to clone or backup to"
    printf "  %-3s %-30s %s\n"   "   " "--source-image"          "Use the given image as source in the form of <path>:<type>"
    printf "  %-3s %-30s %s\n"   "   " ""                        "For example: '/path/to/file.vdi:vdi'. See below for supported types."
    printf "  %-3s %-30s %s\n"   "   " "--destination-image"     "Use the given image as destination in the form of <path>:<type>[:<virtual-size>]"
    printf "  %-3s %-30s %s\n"   "   " ""                        "For instance: '/path/to/file.img:raw:20G'"
    printf "  %-3s %-30s %s\n"   "   " ""                        "If you omit the file, it must exists. Otherwise it will be created"
    printf "  %-3s %-30s %s\n"   "-c," "--check"                 "Create/Validate checksums"
    printf "  %-3s %-30s %s\n"   "-z," "--compress"              "Use compression (compression ratio is about 1:3, but very slow!)"
    printf "  %-3s %-30s %s\n"   "   " "--split"                 "Split backup into chunks of 1G files"
    printf "  %-3s %-30s %s\n"   "-H," "--hostname"              "Set hostname"
    printf "  %-3s %-30s %s\n"   "   " "--remove-pkgs"           "Remove the given list of whitespace-separatedpackages as a final step."
    printf "  %-3s %-30s %s\n"   "   " ""                        "The whole list must be enclosed in \"\""
    printf "  %-3s %-30s %s\n"   "-n," "--new-vg-name"           "LVM only: Define new volume group name"
    printf "  %-3s %-30s %s\n"   "-e," "--encrypt-with-password" "LVM only: Create encrypted disk with supplied passphrase"
    printf "  %-3s %-30s %s\n"   "-p," "--use-all-pvs"           "LVM only: Use all disks found on destination as PVs for VG"
    printf "  %-3s %-30s %s\n"   "   " "--lvm-expand"            "LVM only: Have the given LV use the remaining free space."
    printf "  %-3s %-30s %s\n"   "   " ""                        "An optional percentage can be supplied, e.g. 'root:80'"
    printf "  %-3s %-30s %s\n"   "   " ""                        "Which would add 80% of the remaining free space in a VG to this LV"
    printf "  %-3s %-30s %s\n"   "-u," "--make-uefi"             "Convert to UEFI"
    printf "  %-3s %-30s %s\n"   "-w," "--swap-size"             "Swap partition size. May be zero to remove any swap partition."
    printf "  %-3s %-30s %s\n"   "-m," "--resize-threshold"      "Do not resize partitions smaller than <size> (default 2048M)"
    printf "  %-3s %-30s %s\n"   "   " "--schroot"               "Run in a secure chroot environment with a fixed and tested tool chain"
    printf "  %-3s %-30s %s\n"   "-q," "--quiet"                 "Quiet, do not show any output"
    printf "  %-3s %-30s %s\n"   "-h," "--help"                  "Show this help text"


    printf "\n\nADVANCED OPTIONS"
    printf "\n----------------\n\n"
    printf "  %-3s %-30s %s\n"   "-b," "--boot-size"             "Boot partition size. For instance: 200M or 4G."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Be careful, the  script only checks for the bootable flag,"
    printf "  %-3s %-30s %s\n"   "   " ""                        "Only use with a dedicated /boot partition"

    printf "\n\nADDITIONAL NOTES"
    printf "\n----------------\n"
    printf "\nSize values must be postfixed with a size indcator, e.g: 200M or 4G. The following indicators are valid:\n\n"
    printf "  %-3s %s\n"       "K"    "[kilobytes]"
    printf "  %-3s %s\n"       "M"    "[megabytes]"
    printf "  %-3s %s\n"       "G"    "[gigabytes]"
    printf "  %-3s %s\n"       "T"    "[terabytes]"

    printf "\nWhen using virtual images you always have to provide the image type. Currently the following image types are supported:\n\n"
    printf "  %-7s %s\n"       "raw"    "Plain binary"
    printf "  %-7s %s\n"       "vdi"    "Virtual Box"
    printf "  %-7s %s\n"       "qcow2"  "QEMU/KVM"
    printf "  %-7s %s\n"       "vmdk"   "VMware"
    printf "  %-7s %s\n\n\n"   "vhdx"   "Hyper-V"

    exit_ 1
} #}}}

# -t: <text>
# Flags defining the type of text and symbol to be displayed
# -c = CURRENT (➤)
# -y = SUCCESS (✔)
# -n = FAIL (✘)
# -i = INFO (i)
# -u: Update a message indicator, e.g. from status CURRENT to SUCCESS.
message() { #{{{
    local OPTIND
    local status
    local text=
    local update=false
    clor_cancel=$(tput bold; tput setaf 3)
    clr_yes=$(tput setaf 2)
    clor_no=$(tput setaf 1)
    clor_info=$(tput setaf 6)
    clr_rmso=$(tput sgr0)

    exec 1>&3 #restore stdout
    #prepare
    while getopts ':inucyt:' option; do
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
        i)
            status="${clor_info}i${clr_rmso}"
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
        [[ -n $status ]] && echo -e -n "[ $status ] "
        [[ -n $text ]] &&
            text=$(echo "$text" | sed -e 's/^\s*//; 2,$ s/^/      /') &&
            echo -e -n "$text" && tput el
        echo
    }
    [[ $update == true ]] && tput rc
    tput civis
    exec 3>&1          #save stdout
    exec >>$F_LOG 2>&1 #again all to the log
} #}}}

# $1: <mount point>
# $2: "<dest-dev>"
# $3: ["<list of packages to install>"]
pkg_install() { #{{{
    chroot "$1" sh -c "
        apt-get install -y $3 &&
        grub-install $2 &&
        update-grub &&
        update-initramfs -u -k all" || return 1
} #}}}

# $1: <mount point>
# $2: ["<list of packages to install>"]
pkg_remove() { #{{{
    chroot "$1" sh -c "apt-get remove -y $2" || return 1
} #}}}

# $1: <src-dev>
# $2: <dest-dev>
# $3: <file with partition table dump>
expand_disk() { #{{{
    local size new_size
    local swap_size=0
    local src_size=$(if [[ -d $1 ]]; then cat "$1/$F_SECTORS_SRC"; else blockdev --getsz "$1"; fi)
    local dest_size=$(blockdev --getsz "$2")
    local pdata=$(if [[ -f "$3" ]]; then cat "$3"; else echo "$3"; fi)
    local boot_size=$(echo "$pdata" | grep "$BOOT_PART" | sed -E 's/.*size=\s*([0-9]*).*/\1/')

    if [[ -n $SWAP_PART ]]; then
        #Substract the swap partition size
        swap_size=$(echo "$pdata" | grep "$SWAP_PART" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
        src_size=$((src_size - swap_size))
    fi

    if [[ $SWAP_SIZE > 0 ]]; then
        local swp=$(to_sector ${SWAP_SIZE}K)
        dest_size=$((dest_size - swp))
    else
        dest_size=$((dest_size - swap_size))
    fi

    if [[ $BOOT_SIZE > 0 ]]; then
        local bs=$(to_sector ${BOOT_SIZE}K)
        src_size=$((src_size - boot_size))
        dest_size=$((dest_size - bs))
    fi

    local expand_factor=$(echo "scale=4; $dest_size / $src_size" | bc)

    if [[ $NO_SWAP == true && -n $SWAP_PART ]]; then
        local swap_part=${SWAP_PART////\\/} #Escape for sed interpolation
        pdata=$(echo "$pdata" | sed "/$swap_part/d")
    fi

    while read -r e; do
        size=
        new_size=

        if [[ $e =~ ^/ ]]; then
            echo "$e" | grep -qE 'size=\s*([0-9])' && size=$(echo "$e" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
        fi

        if [[ -n "$size" ]]; then
            if [[ -n $SWAP_PART && $e =~ $SWAP_PART ]]; then
                if [[ $SWAP_SIZE > 0 ]]; then
                    size=$(echo "$e" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
                    new_size=$(to_sector ${SWAP_SIZE}K)
                    pdata=$(sed "s/$size/${new_size}/" < <(echo "$pdata"))
                fi
            elif [[ -n $BOOT_PART && $e =~ $BOOT_PART ]]; then
                if [[ $BOOT_SIZE > 0 ]]; then
                    size=$(echo "$e" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
                    new_size=$(to_sector ${BOOT_SIZE}K)
                    pdata=$(sed "s/$size/${new_size}/" < <(echo "$pdata"))
                fi
            else
                [[ $(sector_to_mbyte $size) -le "$MIN_RESIZE" ]] && continue #MIN_RESIZE is in MB
                new_size=$(echo "scale=4; $size * $expand_factor" | bc)
                pdata=$(sed "s/$size/${new_size%%.*}/" < <(echo "$pdata"))
            fi
        fi

    done < <(echo "$pdata")

    #Remove fixed offsets and only apply size values. We assume the extended partition ist last!
    pdata=$(sed 's/start=\s*\w*,//g' < <(echo "$pdata"))
    #When a field is absent or empty the default value of size indicates "as much as asossible";
    #Therefore we remove the size for extended partitions
    pdata=$(sed '/type=5/ s/size=\s*\w*,//' < <(echo "$pdata"))
    #and the last partition, if it is not swap or swap should be erased.
    local last_line=$(echo "$pdata" | tail -1 | sed -n -e '$ ,$p')
    if [[ $NO_SWAP == true && $last_line =~ $swap_part || ! $last_line =~ $SWAP_PART ]]; then
        pdata=$(sed '$ s/size=\s*\w*,//g' < <(echo "$pdata"))
    fi

    #Finally remove some headers
    pdata=$(sed '/last-lba:/d' < <(echo "$pdata"))

    #return
    echo "$pdata"
} #}}}

# $1: <dest-dev>
mbr2gpt() { #{{{
    local efisysid='C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
    local dest="$1"
    local overlap=$(echo q | gdisk "$dest" | grep -P '\d*\s*blocks!' | awk '{print $1}')
    local pdata=$(sfdisk -d "$dest")

    if [[ $overlap > 0 ]]; then
        local sectors=$(echo "$pdata" | tail -n 1 | grep -o -P 'size=\s*(\d*)' | awk '{print $2}')
        flock "$dest" sfdisk "$dest" < <(echo "$pdata" | sed -e "$ s/$sectors/$((sectors - overlap))/")
    fi

    blockdev --rereadpt $dest && udevadm settle
    flock $dest sgdisk -z "$dest"
    flock $dest sgdisk -g "$dest"
    blockdev --rereadpt $dest && udevadm settle

    local pdata=$(sfdisk -d "$dest")
    local fstsctr=$(echo "$pdata" | grep -o -P 'size=\s*(\d*)' | awk '{print $2}' | head -n 1)
    pdata=$(echo "$pdata" | sed -e "s/$fstsctr/$((fstsctr - 1024000))/")
    pdata=$(echo "$pdata" | grep 'size=' | sed -e 's/^[^,]*,//; s/uuid=[a-Z0-9-]*,\{,1\}//')
    pdata=$(echo -e "size=1024000, type=${efisysid}\n${pdata}")
    flock "$dest" sfdisk "$dest" < <(echo "$pdata")
    blockdev --rereadpt $dest && udevadm settle
} #}}}

# $1: <mount point>
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

mounts() { #{{{
    for x in "${SRCS[@]}" "${LSRCS[@]}"; do
        local sdev=$x
        local sid=${UUIDS[$sdev]}

        mkdir -p "${MNTPNT}/$sdev"

        mount_ "$sdev"

        f[0]='cat ${MNTPNT}/$sdev/etc/fstab | grep "^UUID" | sed -e "s/UUID=//" | tr -s " " | cut -d " " -f1,2'
        f[1]='cat ${MNTPNT}/$sdev/etc/fstab | grep "^PARTUUID" | sed -e "s/PARTUUID=//" | tr -s " " | cut -d " " -f1,2'
        f[2]='cat ${MNTPNT}/$sdev/etc/fstab | grep "^/" | tr -s " " | cut -d " " -f1,2'

        if [[ -f ${MNTPNT}/$sdev/etc/fstab ]]; then
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

# $1: <password>
# $2: <dest-dev>
# $3: <luks lvm name>
encrypt() { #{{{
    local passwd="$1"
    local dest="$2"
    local name="$3"

    { echo ';' | sfdisk "$dest" && sfdisk -Vq; } || return 1 #delete all partitions and create one for the whole disk.
    sleep 3
    ENCRYPT_PART=$(sfdisk -qlo device "$dest" | tail -n 1)
    echo -n "$passwd" | cryptsetup luksFormat "$ENCRYPT_PART" -
    echo -n "$passwd" | cryptsetup open "$ENCRYPT_PART" "$name" --type luks -
} #}}}

#----------------------------------------------------------------------------------------------------------------------
# $1: <vg-name>
# $2: <src-dev>
# $3: <dest-dev>
vg_extend() { #{{{
    local vg_name="$1"
    local src="$2"
    local dest="$3"
    PVS=()

    if [[ -d $src ]]; then
        src=$(df -P "$src" | tail -1 | awk '{print $1}')
    fi

    while read -r e; do
        read -r name type <<<"$e"
        [[ -n $(lsblk -no mountpoint "$name" 2>/dev/null) ]] && continue
        echo ';' | flock "$name" sfdisk -q "$name" && sfdisk "$name" -Vq
        local part=$(lsblk "$name" -lnpo name,type | grep part | awk '{print $1}')
        pvcreate -ff "$part" && vgextend "$vg_name" "$part"
        PVS+=("$part")
    done < <(lsblk -po name,type | grep disk | grep -Ev "$dest|$src")
} #}}}

# $1: <vg-name>
# $2: <Ref. to GLOABAL array holding VG disks>
vg_disks() { #{{{
    local name=$1
    declare -n disks=$2

    for f in $(pvs --no-headings -o pv_name,lv_dm_path | grep -E "${name}\-\w+" | awk '{print $1}' | sort -u); do
        disks+=($(lsblk -pnls $f | grep disk | awk '{print $1}'))
    done
} #}}}

# $1: <dest-dev>
# $2: <checksum file>
create_m5dsums() { #{{{
    local dest="$1"
    local file="$2"
    # find "$1" -type f \! -name '*.md5' -print0 | xargs -0 md5sum -b > "$1/$2"
    pushd "$dest" || return 1
    find . -type f \! -name '*.md5' -print0 | parallel --no-notice -0 md5sum -b >"$file"
    popd || return 1
    validate_m5dsums "$dest" "$file" || return 1
} #}}}

# $1: <src-dev>
# $2: <checksum file>
validate_m5dsums() { #{{{
    local src="$1"
    local file="$2"
    pushd "$src" || return 1
    md5sum -c "$file" --quiet || return 1
    popd || return 1
} #}}}

#----------------------------------------------------------------------------------------------------------------------

# $1: <Ref. DPUUIDS>
# $2: <Ref. DUUIDS>
# $3: <Ref. DNAMES>
# $4: <Ref. DESTS>
set_dest_uuids() { #{{{
    declare -n dpuuids="$1"
    declare -n duuids="$2"
    declare -n dnames="$3"
    declare -n dests="$4"

    [[ $IS_LVM == true ]] && vgchange -an $VG_SRC_NAME_CLONE
    blockdev --rereadpt $DEST && udevadm settle
    [[ $IS_LVM == true ]] && vgchange -ay $VG_SRC_NAME_CLONE

    udevadm settle

    while read -r e; do
        read -r name kdev fstype uuid puuid type parttype mountpoint <<<"$e"
        eval declare "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $FSTYPE == swap ]] && continue
        [[ $UEFI == true && $PARTTYPE == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] && continue
        [[ $PARTTYPE == 0x5 || $TYPE == crypt || $FSTYPE == crypto_LUKS || $FSTYPE == LVM2_member ]] && continue
        [[ -n $UUID ]] && dests[$UUID]="$NAME"
        [[ -n $PARTUUID ]] && dests[$PARTUUID]="$NAME"
        [[ ${PVS[@]} =~ $NAME ]] && continue
        dpuuids+=($PARTUUID)
        duuids+=($UUID)
        dnames+=($NAME)
    done < <(lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" $([[ $PVALL == true ]] && echo ${PVS[@]}) | sort -ru | grep -vE '\bdisk|\bUUID="".*\bPARTUUID=""')
} #}}}

# $1: <Ref. SPUUIDS>
# $2: <Ref. SUUIDS>
# $3: <Ref. SNAMES>
# $4: <Ref. LMBRS>
# $5: <Ref. SECTORS_USED>
# $6: <File with lsblk dump>
set_src_uuids() { #{{{
    declare -n spuuids="$1"
    declare -n suuids="$2"
    declare -n snames="$3"
    declare -n lmbrs="$4"
    declare -n sectors="$5"
    declare file="$6"

    _count() { #{{{
        if [[ $SWAP_SIZE -eq 0 ]]; then
            local size=$(swapon --show=size,name --bytes --noheadings | grep $1 | awk '{print $1}') #no swap = 0
            size=$(to_kbyte ${size:-0})
        fi
        sectors=$(( $size + $sectors + $(df -k --output=used $1 | tail -n -1) ))
    } #}}}

    local n=0
    local plist

    if [[ -n $file ]]; then
        plist=$(cat "$file")
    else
        plist=$(lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" ${VG_DISKS[@]})
    fi

    while read -r e; do
        read -r name kdev fstype uuid puuid type parttype mountpoint <<<"$e"
        eval declare "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"

        [[ -b $SRC ]] && _count "$KNAME"
        [[ $FSTYPE == swap ]] && continue
        [[ ($TYPE == part && $FSTYPE == LVM2_member || $FSTYPE == crypto_LUKS) && $ENCRYPT_PWD ]] && continue
        [[ $FSTYPE == crypto_LUKS ]] && FSTYPE=ext4 && lmbrs[$n]="$UUID" #TODO I think that is wrong!
        [[ $PARTTYPE == 0x5 || $TYPE == crypt || $FSTYPE == crypto_LUKS ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $FSTYPE == LVM2_member ]] && lmbrs[$n]="$UUID" && n=$((n + 1)) && continue
        spuuids+=($PARTUUID)
        suuids+=($UUID)
        snames+=($NAME)
    done < <(echo "$plist" | sort -ru | grep -v 'disk')

    [[ $SWAP_SIZE > 0 ]] && sectors=$((sectors + SWAP_SIZE))
} #}}}

# $1: <Ref. UUIDS>
# $2: <Ref. SRCS>
# $3: <Ref. LSRCS>
# $4: <Ref. PARTUUIDS>
# $5: <Ref. PUUIDS2UUIDS>
# $6: <Ref. TYPES>
# $7: <Ref. NAMES>
# $8: <Ref. FILESYSTEMS>
# $9: <File with lsblk dump>
init_srcs() { #{{{
    declare -n uuids="$1"
    declare -n srcs="$2"
    declare -n lsrcs="$3"
    declare -n partuuids="$4"
    declare -n puuids2uuids="$5"
    declare -n types="$6"
    declare -n names="$7"
    declare -n filesystems="$8"
    declare file="$9"

    while read -r e; do
        read -r name kdev fstype uuid puuid type parttype mountpoint <<<"$e"
        eval declare "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $FSTYPE == LVM2_member || $FSTYPE == swap || $TYPE == crypt || $FSTYPE == crypto_LUKS ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $TYPE == lvm && -z $file ]] && lsrcs+=($NAME)
        [[ $TYPE == part ]] && srcs+=($NAME)
        filesystems[$NAME]="$FSTYPE"
        partuuids[$NAME]="$PARTUUID"
        uuids[$NAME]="$UUID"
        types[$NAME]="$TYPE"
        [[ -n $UUID ]] && names[$UUID]=$NAME
        [[ -n $PARTUUID ]] && names[$PARTUUID]=$NAME
        [[ -n $UUID && -n $PARTUUID ]] && puuids2uuids[$PARTUUID]="$UUID"
    done < <( if [[ -n $file ]]; then cat "$file";
              else lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" ${VG_DISKS[@]} | sort -ru | grep -v 'disk';
    fi)
} #}}}

#----------------------------------------------------------------------------------------------------------------------

# $1: <file with lsblk dump>
# $2: <uefi enabled> true|false
# $3: <src-dev>
# $4: <dest-dev>
disk_setup() { #{{{
    declare parts=() pvs_parts=()
    local file="$1"
    local uefi="$2"
    local src="$3"
    local dest="$4"

    local plist
    if [[ -n $file ]]; then
        plist=$(cat "$file" |
            grep -vE 'PARTTYPE="0x5"' |
            grep -vE 'TYPE="disk"' |
            sort -ru)
    else
        plist=$(
            lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE "$src" |
            grep -vE 'PARTTYPE="0x5"' |
            sort -ru
        ) #only partitions
    fi

    if [[ $uefi == true && $n -eq 0 ]]; then
        parts[$n]=vfat
        n=$((n + 1))
    fi

    #Collect all source paritions and their file systems
    _scan_src_parts() { #{{{
        local n=0

        while read -r e; do
            read -r name kname fstype uuid partuuid type parttype <<<"$e"
            eval "$name" "$kname" "$fstype" "$uuid" "$partuuid" "$type" "$parttype"

            [[ $NO_SWAP == true && $FSTYPE == swap ]] && continue

            if [[ $TYPE == part && $FSTYPE != LVM2_member && $FSTYPE != crypto_LUKS ]]; then
                parts[$n]=$FSTYPE
                n=$((n + 1))
            elif [[ $TYPE == part && $FSTYPE == LVM2_member ]]; then
                pvs_parts[$n]=$FSTYPE
                n=$((n + 1))
            fi
        done < <(echo "$plist")

    } #}}}

    #Create file systems (including swap) or pvs volumes.
    _create_dests() { #{{{
        local n=0
        local plist=$(
            lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE "$dest" |
            grep -vE 'PARTTYPE="0x5"' |
            grep -vE 'TYPE="disk"' |
            sort -ru
        ) #only partitions

        while read -r e; do
            read -r name fstype uuid type <<<"$e"
            eval "$name" "$kname" "$fstype" "$uuid" "$partuuid" "$type" "$parttype"

            if [[ -n ${parts[$n]} && ${parts[$n]} == swap ]]; then
                mkswap -f "$NAME"
            elif [[ -n ${parts[$n]} ]]; then
                mkfs -t "${parts[$n]}" "$NAME"
            elif [[ -n ${pvs_parts[$n]} ]]; then
                pvcreate -ff "$NAME"
            fi
            n=$((n + 1))
        done < <(echo "$plist")
        blockdev --rereadpt $DEST && udevadm settle
    } #}}}

    _scan_src_parts
    _create_dests

    sleep 3
} #}}}

# $1: <Ref.>
boot_setup() { #{{{
    declare -n sd="$1"

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
                "${MNTPNT}/$d/${path[0]}" "${MNTPNT}/$d/${path[1]}" \
                "${MNTPNT}/$d/${path[2]}" "${MNTPNT}/$d/${path[3]}" \
                2>/dev/null

            #Resume file might be wrong, so we just set it explicitely
            if [[ -e ${MNTPNT}/$d/${path[4]} ]]; then
                local uuid fstype
                read -r uuid fstype <<<$(lsblk -Ppo uuid,fstype "$DEST" | grep 'swap')
                uuid=${uuid//\"/} #get rid of ""
                eval sed -i -E '/RESUME=none/!s/^RESUME=.*/RESUME=$uuid/i' "${MNTPNT}/$d/${path[4]}"
            fi
            if [[ -e ${MNTPNT}/$d/${path[1]} ]]; then
                #Make sure swap is set correctly.
                local uuid fstype
                read -r fstype uuid <<<$(lsblk -plo fstype,uuid $DEST ${PVS[@]} | grep '^swap')
                sed -i -E "/\bswap/ s/[^ ]*/UUID=$uuid/" "${MNTPNT}/$d/${path[1]}"
            fi
        done
    done
} #}}}

# $1: <destination to mount>
# $2: <has efi> true|false
# $3: <add efi partition to fstab> true|false
# $4: <dest-dev>
grub_setup() { #{{{
    local d="$1"
    local has_efi=$2
    local uefi=$3
    local dest="$4"
    local mp="${MNTPNT}/$d"

    mount "$d" "$mp"

    sed -i -E "/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*||" "$mp/etc/default/grub"
    sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=n/' "$mp/etc/default/grub"
    sed -i 's/^/#/' "$mp/etc/crypttab"

    for f in sys dev dev/pts proc run; do
        mount --bind "/$f" "$mp/$f"
    done

    IFS=$'\n'
    local mounts=($(sort <<<"${!MOUNTS[*]}"))
    unset IFS

    for m in ${mounts[*]}; do
        [[ "$m" == / ]] && continue
        if [[ "$m" =~ ^/ ]]; then
            mount_ "${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}" -p "$mp/$m"
        fi
    done

    if [[ $uefi == true && $has_efi == true ]]; then
        while read -r e; do
            read -r name uuid parttype <<<"$e"
            eval "$name" "$uuid" "$parttype"
        done < <(lsblk -pPo name,uuid,parttype "$dest" | grep -i 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b')

        echo -e "${uuid}\t/boot/efi\tvfat\tumask=0077\t0\t1" >>"$mp/etc/fstab"
        mkdir -p "$mp/boot/efi" && mount "$uuid" "$mp/boot/efi"
    fi

    if [[ $has_efi == true ]]; then
        local apt_pkgs="grub-efi-amd64"
    else
        local apt_pkgs="binutils"
    fi

    pkg_remove "$mp" "$REMOVE_PKGS" || return 1
    pkg_install "$mp" "$dest" || return 1

    create_rclocal "$mp"
    umount -Rl "$mp"
    return 0
} #}}}

# $1: <password>
# $2: <destination to mount>
# $3: <dest-dev>
# $4: <luks_lvm_name>
# $5: <encrypt_part>
crypt_setup() { #{{{
    local passwd="$1"
    local d="$2"
    local dest="$3"
    local luks_lvm_name="$4"
    local encrypt_part="$5"
    local mp="${MNTPNT}/$d"

    mount "$d" "$mp"

    for f in sys dev dev/pts proc run; do
        mount --bind "/$f" "$mp/$f"
    done

    for m in "${!MOUNTS[@]}"; do
        [[ "$m" == / ]] && continue
        [[ "$m" =~ ^/ ]] && mount "${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}" "$mp/$m"
    done

    printf '%s' '#!/bin/sh
    exec /bin/cat /${1}' >"$mp/home/dummy" && chmod +x "$mp/home/dummy"

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

	exit 0' >"$mp/etc/initramfs-tools/hooks/lukslvm" && chmod +x "$mp/etc/initramfs-tools/hooks/lukslvm"

    dd oflag=direct bs=512 count=4 if=/dev/urandom of="$mp/crypto_keyfile.bin"
    echo -n "$1" | cryptsetup luksAddKey "$encrypt_part" "$mp/crypto_keyfile.bin" -
    chmod 000 "$mp/crypto_keyfile.bin"

    # local dev=$(lsblk -asno pkname /dev/mapper/$luks_lvm_name | head -n 1)
    echo "$luks_lvm_name UUID=$(cryptsetup luksUUID "$encrypt_part") /crypto_keyfile.bin luks,keyscript=/home/dummy" >"$mp/etc/crypttab"

    sed -i -E "/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*[^\"]||" "$mp/etc/default/grub"

    grep -q 'GRUB_CMDLINE_LINUX' "$mp/etc/default/grub" &&
        sed -i -E "/GRUB_CMDLINE_LINUX=/ s|\"(.*)\"|\"cryptdevice=UUID=$(cryptsetup luksUUID $encrypt_part):$luks_lvm_name \1\"|" "$mp/etc/default/grub" ||
        echo "GRUB_CMDLINE_LINUX=cryptdevice=UUID=$(cryptsetup luksUUID $encrypt_part):$luks_lvm_name" >>"$mp/etc/default/grub"

    grep -q 'GRUB_ENABLE_CRYPTODISK' "$mp/etc/default/grub" &&
        sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=y/' "$mp/etc/default/grub" ||
        echo "GRUB_ENABLE_CRYPTODISK=y" >>"$mp/etc/default/grub"

    pkg_remove "$mp" "$REMOVE_PKGS" || return 1
    pkg_install "$mp" "$dest" "lvm2 cryptsetup keyutils binutils grub2-common grub-pc-bin" || return 1
    create_rclocal "$mp"
    umount -lR "$mp"
} #}}}

# $1: <full path>
# $2: <type>
# $3: <size>
create_image() { #{{{
    local img="$1"
    local type="$2"
    local size="$3"

    qemu-img create -f "$type" "$img" "$size" || return 1
} #}}}

#----------------------------------------------------------------------------------------------------------------------

# $1: <bytes>
to_readable_size() { #{{{
    local size=$1
    local dimension=B

    for d in K M G T P; do
        if (($(echo "scale=2; $size / 2 ^ 10 >= 1" | bc -l))); then
            size=$(echo "scale=2; $size / 2 ^ 10" | bc)
            dimension=$d
        else
            echo "${size}${dimension}"
            return 0
        fi
    done

    echo "${size}${dimension}"
    return 0
} #}}}

# $1: <number+K|M|G|T>
to_byte() { #{{{
    local p=$1
    [[ $p =~ ^[0-9]+K ]] && echo $((${p%[a-zA-Z]} * 2 ** 10))
    [[ $p =~ ^[0-9]+M ]] && echo $((${p%[a-zA-Z]} * 2 ** 20))
    [[ $p =~ ^[0-9]+G ]] && echo $((${p%[a-zA-Z]} * 2 ** 30))
    [[ $p =~ ^[0-9]+T ]] && echo $((${p%[a-zA-Z]} * 2 ** 40))
    return 0
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_kbyte() { #{{{
    local v=$1
    validate_size $1 && v=$(to_byte $1)
    echo $((v / 2 ** 10))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_mbyte() { #{{{
    local v=$1
    validate_size $1 && v=$(to_byte $1)
    echo $((v / 2 ** 20))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_gbyte() { #{{{
    local v=$1
    validate_size $1 && v=$(to_byte $1)
    echo $((v / 2 ** 30))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_tbyte() { #{{{
    local v=$1
    validate_size $1 && v=$(to_byte $1)
    echo $((v / 2 ** 40))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
validate_size() { #{{{
    [[ $1 =~ ^[0-9]+(K|M|G|T) ]] && return 0 || return 1
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_sector() { #{{{
    local v=$1
    validate_size $1 && v=$(to_byte $1)
    echo $((v / 512))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_kbyte() { #{{{
    echo $(($1 / 2 * 2 ** 10))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_mbyte() { #{{{
    echo $(($1 / 2 * 2 ** 20))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_gbyte() { #{{{
    echo $(($1 / 2 * 2 ** 30))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_tbyte() { #{{{
    echo $(($1 / 2 * 2 ** 40))
} #}}}

#----------------------------------------------------------------------------------------------------------------------
# PUBLIC - To be used in Main() only
#----------------------------------------------------------------------------------------------------------------------

Cleanup() { #{{{
    {
        umount_
        rm -rf "$SCHROOT_HOME" #TODO add option to overwrite
        [[ $VG_SRC_NAME_CLONE ]] && vgchange -an "$VG_SRC_NAME_CLONE"
        [[ $ENCRYPT_PWD ]] && cryptsetup close "/dev/mapper/$LUKS_LVM_NAME"
        [[ $CREATE_LOOP_DEV == true ]] && qemu-nbd -d $DEST_NBD
        [[ $CREATE_LOOP_DEV == true ]] && qemu-nbd -d $SRC_NBD
        lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE"
    } &>/dev/null

    if [[ -t 3 ]]; then
        exec 1>&3 2>&4
        tput cnorm
    fi

    #Check if system files have been changed for execution and restore
    local failed=()
    for f in "${!CHG_SYS_FILES[@]}"; do
        if [[ ${CHG_SYS_FILES["$f"]} == $(md5sum "${BACKUP_FOLDER}/${f}" | awk '{print $1}') ]]; then
            cp "${BACKUP_FOLDER}/${f}" "$f"
        else
            failed+=("$f")
        fi
        [[ ${#failed[@]} -gt 0 ]] && message -n -t "Backups of original file(s) ${f[*]} changed. Will not restore. Check ${BACKUP_FOLDER}."
    done

    exec 200>&-
    exit $EXIT #Make sure we really exit the script!
} #}}}

To_file() { #{{{
    #TODO move messages here
    lm=(
        "Saving disk layout"
    )
    if [ -n "$(ls -A "$DEST")" ]; then return 1; fi

    pushd "$DEST" >/dev/null || return 1

    _save_disk_layout() { #{{{
        local snp=$(sudo lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role | grep 'snap' | sed -e 's/^\s*//' | awk '{print $1}')
        [[ -z $snp ]] && snp="NOSNAPSHOT"

        {
            pvs --noheadings -o pv_name,vg_name,lv_active | grep 'active$' | sort -u | sed -e 's/active$//;s/^\s*//' >$F_PVS_LIST
            vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free,lv_active | grep 'active$' | sort -u | sed -e 's/active$//;s/^\s*//' >$F_VGS_LIST
            lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role,lv_dm_path | grep -v 'snap' | grep 'active public.*' | sed -e 's/^\s*//; s/\s*$//' >$F_LVS_LIST
            blockdev --getsz "$SRC" >"$F_SECTORS_SRC"
            sfdisk -d "$SRC" >"$F_PART_TABLE"
        }

        sleep 3 #IMPORTANT !!! So changes by sfdisk can settle.
        #Otherwise resultes from lsblk might still show old values!
        lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" | sort -ru | grep -v "$snp" >"$F_PART_LIST"
    } #}}}

    message -c -t "Creating backup of disk layout"
    {
        logmsg ${lm[0]} && _save_disk_layout
        init_srcs "UUIDS" "SRCS" "LSRCS" "PARTUUIDS" "PUUIDS2UUIDS" "TYPES" "NAMES" "FILESYSTEMS"
        set_src_uuids "SPUUIDS" "SUUIDS" "SNAMES" "LMBRS" "SECTORS_USED"
        mounts
    }
    message -y

    local VG_SRC_NAME=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | awk '{print $2}')
    if [[ -z $VG_SRC_NAME ]]; then
        while read -r e g; do
            grep -q "${SRC##*/}" < <(dmsetup deps -o devname "$e" | sed 's/.*(\(\w*\).*/\1/g') && VG_SRC_NAME="$g"
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
            local mount=${MOUNTS[$sid]:-${MOUNTS[$spid]}}

            local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | awk '{print $1}')
            local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${VG_SRC_NAME}" | sort -ru | awk '{print $2}')

            [[ -z ${FILESYSTEMS[$sdev]} ]] && continue
            local tdev=$sdev

            {
                if [[ $x == LSRCS && ${#LMBRS[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                    local tdev=$SNAP4CLONE
                    lvremove -f "${VG_SRC_NAME}/$tdev"
                    lvcreate -l100%FREE -s -n snap4clone "${VG_SRC_NAME}/$lv_src_name"
                    sleep 3
                    mount_ "/dev/${VG_SRC_NAME}/$tdev" -p "${MNTPNT}/$tdev"
                else
                    mount_ "$sdev" -t "${FILESYSTEMS[$sdev]}"
                fi
            }

            local src_size=$(df --block-size=1M --output=used "${MNTPNT}/$tdev/" | tail -n -1 | sed -e 's/^\s*//; s/\s*$//')
            cmd="tar --warning=none --directory=${MNTPNT}/$tdev --exclude=/run/* --exclude=/tmp/* --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* --atime-preserve --numeric-owner --xattrs"
            file="${g}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${src_size}.${sdev//\//_}.${mount//\//_} "

            [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

            if [[ $INTERACTIVE == true ]]; then
                message -u -c -t "Creating backup for $sdev [ scan ]"
                local size=$(du --bytes --exclude=/run/* --exclude=/tmp/* --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* -s ${MNTPNT}/$tdev | awk '{print $1}')
                if [[ $SPLIT == true ]]; then
                    cmd="$cmd -Scpf - . | pv --interval 0.5 --numeric -s $size | split -b 1G - $file"
                else
                    cmd="$cmd -Scpf - . | pv --interval 0.5 --numeric -s $size > $file"
                fi

                while read -r e; do
                    [[ $e -ge 100 ]] && e=100 #Just a precaution
                    message -u -c -t "Creating backup for $sdev [ $(printf '%02d%%' $e) ]"
                done < <(eval "$cmd" 2>&1) #Note that with pv stderr holds the current percentage value!
                message -u -c -t "Creating backup for $sdev [ $(printf '%02d%%' 100) ]" #In case we very faster than the update interval of pv, especially when at 98-99%.
            else
                message -c -t "Creating backup for $sdev"
                {
                    if [[ $SPLIT == true ]]; then
                        cmd="$cmd -Scpf - . | split -b 1G - $file"
                    else
                        cmd="$cmd -Scpf $file ."
                    fi
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
    echo $SECTORS_USED >"$DEST/$F_SECTORS_USED"
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
        local swap_size=0
        declare -A src_lfs

        ldata=$(if [[ $_RMODE == true ]]; then cat "$SRC/$F_LVS_LIST";
                else lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_role,lv_dm_path;
                fi)

        if [[ -n $SWAP_PART ]]; then
            read -r swap_name swap_size <<<$(echo "$ldata" | grep $SWAP_PART | awk '{print $1, $3}')
        fi
        ((SWAP_SIZE > 0)) && swap_size=$(to_mbyte ${SWAP_SIZE}K)

        vgcreate "$VG_SRC_NAME_CLONE" $(pvs --noheadings -o pv_name,vg_name | sed -e 's/^ *//' | grep -Ev '/.*\s+\w+') #TODO optimize, check for better solution
        [[ $PVALL == true ]] && vg_extend "$VG_SRC_NAME_CLONE" "$SRC" "$DEST"

        if [[ $NO_SWAP == true ]]; then
            swap_part=${swap_part////\\/}
            pdata=$(echo "$pdata" | sed "/$swap_part/d")
        else
            lvcreate --yes -L${swap_size%%.*} -n "$swap_name" "$VG_SRC_NAME_CLONE"
        fi

        while read -r e; do
            read -r vg_name vg_size vg_free <<<"$e"
            [[ $vg_name == "$VG_SRC_NAME" ]] && s1=$((${vg_size%%.*} - ${vg_free%%.*} - ${swap_size%%.*}))
            [[ $vg_name == "$VG_SRC_NAME_CLONE" ]] && s2=${vg_free%%.*}
        done < <(if [[ $_RMODE == true ]]; then cat "$SRC/$F_VGS_LIST"; else vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free; fi)

        denom_size=$((s1 < s2 ? s2 : s1))

        : 'It might happen that a volume is so small, that it is only 0% in size. In this case we assume the
        lowest possible value: 1%. This also means we have to decrease the maximum possible size. E.g. two volumes
        with 0% and 100% would have to be 1% and 99% to make things work.'
        local max_size=100

        while read -r e; do
            read -r lv_name vg_name lv_size vg_size vg_free lv_role lv_dm_path <<<"$e"
            if [[ $vg_name == "$VG_SRC_NAME" ]]; then
                [[ $lv_dm_path == $SWAP_PART ]] && continue
                [[ -n $LVM_EXPAND && $lv_name == "$LVM_EXPAND" ]] && continue
                [[ $lv_role =~ snapshot ]] && continue
                size=$(echo "$lv_size * 100 / $denom_size" | bc)

                if ((s1 < s2)); then
                    lvcreate --yes -L"${lv_size%%.*}" -n "$lv_name" "$VG_SRC_NAME_CLONE"
                else
                    ((size == 0)) && size=1 && max_size=$((max_size - size))
                    lvcreate --yes -l${size}%VG -n "$lv_name" "$VG_SRC_NAME_CLONE"
                fi
            fi
        done < <(if [[ $_RMODE == true ]]; then cat "$SRC/$F_LVS_LIST";
                else lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_role,lv_dm_path;
                fi)

        [[ -n $LVM_EXPAND ]] && lvcreate --yes -l"${LVM_EXPAND_BY:-100}%FREE" -n "$LVM_EXPAND" "$VG_SRC_NAME_CLONE"

        while read -r e; do
            read -r name kname fstype uuid partuuid type parttype mountpoint <<<"$e"
            eval "$name" "$kname" "$fstype" "$uuid" "$partuuid" "$type" "$parttype" "$mountpoint"
            [[ $TYPE == 'lvm' ]] && src_lfs[${NAME##*-}]=$FSTYPE
        done < <(if [[ -d $SRC ]]; then cat "$SRC/$F_PART_LIST"; else lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" ${VG_DISKS[@]}; fi)

        while read -r e; do
            read -r kname name fstype type <<<"$e"
            eval "$kname" "$name" "$fstype" "$type"
            [[ -z ${src_lfs[${NAME##*-}]} ]] && exit_ 1 "Unexpected Error" #Yes, I know... but has to do for the moment!
            { [[ "${src_lfs[${NAME##*-}]}" == swap ]] && mkswap -f "$NAME"; } || mkfs -t "${src_lfs[${NAME##*-}]}" "$NAME"
        done < <(lsblk -Ppo KNAME,NAME,FSTYPE,TYPE "$DEST" ${PVS[@]} | sort -ru | grep ${VG_SRC_NAME_CLONE//-/--}); : 'The
        device mapper doubles hyphens in a LV/VG names exactly so it can distinguish between hyphens _inside_ an LV or
        VG name and a hyphen used as separator _between_ them.'
    } #}}}

    _prepare_disk() { #{{{
        if hash lvm 2>/dev/null; then
            # local vgname=$(vgs -o pv_name,vg_name | eval grep "'${DEST}|${VG_DISKS/ /|}'" | awk '{print $2}')
            local vgname=$(vgs -o pv_name,vg_name | grep "${DEST}" | awk '{print $2}')
            vgreduce --removemissing "$vgname"
            vgremove -f "$vgname"
            pvremove -f "${DEST}*"

            while read -r e; do
                echo "pvremove -f $e"
                pvremove $e || exit_ 1 "Cannot remove PV $e"
            done < <(pvs --noheadings -o pv_name,vg_name | grep -E '(/\w*)+(\s+)$')
        fi

        dd oflag=direct if=/dev/zero of="$DEST" bs=512 count=100000
        dd oflag=direct bs=512 if=/dev/zero of="$DEST" count=4096 seek=$(($(blockdev --getsz $DEST) - 4096))

        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"

        sleep 3

        if [[ $ENCRYPT_PWD ]]; then
            encrypt "$ENCRYPT_PWD" "$DEST" "$LUKS_LVM_NAME"
        else
            local ptable="$(if [[ $_RMODE == true ]]; then cat "$SRC/$F_PART_TABLE"; else sfdisk -d "$SRC"; fi)"

            flock "$DEST" sfdisk --force "$DEST" < <(expand_disk "$SRC" "$DEST" "$ptable")
            flock "$DEST" sfdisk -Vq "$DEST" || return 1
        fi
        blockdev --rereadpt $DEST && udevadm settle

        [[ $UEFI == true ]] && mbr2gpt $DEST
    } #}}}

    _finish() { #{{{
        [[ -f "$1/etc/hostname" && -n $HOST_NAME ]] && echo "$HOST_NAME" >"$1/etc/hostname"
        [[ -f $1/grub/grub.cfg || -f $1/grub.cfg || -f $1/boot/grub/grub.cfg ]] && HAS_GRUB=true
        [[ -d $1/EFI ]] && HAS_EFI=true
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
            local k=$(echo "$file" | sed "s/\.[a-z]*$//")
            files[$k]=1
        done

        #Now, we are ready to restore files from previous backup images
        for file in ${!files[@]}; do
            read -r i uuid puuid fs type ss dev mnt <<<"${file//./ }"
            local ddev=${DESTS[${SRC2DEST[$uuid]}]}
            [[ -z $ddev ]] && ddev=${DESTS[${PSRC2PDEST[$puuid]}]}

            MOUNTS[${mnt//_/\/}]="$uuid"

            if [[ -n $ddev ]]; then
                mount_ "$ddev" -t "$fs"
                pushd "${MNTPNT}/$ddev" >/dev/null || return 1

                local ds=$(df --block-size=1M --output=avail "${MNTPNT}/$ddev" | tail -n -1)
                ((ds - ss <= 0)) && exit_ 10 "Require ${ss}M but destination is only ${ds}M"

                local cmd="tar -xf - -C ${MNTPNT}/$ddev"
                [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

                if [[ $INTERACTIVE == true ]]; then
                    local size=$(du --bytes -c "${SRC}/${file}"* | tail -n1 | awk '{print $1}')
                    cmd="cat \"${SRC}\"/${file}* | pv --interval 0.5 --numeric -s $size | $cmd"
                    [[ $fs == vfat ]] && cmd="fakeroot $cmd"
                    while read -r e; do
                        [[ $e -ge 100 ]] && e=100
                        message -u -c -t "Restoring $file [ $(printf '%02d%%' $e) ]"
                        #Note that with pv stderr holds the current percentage value!
                    done < <((eval "$cmd") 2>&1)
                    message -u -c -t "Restoring $file [ $(printf '%02d%%' 100) ]"
                else
                    message -c -t "Restoring $file"
                    cmd="cat ${SRC}/${file}* | $cmd"
                    [[ $fs == vfat ]] && cmd="fakeroot $cmd"
                    eval "$cmd"
                fi

                popd >/dev/null || return 1
                _finish ${MNTPNT}/$ddev 2>/dev/null
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
                local tdev=$sdev
                local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | awk '{print $1}')
                local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${VG_SRC_NAME}" | sort -u | awk '{print $2}')

                [[ -z ${FILESYSTEMS[$sdev]} ]] && continue
                mkdir -p "${MNTPNT}/$ddev" "${MNTPNT}/$sdev"
                [[ -d ${MNTPNT}/$sdev/EFI ]] && HAS_EFI=true
                [[ $SYS_HAS_EFI == false && $HAS_EFI == true ]] && exit_ 1 "Cannot clone UEFI system. Current running system does not support UEFI."

                {
                    if [[ $dev == LSRCS && ${#LMBRS[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                        tdev='snap4clone'
                        mkdir -p "${MNTPNT}/$tdev"
                        lvremove -q -f "${VG_SRC_NAME}/$tdev"
                        lvcreate -l100%FREE -s -n snap4clone "${VG_SRC_NAME}/$lv_src_name" &&
                            sleep 3 &&
                            mount_ "/dev/${VG_SRC_NAME}/$tdev" -p "${MNTPNT}/$tdev" || return 1
                    else
                        mount_ "$sdev"
                    fi
                }

                mount_ "$ddev"

                local ss=$(df --block-size=1M --output=used "${MNTPNT}/$tdev/" | tail -n -1)
                local ds=$(df --block-size=1M --output=avail "${MNTPNT}/$ddev" | tail -n -1)
                ((ds - ss <= 0)) && exit_ 10 "Require ${ss}M but destination is only ${ds}M"

                if [[ $INTERACTIVE == true ]]; then
                    message -u -c -t "Cloning $sdev to $ddev [ scan ]"
                    local size=$(
                        rsync -aSXxH --stats --dry-run "${MNTPNT}/$tdev/" "${MNTPNT}/$ddev" |
                            grep -oP 'Number of files: \d*(,\d*)*' |
                            cut -d ':' -f2 |
                            tr -d ' ' |
                            sed -e 's/,//g'
                    )

                    while read -r e; do
                        [[ $e -ge 100 ]] && e=100
                        message -u -c -t "Cloning $sdev to $ddev [ $(printf '%02d%%' $e) ]"
                    done < <((rsync -vaSXxH "${MNTPNT}/$tdev/" "${MNTPNT}/$ddev" | pv --interval 0.5 --numeric -le -s "$size" 3>&2 2>&1 1>&3) 2>/dev/null)
                    message -u -c -t "Cloning $sdev to $ddev [ $(printf '%02d%%' 100) ]"
                else
                    message -c -t "Cloning $sdev to $ddev"
                    {
                        rsync -aSXxH "${MNTPNT}/$tdev/" "${MNTPNT}/$ddev"
                    } >/dev/null
                fi
                {
                    sleep 3
                    umount_ "/dev/${VG_SRC_NAME}/$tdev"
                    [[ $dev == LSRCS ]] && lvremove -q -f "${VG_SRC_NAME}/$tdev"

                    _finish ${MNTPNT}/$ddev 2>/dev/null
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
        local f=$([[ $_RMODE == true ]] && echo "$SRC/$F_PART_LIST")
        _prepare_disk #First collect what we have in our backup
        init_srcs "UUIDS" "SRCS" "LSRCS" "PARTUUIDS" "PUUIDS2UUIDS" "TYPES" "NAMES" "FILESYSTEMS" "$f"
        set_src_uuids "SPUUIDS" "SUUIDS" "SNAMES" "LMBRS" "SECTORS_USED" "$f"

        if [[ $ENCRYPT_PWD ]]; then
            pvcreate -ff "/dev/mapper/$LUKS_LVM_NAME"
            sleep 3
            _lvm_setup "/dev/mapper/$LUKS_LVM_NAME"
            sleep 3
        else
            disk_setup "$f" "$UEFI" "$SRC" "$DEST"
            if [[ ${#LMBRS[@]} -gt 0 ]]; then
                _lvm_setup "$DEST"
                sleep 3
            fi
        fi

        #Now collect what we have created
        set_dest_uuids "DPUUIDS" "DUUIDS" "DNAMES" "DESTS"

        if [[ ${#SUUIDS[@]} != "${#DUUIDS[@]}" || ${#SPUUIDS[@]} != "${#DPUUIDS[@]}" || ${#SNAMES[@]} != "${#DNAMES[@]}" ]]; then
            echo >&2 "Source and destination tables for UUIDs, PARTUUIDs or NAMES did not macht. This should not happen!"
            return 1
        fi

        #TODO
        for ((i = 0; i < ${#SUUIDS[@]}; i++)); do SRC2DEST[${SUUIDS[$i]}]=${DUUIDS[$i]}; done
        for ((i = 0; i < ${#SPUUIDS[@]}; i++)); do PSRC2PDEST[${SPUUIDS[$i]}]=${DPUUIDS[$i]}; done
        for ((i = 0; i < ${#SNAMES[@]}; i++)); do NSRC2NDEST[${SNAMES[$i]}]=${DNAMES[$i]}; done

        [[ $_RMODE == false ]] && mounts
    }
    message -y

    #Check if destination is big enough.
    local cnt
    [[ $_RMODE == true ]] && SECTORS_USED=$(cat "$SRC/$F_SECTORS_USED")
    [[ -b $DEST ]] && cnt=$(to_kbyte $(blockdev --getsize64 "$DEST"))
    [[ -d $DEST ]] && cnt=$(df -k --output=avail "$DEST" | tail -n -1)
    ((cnt - SECTORS_USED <= 0)) && exit_ 10 "Require $(to_mbyte ${SECTORS}K)M but destination is only $(to_mbyte ${cnt}K)M"

    if [[ $_RMODE == true ]]; then
        _from_file || return 1
    else
        _clone || return 1
    fi

    if [[ $HAS_GRUB == true ]]; then
        message -c -t "Installing Grub"
        {
            if [[ $ENCRYPT_PWD ]]; then
                crypt_setup "$ENCRYPT_PWD" ${DESTS[${SRC2DEST[${MOUNTS['/']}]}]} "$DEST" "$LUKS_LVM_NAME" "$ENCRYPT_PART" || return 1
            else
                [[ $HAS_EFI == true && $SYS_HAS_EFI == false ]] && return 1
                grub_setup ${DESTS[${SRC2DEST[${MOUNTS['/']}]}]} $HAS_EFI $UEFI "$DEST" || return 1
            fi
        }
        message -y
    fi
    return 0
} #}}}

Main() { #{{{
    local args_count=$# #getop changes the $# value. To be sure we save the original arguments count.
    local args=$@ #Backup original arguments.

    _validate_block_device() { #{{{
        local t=$(lsblk --nodeps --noheadings -o TYPE "$1")
        ! [[ $t =~ disk|loop ]] && exit_ 1 "Invalid block device. $1 is not a disk."
    } #}}}

    _is_valid_lv() { #{{{
        local lv_name="$1"
        local vg_name="$2"

        if [[ $_RMODE == true ]]; then
            grep -qw "$lv_name" < <(cat "$SRC/$F_LVS_LIST" | awk '{print $1}' | sort -u)
        else
            lvs --noheadings -o lv_name,vg_name | grep -w "$vg_name" | grep -qw "$1"
        fi
    } #}}}

    _run_schroot() { #{{{
        # debootstrap --make-tarball=bcrm.tar --include=git,locales,lvm2,bc,pv,parallel,qemu-utils stretch ./dbs2
        # debootstrap --unpack-tarball=$(dirname $(readlink -f $0))/bcrm.tar --include=git,locales,lvm2,bc,pv,parallel,qemu-utils,rsync stretch /tmp/dbs

        [[ -s $SCRIPTPATH/$F_SCHROOT ]] || exit_ 2 "Cannot run schroot because the archive containing it - $F_SCHROOT - is missing."

        echo_ "Creating chroot environment. This might take a while ..."
        { mkdir -p $SCHROOT_HOME && tar xf ${SCRIPTPATH}/$F_SCHROOT -C $_; } || exit_ 1 "Faild extracting chroot. See the log $F_LOG for details."

        for f in sys dev dev/pts proc run; do
            mount_ "/$f" -p "$SCHROOT_HOME/$f" -b
        done

        if [[ -d "$SRC" && -b $DEST ]]; then
            { mkdir -p "$SCHROOT_HOME/$SRC" && mount_ "$SRC" -p "$SCHROOT_HOME/$SRC" -b; } ||
                exit_ 1 "Failed preparing chroot for restoring from backup."
        elif [[ -b "$SRC" && -d $DEST ]]; then
            { mkdir -p "$SCHROOT_HOME/$DEST" && mount_ "$DEST" -p "$SCHROOT_HOME/$DEST" -b; } ||
                exit_ 1 "Failed preparing chroot for backup creation."
        fi

        echo -n "$( < <(echo -n "
            [bcrm]
            type=plain
            directory=${SCHROOT_HOME}
            profile=desktop
            preserve-environment=true
        "  ))" |  sed -e '/./,$!d; s/^\s*//' > /etc/schroot/chroot.d/bcrm

        cp -r $(dirname $(readlink -f $0)) $SCHROOT_HOME
        echo_ "Now executing chroot in $SCHROOT_HOME"
        rm $PIDFILE && schroot -c bcrm -d /sf_bcrm -- bcrm.sh ${args//--schroot/}
        for f in sys dev dev/pts proc run; do
            umount_ "/$f"
        done
        umount_ "$SCHROOT_HOME/$DEST"
    } #}}}

    _prepare_locale() { #{{{
        mkdir -p $BACKUP_FOLDER
        local cf="/etc/locale.gen"
        CHG_SYS_FILES["$cf"]=$(md5sum "$cf" | awk '{print $1}')

        mkdir -p "${BACKUP_FOLDER}/${cf%/*}" && cp "$cf" "${BACKUP_FOLDER}/${cf}"
        echo "en_US.UTF-8 UTF-8" > "$cf"
        locale-gen || return 1
    } #}}}

    trap Cleanup INT TERM EXIT

    if [[ -t 1 ]]; then
        exec 3>&1 4>&2
        tput sc
    fi

    option=$(getopt \
        -o 'huqcxps:d:e:n:m:w:b:H:' \
        --long '
            help,
            hostname:,
            remove-pkgs:,
            encrypt-with-password:,
            new-vg-name:,
            resize-threshold:,
            destination-image:,
            source-image:,
            split,
            lvm-expand:,
            swap-size:,
            use-all-pvs,
            make-uefi,
            source,
            destination,
            compress,
            quiet,
            schroot,
            boot-size:,
            check' \
        -n "$(basename "$0" \
        )" -- "$@")

    [[ $? -ne 0 ]] && usage

    eval set -- "$option"

    [[ $1 == -h || $1 == --help || $args_count -eq 0 ]] && usage #Don't have to be root to get the usage info

    #Force root
    [[ "$(id -u)" != 0 ]] && exec sudo "$0" "$@"

    echo >$F_LOG
    hash pv && INTERACTIVE=true || message -i -t "No progress will be shown. Consider installing package: pv"

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

    while true; do
        case "$1" in
        '-h' | '--help')
            usage
            shift 1; continue
            ;;
        '-s' | '--source')
            SRC=$(readlink -m "$2");
            shift 2; continue
            ;;
        '--source-image')
            read -r SRC_IMG IMG_TYPE <<<${2//:/ }

            [[ -n $SRC_IMG && -z $IMG_TYPE ]] && exit_ 1 "Missing type attribute"
            [[ $IMG_TYPE =~ ^raw$|^vdi$|^vmdk$|^qcow2$ ]] || exit_ 2 "Invalid image type in $1 $2"
            [[ ! -e "$SRC_IMG" ]] && exit_ 1 "Specified image file does not exists."

            PKGS+=(qemu-img)
            CREATE_LOOP_DEV=true
            shift 2; continue
            ;;
        '--destination-image')
            read -r DEST_IMG IMG_TYPE IMG_SIZE <<<${2//:/ }

            [[ -n $DEST_IMG && -z $IMG_TYPE ]] && exit_ 1 "Missing type attribute"
            [[ $IMG_TYPE =~ ^raw$|^vdi$|^vmdk$|^qcow2$ ]] || exit_ 2 "Invalid image type in $1 $2"
            [[ ! -e "$DEST_IMG" && -z $IMG_SIZE ]] && exit_ 1 "Specified image file does not exists."

            if [[ -n $DEST_IMG && -n $IMG_SIZE ]]; then
                validate_size $IMG_SIZE || exit_ 2 "Invalid size attribute in $1 $2"
            fi

            PKGS+=(qemu-img)
            CREATE_LOOP_DEV=true
            shift 2; continue
            ;;
        '-d' | '--destination')
            DEST=$(readlink -m "$2")
            shift 2; continue
            ;;
        '-n' | '--new-vg-name')
            VG_SRC_NAME_CLONE="$2"
            shift 2; continue
            ;;
        '-e' | '--encrypt-with-password')
            ENCRYPT_PWD="$2"
            PKGS+=(cryptsetup)
            shift 2; continue
            ;;
        '-H' | '--hostname')
            HOST_NAME="$2"
            shift 2; continue
            ;;
        '-u' | 'make-uefi')
            UEFI=true;
            shift 1; continue
            ;;
        '-p' | '--use-all-pvs')
            PVALL=true;
            shift 1; continue
            ;;
        '-q' | '--quiet')
            exec 3>&-
            exec 4>&-
            shift 1; continue
            ;;
        '--split')
            SPLIT=true;
            shift 1; continue
            ;;
        '-c' | '--check')
            IS_CHECKSUM=true
            PKGS+=(parallel)
            shift 1; continue
            ;;
        '-z' | '--compress')
            export XZ_OPT=-4T0
            PKGS+=(xz)
            shift 1; continue
            ;;
        '-m' | '--resize-threshold')
            { validate_size $2 && MIN_RESIZE="$(to_mbyte $2)"; } || exit_ 2 "Invalid size specified.
                Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
            shift 2; continue
            ;;
        '-w' | '--swap-size')
            { validate_size $2 && SWAP_SIZE=$(to_kbyte $2); } || exit_ 2 "Invalid size specified.
                Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
            (($SWAP_SIZE <= 0)) && NO_SWAP=true
            shift 2; continue
            ;;
        '-b' | '--boot-size')
            { validate_size $2 && BOOT_SIZE=$(to_kbyte $2); } || exit_ 2 "Invalid size specified.
                Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
            shift 2; continue
            ;;
        '--lvm-expand')
            read -r LVM_EXPAND LVM_EXPAND_BY <<<${2/:/ }
            [[ "$LVM_EXPAND_BY" =~ ^0*[1-9]$|^0*[1-9][0-9]$|^100$ ]] || exit_ 2 "Invalid size attribute in $1 $2"
            shift 2; continue
            ;;
        '--remove-pkgs')
            REMOVE_PKGS=$2
            shift 2; continue
            ;;
        '--schroot')
            PKGS+=(schroot debootstrap)
            SCHROOT=true;
            shift 1; continue
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
            qemu-img)
                packages+=(qemu-utils)
                ;;
            *)
                packages+=($c)
                ;;
            esac
            abort='exit_ 1'
        }
    done

    exec >$F_LOG 2>&1

    [[ -n $abort ]] && message -n -t "ERROR: Some packages missing. Please install packages: $(echo ${packages[@]})"
    eval "$abort"

    if [[ -n $SRC_IMG ]]; then
        modprobe nbd max_part=16 && qemu-nbd --cache=writeback -f $IMG_TYPE -c $SRC_NBD "$SRC_IMG"
        SRC=$SRC_NBD
    fi

    [[ -n $DEST && -n $DEST_IMG && -n $IMG_TYPE && -n $IMG_SIZE ]] && exit_ 1 "Invalid combination."

    if [[ -n $DEST_IMG ]]; then
        create_image "$DEST_IMG" "$IMG_TYPE" "$IMG_SIZE" || exit_ 1 "Image creation failed."
        modprobe nbd max_part=16 && qemu-nbd --cache=writeback -f $IMG_TYPE -c $DEST_NBD "$DEST_IMG"
        DEST=$DEST_NBD
    fi

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

    [[ -d $DEST && ! -r $DEST && ! -w $DEST && ! -x $DEST ]] &&
        exit_ 1 "$DEST is not writable."

    [[ -d $SRC && ! -r $SRC && ! -x $SRC ]] &&
        exit_ 1 "$SRC is not readable."

    for d in "$SRC" "$DEST"; do
        [[ -b $d ]] && _validate_block_device $d
    done

    [[ $SRC == $DEST ]] &&
        exit_ 1 "Source and destination cannot be the same!"

    [[ $UEFI == true && $SYS_HAS_EFI == false ]] &&
        exit_ 1 "Cannot convert to UEFI because system booted in legacy mode. Check your UEFI firmware settings!"

    [[ -n $(lsblk --noheadings -o mountpoint $DEST 2>/dev/null) ]] &&
        exit_ 1 "Invalid device condition. Some or all partitions of $DEST are mounted."

    [[ $PVALL == true && -n $ENCRYPT_PWD ]] && exit_ 1 "Encryption only supported for simple LVM setups with a single PV!"

    #Make sure source or destination folder are not mounted on the same disk to backup to or restore from.
    for d in "$SRC" "$DEST"; do
        if [[ -d $d ]]; then
            local disk=()
            disk+=($(df --block-size=1M $d | tail -n 1 | awk '{print $1}'))
            disk+=($(lsblk -psnlo name,type $disk 2>/dev/null | grep disk | awk '{print $1}'))
            [[ ${disk[-1]} == $SRC || ${disk[-1]} == $DEST ]] && exit_ 1 "Source and destination cannot be the same!"
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

        for f in $(cat "$SRC" | grep -v -i swap |  grep -o 'MOUNTPOINT=".\+"' | cut -d '=' -f 2 | tr -d '"' | tr -s "/" "_"); do
            grep "$f\$" <(ls "$SRC") || exit_ 2 "$SRC folder missing files."
        done
    fi

    VG_SRC_NAME=$(echo $(if [[ -d $SRC ]]; then cat "$SRC/$F_PVS_LIST"; else pvs --noheadings -o pv_name,vg_name | grep "$SRC"; fi) | awk '{print $2}' | sort -u)

    if [[ -z $VG_SRC_NAME ]]; then
        while read -r e g; do
            grep -q ${SRC##*/} < <(dmsetup deps -o devname | sort -u | sed 's/.*(\(\w*\).*/\1/g') && VG_SRC_NAME=$g
        done < <(if [[ -d $SRC ]]; then cat "$SRC/$F_PVS_LIST"; else pvs --noheadings -o pv_name,vg_name; fi)
    fi

    [[ -n $VG_SRC_NAME ]] && vg_disks $VG_SRC_NAME "VG_DISKS" && IS_LVM=true

    if [[ $IS_LVM == true ]]; then
        [[ -z $VG_SRC_NAME_CLONE ]] && VG_SRC_NAME_CLONE=${VG_SRC_NAME}_${CLONE_DATE}

        [[ -n $LVM_EXPAND ]] && ! _is_valid_lv "$LVM_EXPAND" "$VG_SRC_NAME" && exit_ 2 "Volumen name ${LVM_EXPAND} does not exists in ${VG_SRC_NAME}!"

        grep -q "^$VG_SRC_NAME_CLONE\$" < <(dmsetup deps -o devname) && exit_ 2 "Generated VG name $VG_SRC_NAME_CLONE already exists!"
    fi

    SWAP_PART=$(if [[ -d $SRC ]]; then
        cat "$SRC/$F_PART_LIST" | grep swap | awk '{print $1}' | cut -d '"' -f 2
    else
        lsblk -lpo name,fstype "$SRC" | grep swap | awk '{print $1}'
    fi)

    #Botable is the first partition or the one marked as bootable
    BOOT_PART=$(if [[ -d $SRC ]]; then
        cat "$SRC/$F_PART_TABLE" | grep 'bootable\|^/' | head -n 1 | awk '{print $1}'
    else
        sfdisk --dump "$SRC" | grep 'bootable\|^/' | head -n 1 | awk '{print $1}'
    fi)

    #In case another distribution is used when cloning, e.g. cloning an Ubuntu system with Debian Live CD.
    [[ ! -e /run/resolvconf/resolv.conf ]] && mkdir /run/resolvconf && cp /run/NetworkManager/resolv.conf /run/resolvconf/
    [[ ! -e /run/NetworkManager/resolv.conf ]] && mkdir /run/NetworkManager && cp /run/resolvconf/resolv.conf /run/NetworkManager/

    if [[ $SCHROOT == true ]]; then
        [[ -b "$SRC" && -d $DEST && -n "$(ls -A "$DEST")" ]] && exit_ 1 "Destination not empty!"
        _run_schroot
        Cleanup
    fi

    _prepare_locale || exit_ 1 "Could not prepare locale!"

    #main
    echo_ "Backup started at $(date)"
    if [[ -b $SRC && -b $DEST ]]; then
        Clone || exit_ 1
    elif [[ -d "$SRC" && -b $DEST ]]; then
        Clone -r || exit_ 1
    elif [[ -b "$SRC" && -d $DEST ]]; then
        To_file || exit_ 1
    fi
    echo_ "Backup finished at $(date)"
} #}}}

bash -n $(readlink -f $0) && Main "$@" #self check and run

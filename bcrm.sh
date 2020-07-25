#! /usr/bin/env bash
# shellcheck disable=SC2155,SC2153,SC2015,SC2094,SC2016,SC2034

# Copyright (C) 2017-2019 Marcel Lautenbach {{{
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
#}}}

# OPTIONS -------------------------------------------------------------------------------------------------------------{{{
unset IFS #Make sure IFS is not overwritten from the outside
export LC_ALL=en_US.UTF-8
export LVM_SUPPRESS_FD_WARNINGS=true
export XZ_OPT= #Make sure no compression is in place, can be set with -z. See Main()
[[ $TERM == unknown || $TERM == dumb ]] && export TERM=xterm
set -o pipefail
#}}}

# CONSTANTS -----------------------------------------------------------------------------------------------------------{{{
declare F_SCHROOT_CONFIG='/etc/schroot/chroot.d/bcrm'
declare F_SCHROOT='bcrm.stretch.tar.xz'
declare F_PART_LIST='part_list'
declare F_VGS_LIST='vgs_list'
declare F_LVS_LIST='lvs_list'
declare F_PVS_LIST='pvs_list'
declare F_PART_TABLE='part_table'
declare F_CHESUM='check.md5'
declare F_CONTEXT='context'
declare F_DEVICE_MAP='device_map'
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
declare SALT=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
declare LUKS_LVM_NAME="${SALT}_${CLONE_DATE}"

declare ID_GPT_LVM=e6d6d379-f507-44c2-a23c-238f2a3df928
declare ID_GPT_EFI=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
declare ID_GPT_LINUX=0fc63daf-8483-4772-8e79-3d69d8477de4
declare ID_DOS_EFI=ef
declare ID_DOS_LVM=8e
declare ID_DOS_LINUX=83
declare ID_DOS_FAT32=c
declare ID_DOS_EXT=5
declare _RMODE=false
#}}}

# PREDEFINED COMMAND SEQUENCES ----------------------------------------------------------------------------------------{{{
declare LSBLK_CMD='lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT,SIZE'
#}}}

# VARIABLES -----------------------------------------------------------------------------------------------------------{{{

# GLOBALS -------------------------------------------------------------------------------------------------------------{{{
declare -A SRCS
declare -A DESTS
declare -A CONTEXT          #Values needed for backup/restore

declare -A CHG_SYS_FILES    #Container for system files that needed to be changed during execution
                            #Key = original file path, Value = MD5sum

declare -A MNTJRNL MOUNTS EXT_PARTS EXCLUDES CHOWN
declare -A SRC2DEST PSRC2PDEST NSRC2NDEST
declare -A DEVICE_MAP

declare PVS=() VG_DISKS=() CHROOT_MOUNTS=()
#}}}

# FILLED BY OR BECAUSE OF PROGRAM ARGUMENTS ---------------------------------------------------------------------------{{{
declare PKGS=() #Will be filled with a list of packages that will be needed, depending on given arguments
declare SRCS_ORDER=() DESTS_ORDER=()

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
declare CREATE_LOOP_DEV=false
declare PVALL=false
declare SPLIT=false
declare IS_CHECKSUM=false
declare SCHROOT=false
declare IS_CLEANUP=true
declare ALL_TO_LVM=false

declare MIN_RESIZE=2048 #In 1M units
declare SWAP_SIZE=-1    #Values < 0 mean no change/ignore
declare BOOT_SIZE=-1
declare LVM_EXPAND_BY=0 #How much % of free space to use from a VG, e.g. when a dest disk is larger than a src disk.
#}}}

# CHECKS FILLED BY MAIN -----------------------------------------------------------------------------------------------{{{
declare DISABLED_MOUNTS=()
declare -A TO_LVM=()
declare VG_SRC_NAME=""
declare BOOT_PART=""
declare SWAP_PART=""
declare EFI_PART=""
declare MNTPNT=""
declare TABLE_TYPE=""

declare INTERACTIVE=false
declare HAS_GRUB=false
declare HAS_LUKS=false    #If source is encrypted
declare HAS_EFI=false     #If the cloned system is UEFI enabled
declare SYS_HAS_EFI=false #If the currently running system has UEFI
declare IS_LVM=false

declare EXIT=0
declare SECTORS_SRC=0
declare SECTORS_DEST=0
declare SECTORS_SRC_USED=0
declare VG_FREE_SIZE=0
#}}}

#}}}

# DEBUG ONLY ----------------------------------------------------------------------------------------------------------{{{
printarr() { #{{{
    local k
    declare -n __p="$1"
    for k in "${!__p[@]}"; do printf "%s=%s\n" "$k" "${__p[$k]}" >> $F_LOG; done
} #}}}
#}}}

# PRIVATE - Only used by PUBLIC functions -----------------------------------------------------------------------------{{{

#--- Display ---{{{

echo_() { #{{{
    exec 1>&3 #restore stdout
    echo "$1"
    exec 3>&1         #save stdout
    exec >>$F_LOG 2>&1 #again all to the log
} #}}}

logmsg() { #{{{
    local d=$(date --rfc-3339=seconds)
    printf "\n[BCRM] ${d}\t${1}\n\n" >> $F_LOG
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
    printf "  %-3s %-30s %s\n"   "   " ""                        "If you omit the size, the image file must exists."
    printf "  %-3s %-30s %s\n"   "   " ""                        "If you provide a size, the image file will be created or overwritten."
    printf "  %-3s %-30s %s\n"   "-c," "--check"                 "Create/Validate checksums"
    printf "  %-3s %-30s %s\n"   "-z," "--compress"              "Use compression (compression ratio is about 1:3, but very slow!)"
    printf "  %-3s %-30s %s\n"   "   " "--split"                 "Split backup into chunks of 1G files"
    printf "  %-3s %-30s %s\n"   "-H," "--hostname"              "Set hostname"
    printf "  %-3s %-30s %s\n"   "   " "--remove-pkgs"           "Remove the given list of whitespace-separated packages as a final step."
    printf "  %-3s %-30s %s\n"   "   " ""                        "The whole list must be enclosed in \"\""
    printf "  %-3s %-30s %s\n"   "-n," "--new-vg-name"           "LVM only: Define new volume group name"
    printf "  %-3s %-30s %s\n"   "   " "--vg-free-size"          "LVM only: How much space should be added to remaining free space in source VG."
    printf "  %-3s %-30s %s\n"   "-e," "--encrypt-with-password" "LVM only: Create encrypted disk with supplied passphrase"
    printf "  %-3s %-30s %s\n"   "-p," "--use-all-pvs"           "LVM only: Use all disks found on destination as PVs for VG"
    printf "  %-3s %-30s %s\n"   "   " "--lvm-expand"            "LVM only: Have the given LV use the remaining free space."
    printf "  %-3s %-30s %s\n"   "   " ""                        "An optional percentage can be supplied, e.g. 'root:80'"
    printf "  %-3s %-30s %s\n"   "   " ""                        "Which would add 80% of the remaining free space in a VG to this LV"
    printf "  %-3s %-30s %s\n"   "-u," "--make-uefi"             "Convert to UEFI"
    printf "  %-3s %-30s %s\n"   "-w," "--swap-size"             "Swap partition size. May be zero to remove any swap partition."
    printf "  %-3s %-30s %s\n"   "-m," "--resize-threshold"      "Do not resize partitions smaller than <size> (default 2048M)"
    printf "  %-3s %-30s %s\n"   "   " "--schroot"               "Run in a secure chroot environment with a fixed and tested tool chain"
    printf "  %-3s %-30s %s\n"   "   " "--no-cleanup"            "Do not remove temporary (backup) files and mounts."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Useful when tracking down errors with --schroot."
    printf "  %-3s %-30s %s\n"   "   " "--disable-mount"         "Disable the given mount point in <destination>/etc/fstab."
    printf "  %-3s %-30s %s\n"   "   " ""                        "For instance --disable-mount /some/path. Can be used multiple times."
    printf "  %-3s %-30s %s\n"   "   " "--to-lvm"                "Convert given source partition to LV. E.g. '/dev/sda1:boot' would be"
    printf "  %-3s %-30s %s\n"   "   " ""                        "converted to LV with the name 'boot' Can be used multiple times."
    printf "  %-3s %-30s %s\n"   "   " ""                        "Only works for partitions that have a valid mountpoint in fstab"
    printf "  %-3s %-30s %s\n"   "   " "--all-to-lvm"            "Convert all source partitions to LV. (except EFI)"
    printf "  %-3s %-30s %s\n"   "   " "--include-partition"     "Also include the content of the given partition to the specified path."
    printf "  %-3s %-30s %s\n"   "   " ""                        "E.g: 'part=/dev/sdX,dir=/some/path/,user=1000,group=10001,exclude=fodler1,folder2'"
    printf "  %-3s %-30s %s\n"   "   " ""                        "would copy all content from /dev/sdX to /some/path."
    printf "  %-3s %-30s %s\n"   "   " ""                        "If /some/path does not exist, it will be created with the given user"
    printf "  %-3s %-30s %s\n"   "   " ""                        "and group ID, or root otherwise. With exclude you can filter folders and files."
    printf "  %-3s %-30s %s\n"   "   " ""                        "This option can be specified multiple times."
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
    local text
    local update=false
    clor_current=$(tput bold; tput setaf 3)
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
            status="${clor_current}➤${clr_rmso}"
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
    [[ -n $status ]] && echo -e -n "[ $status ] "
    [[ -n $text ]] \
        && text=$(echo "$text" | sed -e 's/^\s*//; 2,$ s/^/      /') \
        && echo -e -n "$text" \
        && tput el
    echo

    [[ $update == true ]] && tput rc
    tput civis
    exec 3>&1          #save stdout
    exec >>$F_LOG 2>&1 #again all to the log
} #}}}
#}}}

#--- Context ---{{{

# Intitializes the CONTEXT array during backup and restore with sane values.
ctx_init() { #{{{
    logmsg "ctx_init"
    declare -A map
    map[bootPart]=BOOT_PART
    map[hasGrub]=HAS_GRUB
    map[sectors]=SECTORS_SRC
    map[sectorsUsed]=SECTORS_SRC_USED
    map[isLvm]=IS_LVM
    map[isChecksum]=IS_CHECKSUM
    map[hasEfi]=HAS_EFI
    map[tableType]=TABLE_TYPE

    if [[ -d "$SRC" && -e "$SRC/$F_CONTEXT" ]]; then
        local IFS='='
        while read -r k v; do
            CONTEXT["$k"]="$v"
        done < <(sed '/^#/d; /^$/d' "$SRC/$F_CONTEXT")

        local keys=$(echo "${!map[@]} ${!CONTEXT[@]}" | tr -s " " $'\n' | sort | uniq -d)

        {
            local f
            while read -r f; do
                [[ -n ${CONTEXT[$f]} ]] && eval "${map[$f]}"="${CONTEXT[$f]}" || exit_ 1 "Could not init context."
            done < <(echo "$keys")
        }
    else
        {
            local f
            for f in "${!map[@]}"; do
                CONTEXT[$f]=$(eval echo "\$${map[$f]}") || exit_ 1 "Could not init context."
            done
        }
    fi
} #}}}

# Set a single context value
ctx_set() { #{{{
    declare -A map
    declare -n v=$1
    logmsg "ctx_set $1"

    case "$1" in
    BOOT_PART)
        CONTEXT[bootPart]="$v"
        ;;
    SECTORS_SRC)
        CONTEXT[sectors]="$v"
        ;;
    SECTORS_SRC_USED)
        CONTEXT[sectorsUsed]="$v"
        ;;
    IS_LVM)
        CONTEXT[isLvm]="$v"
        ;;
    IS_CHECKSUM)
        CONTEXT[isChecksum]="$v"
        ;;
    HAS_EFI)
        CONTEXT[hasEfi]="$v"
        ;;
    TABLE_TYPE)
        CONTEXT[tableType]="$v"
        ;;
    HAS_GRUB)
        CONTEXT[hasGrub]="$v"
        ;;
    *)
        return 1
        ;;
    esac
} #}}}

# Save key/values of context array to file
ctx_save() { #{{{
    logmsg "ctx_save"
    echo >"$DEST/$F_CONTEXT"
    local f
    for f in "${!CONTEXT[@]}"; do
        [[ -n ${CONTEXT[$f]} ]] && echo "$f=${CONTEXT[$f]}" >>"$DEST/$F_CONTEXT"
    done
    sed -i '/^\s*$/d' "$DEST/$F_CONTEXT"
    echo "# Backup date: $(date)" >>"$DEST/$F_CONTEXT"
    echo "# Version used: $(git log -1 --format="%H")" >>"$DEST/$F_CONTEXT"
} #}}}
#}}}

#--- Wrappers ---- {{{

# By convention methods ending with a '_' wrap shell functions or commands with the same name.

# $1: <exit code>
# $2: <message>
exit_() { #{{{
    [[ -n $2 ]] && message -n -t "$2"
    EXIT=${1:-0}
    exit $EXIT
} #}}}
#}}}

#--- Mounting ---{{{

find_mount_part() { #{{{
    for x in $(echo ${!MOUNTS[@]} | tr ' ' '\n' | sort -r | grep -E '^/' | grep -v -E '^/dev/'); do
        [[ $1 =~ $x ]] && echo $x && return 0
    done
} #}}}

mount_() { #{{{
    local cmd="mount"
    local OPTIND
    local src=$(realpath -s "$1")
    local path

    mkdir -p "${MNTPNT}/$src" && path=$(realpath -s "${MNTPNT}/$src")

    shift
    while getopts ':p:t:o:b' option; do
        case "$option" in
        t)
            ! mountpoint -q  $src && cmd+=" -t $OPTARG"
            ;;
        p)
            path=$(realpath -s "$OPTARG")
            ;;
        b)
            cmd+=" --bind"
            ;;
        o)
            cmd+=" -o $OPTARG"
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

    mountpoint -q $src && cmd+=" --bind"
    logmsg "$cmd $src $path"
    [[ -n ${MNTJRNL["$src"]} && ${MNTJRNL["$src"]} != "$path" ]] && return 1
    [[ -n ${MNTJRNL["$src"]} && ${MNTJRNL["$src"]} == "$path" ]] && return 0
    { $cmd "$src" "$path" && MNTJRNL["$src"]="$path"; } || return 1
} #}}}

umount_() { #{{{
    local OPTIND
    local cmd="umount -l"
    local mnt=$(realpath -s "$1")

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
        local m
        for m in "${MNTJRNL[@]}"; do $cmd -l "$m"; done
        return 0
    fi

    logmsg "$cmd ${MNTJRNL[$mnt]}"
    if [[ -n ${MNTJRNL[$mnt]} ]]; then
        { $cmd ${MNTJRNL[$mnt]} && unset MNTJRNL[$mnt]; } || exit_ 1
    fi
} #}}}

get_mount() { #{{{
    local k=$(realpath -s "$1")
    [[ -z $k || -z ${MNTJRNL[$k]} ]] && return 1
    echo ${MNTJRNL[$k]}
    return 0
} #}}}

mount_chroot() { #{{{
    logmsg "mount_chroot"
    local mp="$1"

    umount_chroot

    local f
    for f in sys dev dev/pts proc run; do
        mount --bind "/$f" "$mp/$f"
    done

    CHROOT_MOUNTS+=("$mp")
} #}}}

umount_chroot() { #{{{
    logmsg "umount_chroot"
    local f
    for f in ${CHROOT_MOUNTS[@]}; do
        umount -Rl "$f"
    done
} #}}}

#}}}

#--- LVM related --{{{
# $1: <vg-name>
# $2: <src-dev>
# $3: <dest-dev>
vg_extend() { #{{{
    logmsg "vg_extend"
    local vg_name="$1"
    local src="$2"
    local dest="$3"
    PVS=()

    if [[ -d $src ]]; then
        src=$(df -P "$src" | tail -1 | awk '{print $1}')
    fi

    while read -r e; do
        local name type
        read -r name type <<<"$e"
        [[ -n $(lsblk -no mountpoint "$name" 2>/dev/null) ]] && continue
        echo ';' | sfdisk -q "$name" && sfdisk "$name" -Vq
        local part=$(lsblk "$name" -lnpo name,type | grep part | awk '{print $1}')
        pvcreate -ff "$part" && vgextend "$vg_name" "$part"
        PVS+=("$part")
    done < <(lsblk -po name,type | grep disk | grep -Ev "$dest|$src")
} #}}}

# $1: <vg-name>
# $2: <Ref. to GLOABAL array holding VG disks>
vg_disks() { #{{{
    logmsg "vg_disks"
    local name=$1
    declare -n disks=$2

    local f
    for f in $(pvs --no-headings -o pv_name,lv_dm_path | grep -E "${name}\-\w+" | awk '{print $1}' | sort -u); do
        disks+=($(lsblk -pnls $f | grep disk | awk '{print $1}'))
    done
} #}}}

#}}}

#--- Registration ---{{{

        add_device_links() { #{{{
            local kdev=$1
            local devlinks=$(find /dev -type l -exec readlink -nf {} \; -exec echo " {}" ';' | grep "$kdev" | awk '{print $2}')
            DEVICE_MAP[$kdev]="$devlinks"
            for d in $devlinks;
                do DEVICE_MAP[$d]=$kdev;
            done
        } #}}}

mounts() { #{{{
    logmsg "mounts"
    if [[ $_RMODE == false ]]; then
        local mp mpnt sdev sid fs spid ptype type mountpoint rest
        local s ldata=$(lsblk -lnpo name,kname,uuid,partuuid $SRC)

        for s in ${!SRCS[@]}; do
            sid=$s
            IFS=: read -r sdev fs spid ptype type mountpoint rest <<<${SRCS[$s]}

            [[ -z ${mountpoint// } ]] && mp="$sdev" || mp="$mountpoint"
            mount_ $mp && mpnt=$(get_mount $mp) || exit_ 1 "Could not mount ${mp}."

            if [[ -f $mpnt/etc/fstab ]]; then
                {
                    local dev mnt fs
                    local name kname uuid partuuid
                    while read -r dev mnt fs; do
                        if [[ ! ${fs// } =~ nfs|swap|udf ]]; then
                            read -r name kname uuid partuuid <<<$(grep -iE "${dev//*=/}\s+" <<<"$ldata") #Ignore -real, -cow

                            if [[ -n ${name// } ]]; then
                                MOUNTS[$mnt]="${uuid}"
                                [[ -n ${name// } ]] && MOUNTS[${name//*=/}]=$mnt
                                [[ -n ${partuuid// } ]] && MOUNTS[${partuuid}]=$mnt
                                [[ -n ${uuid// } ]] && MOUNTS[$uuid]="${mnt}"
                            fi
                        fi
                    done <<<$(grep -E '^[^;#]' "$mpnt/etc/fstab" | awk '{print $1,$2,$3}')
                }
            fi

            umount_ "$mp"
        done
    else
        local files=()
        pushd "$SRC" >/dev/null || return 1

        {
            local file
            for file in [0-9]*; do
                local k=$(echo "$file" | sed "s/\.[a-z]*$//")
                files+=($k)
            done
        }

        local file mpnt i uuid puuid fs type sused dev mnt dir ddev dfs dpid dptype dtype davail user group
        for file in "${files[@]}"; do
            IFS=. read -r i uuid puuid fs type sused dev mnt dir user group <<<"$(pad_novalue $file)"
            mnt=${mnt//_//}

            MOUNTS[${mnt}]="$uuid"
            [[ -n ${dev//NOVALUE/} ]] && MOUNTS[${dev//_//}]=$mnt
            [[ -n ${puuid//NOVALUE/} ]] && MOUNTS[${puuid}]=$mnt
            [[ -n ${uuid//NOVALUE/} ]] && MOUNTS[$uuid]="$mnt"
        done

        popd >/dev/null || return 1
    fi
} #}}}

set_dest_uuids() { #{{{
    logmsg "set_dest_uuids"
    if [[ -b $DEST ]]; then
        [[ $IS_LVM == true ]] && vgchange -an $VG_SRC_NAME_CLONE
        [[ $IS_LVM == true ]] && vgchange -ay $VG_SRC_NAME_CLONE
        udevadm settle
    fi

    local name kdev fstype uuid puuid type parttype mountpoint size e
    while read -r e; do
        read -r name kdev fstype uuid puuid type parttype mountpoint size <<<"$e"
        eval declare "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"

        [[ $FSTYPE == swap ]] && continue
        [[ $UEFI == true && ${PARTTYPE} =~ $ID_GPT_EFI|0x${ID_DOS_EFI} ]] && continue

        [[ $PARTTYPE == 0x5 || $TYPE == crypt || $FSTYPE == crypto_LUKS || $FSTYPE == LVM2_member ]] && continue

        local mp
        [[ -z ${MOUNTPOINT// } ]] && mp="$NAME" || mp="$MOUNTPOINT"
        mount_ "$mp" -t "$FSTYPE" || exit_ 1 "Could not mount ${mp}."

        local used avail
        read -r used avail <<<$(df --block-size=1K --output=used,size "$NAME" | tail -n -1)
        avail=$((avail - used)) #because df keeps 5% for root!
        umount_ "$mp"
        update_dest_order $UUID

        DESTS[$UUID]="${NAME}:${FSTYPE:- }:${PARTUUID:- }:${PARTTYPE:- }:${TYPE:- }:${avail:- }" #Avail to be checked

        # [[ ${PVS[@]} =~ $NAME ]] && continue
    done < <($LSBLK_CMD "$DEST" $([[ $PVALL == true ]] && echo ${PVS[@]}) | grep -vE 'disk|UUID="".*PARTUUID=""')
} #}}}

update_src_order() {
    grep -q "$1" < <(echo ${SRCS_ORDER[*]}) || SRCS_ORDER+=($1)
}

update_dest_order() {
    grep -q "$1" < <(echo ${DESTS_ORDER[*]}) || DESTS_ORDER+=($1)
}

# $1: partition, e.g. /dev/sda1
get_uuid() {
    if [[ $_RMODE == true ]]; then
        ({ eval $(grep -e "$1" $F_PART_LIST); echo $UUID;  })
    else
        local env=$(blkid -o export $1)
        local uuid=$(eval "$env"; echo $UUID)
        echo "$uuid"
    fi
}

# $2: <File with lsblk dump>
init_srcs() { #{{{
    logmsg "init_srcs"
    declare file="$1"

    local name kdev fstype uuid puuid type parttype mountpoint size e
    while read -r e; do
        read -r name kdev fstype uuid puuid type parttype mountpoint size <<<"$e"
        eval declare "$name" "$kdev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"

        add_device_links $KNAME

        [[ $PARTTYPE == 0x5 || $FSTYPE == LVM2_member || $FSTYPE == swap || $TYPE == crypt || $FSTYPE == crypto_LUKS ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue

        if [[ $_RMODE == false ]]; then
            [[ -z ${MOUNTPOINT// } ]] && mp="$NAME" || mp="$MOUNTPOINT"
            mount_ "$mp" -t "$FSTYPE" || exit_ 1 "Could not mount ${mp}."
            mpnt=$(get_mount $mp) || exit_ 1 "Could not find mount journal entry for $mp. Aborting!" #do not use local, $? will be affected!
            local used size
            read -r used <<<$(df -k --output=used "$mpnt" | tail -n -1)
            size=$(sector_to_kbyte $(blockdev --getsz "$NAME"))
            umount_ "$mp"
        fi
        SRCS[$UUID]="${NAME}:${FSTYPE:- }:${PARTUUID:- }:${PARTTYPE:- }:${TYPE:- }:${MOUNTPOINT:- }:${used:- }:${size:- }"
        update_src_order "$UUID"
    done < <(echo "$file" | grep -v 'disk')

    if [[ $_RMODE == true ]]; then
        pushd "$SRC" >/dev/null || return 1
        {
            local f
            for f in [0-9]*; do
                IFS=. read -r i uuid puuid fs type sused dev mnt <<<"$(pad_novalue $f)"
                IFS=: read -r sname sfstype spartuuid sparttype stype mp used size <<<"${SRCS[$uuid]}"
                if [[ $type == part ]]; then
                    sname=$(grep $uuid $F_PART_LIST | awk '{print $1}' | cut -d '"' -f2)
                    size=$(sector_to_kbyte $(grep "$sname" $F_PART_TABLE | grep -o 'size=.*,' | grep -o '[0-9]*'))
                fi
                SRCS[$uuid]="${sname//NOVALUE/}:${sfstype//NOVALUE/}:${spartuuid//NOVALUE/}:${sparttype//NOVALUE/}:${stype//NOVALUE/}:${mp//NOVALUE/}:${sused//NOVALUE/}:${size//NOVALUE/}"
            done
        }
    fi
} #}}}
#}}}

#--- Post cloning ---{{{

# $1: <mount point>
# $2: "<dest-dev>"
# $3: ["<list of packages to install>"]
pkg_install() { #{{{
    logmsg "pkg_install"
    chroot "$1" bash -c "
        DEBIAN_FRONTEND=noninteractive apt-get install -y $3 &&
        grub-install $2 &&
        update-grub &&
        update-initramfs -u -k all" || return 1
} #}}}

# $1: <mount point>
# $2: ["<list of packages to install>"]
pkg_remove() { #{{{
    logmsg "pkg_remove"
    chroot "$1" sh -c "apt-get remove -y $2" || return 1
} #}}}

# $1: <mount point>
create_rclocal() { #{{{
    logmsg "create_rclocal"
    mv "$1/etc/rc.local" "$1/etc/rc.local.bak" 2>/dev/null
    printf '%s' '#! /usr/bin/env bash
    update-grub
    rm /etc/rc.local
    mv /etc/rc.local.bak /etc/rc.local 2>/dev/null
    sleep 10
    reboot' >"$1/etc/rc.local"
    chmod +x "$1/etc/rc.local"
} #}}}

#}}}

#--- Validation ---{{{

# $1: <dest-dev>
# $2: <checksum file>
create_m5dsums() { #{{{
    logmsg "create_m5dsums"
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
    logmsg "validate_m5dsums"
    local src="$1"
    local file="$2"
    pushd "$src" || return 1
    md5sum -c "$file" --quiet || return 1
    popd || return 1
} #}}}

#}}}

#--- Disk and partition setup ---{{{

sync_block_dev() { #{{{
    logmsg "sync_block_dev"
    sleep 3
    udevadm settle && blockdev --rereadpt "$1" && udevadm settle
} #}}}

# $1: <password>
# $2: <dest-dev>
# $3: <luks lvm name>
encrypt() { #{{{
    logmsg "encrypt"
    local passwd="$1"
    local dest="$2"
    local name="$3"

    local size type
    if [[ $HAS_EFI == true ]]; then
        if [[ $_RMODE == true ]]; then
            {
                echo -e "$(cat $F_PART_TABLE | tr -d ' ' | grep -o "size=[0-9]*,type=${ID_GPT_EFI^^}")\n;" \
                | sfdisk --label gpt "$dest";
            } || return 1
        else
            read -r size type <<<$(sfdisk -l -o Size,Type-UUID $SRC | grep ${ID_GPT_EFI^^})
            { echo -e "size=$size, type=$type\n;" | sfdisk --label gpt "$dest"; } || return 1
        fi
    elif [[ $UEFI == true ]]; then
        { echo ';' | sfdisk "$DEST"; }
        mbr2gpt $DEST && HAS_EFI=true
        read -r size type <<<$(sfdisk -l -o Size,Type-UUID $DEST | grep ${ID_GPT_EFI^^})
    else
        { echo ';' | sfdisk "$dest"; } || return 1 #delete all partitions and create one for the whole disk.
    fi

    sleep 3
    ENCRYPT_PART=$(sfdisk -qlo device "$dest" | tail -n 1)
    echo -n "$passwd" | cryptsetup luksFormat "$ENCRYPT_PART" --type luks1 -
    echo -n "$passwd" | cryptsetup open "$ENCRYPT_PART" "$name" --type luks1 -
} #}}}

# $1: <src-sectors>
# $2: <dest-sectors>
# $3: <file with partition table dump>
# $4: <REF for result data>
expand_disk() { #{{{
    logmsg "expand_disk"
    local src_size=$1
    local dest_size=$2
    local size
    local new_size
    local swap_size=0
    local pdata="$3"
    local src_boot_size=$(echo "$pdata" | grep "$BOOT_PART" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
    declare -n pdata_new=$4

    declare -A val_parts #Partitions with fixed sizes
    declare -A var_parts #Partitions to be expanded

    _size() { #{{{
        local part=$1
        local part_size=$2
        #Substract the swap partition size
        [[ $part_size -le 0 ]] && part_size=$(echo "$pdata" | grep "$part" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
        src_size=$((src_size - part_size))
        dest_size=$((dest_size - part_size))
    } #}}}

    [[ -n $SWAP_PART  ]] && _size $SWAP_PART $SWAP_SIZE
    [[ -n $BOOT_PART  ]] && _size $BOOT_PART $BOOT_SIZE
    [[ -n $EFI_PART  ]] && _size $EFI_PART 0

    local expand_factor=$(echo "scale=4; $dest_size / $src_size" | bc)

    if [[ $SWAP_SIZE -eq 0 && -n $SWAP_PART ]]; then
        local swap_part=${SWAP_PART////\\/} #Escape for sed interpolation
        pdata=$(echo "$pdata" | sed "/$swap_part/d")
    fi

    local n=0
    {
        while read -r name size; do
            if [[ (-n $BOOT_PART && $name == "$BOOT_PART") ||
                (-n $SWAP_PART && $name == "$SWAP_PART") ||
                (-n $EFI_PART && $name == "$EFI_PART") ]]
            then
                val_parts[$name]=${size%,*}
            else
                var_parts[$name]=${size%,*}
                ((n++))
            fi
        done < <(echo "$pdata" | grep '^/' | awk '{print $1,$6}')
    }

    {
        local k
        for k in "${!var_parts[@]}"; do
            local nv=$(echo "${var_parts[$k]} * $expand_factor" | bc)
            var_parts[$k]=${nv%.*}
        done
    }

    {
        while read -r e; do
            local size=$(echo "$e" | sed -E 's/.*size=\s*([0-9]*).*/\1/')
            local part=$(echo "$e" | awk '{print $1}')

            if [[ -n "$size" ]]; then
                if [[ $part == "$SWAP_PART" || $part == "$BOOT_PART" || $part == "$EFI_PART" ]]; then
                    pdata=$(sed "s/$size/${val_parts[$part]}/" < <(echo "$pdata"))
                else
                    [[ $(sector_to_mbyte $size) -le "$MIN_RESIZE" ]] && continue
                    pdata=$(sed "s/$size/${var_parts[$part]}/" < <(echo "$pdata"))
                fi
            fi
        done < <(echo "$pdata" | grep '^/')
    }

    #Remove fixed offsets and only apply size values. We assume the extended partition ist last!
    pdata=$(sed 's/start=\s*\w*,//g' < <(echo "$pdata"))
    #When a field is absent or empty the default value of size indicates "as much as asossible";
    #Therefore we remove the size for extended partitions
    pdata=$(sed '/type=5/ s/size=\s*\w*,//' < <(echo "$pdata"))
    #and the last partition, if it is not swap or swap should be erased.
    local last_line=$(echo "$pdata" | tail -1 | sed -n -e '$ ,$p')
    if [[ $SWAP_SIZE -eq 0 && $last_line =~ $swap_part || ! $last_line =~ $SWAP_PART ]]; then
        pdata=$(sed '$ s/size=\s*\w*,//g' < <(echo "$pdata"))
    fi

    #Finally remove some headers
    pdata=$(sed '/last-lba:/d' < <(echo "$pdata"))

    _set_type() {
        local p="$1"
        case $TABLE_TYPE in
        dos)
            pdata=$(sed "\|$p| s/type=\w*/type=8e/" < <(echo "$pdata"))
            ;;
        gpt)
            pdata=$(sed "\|$p| s/type=\([[:alnum:]]*-\)*[[:alnum:]]*/type=${ID_GPT_LVM^^}/" < <(echo "$pdata"))
            ;;
        *)
            exit_ 1 "Unsupported partition table $TABLE_TYPE."
            ;;
        esac
    }

    {
        local p
        for p in ${!TO_LVM[@]}; do
            _set_type "$p"
        done
    }

	if [[ $HAS_LUKS == true ]]; then
		[[ $HAS_EFI == true ]] && pdata=$(sed "s/${ID_GPT_LINUX^^}/${ID_GPT_LVM^^}/" < <(echo "$pdata"))
		[[ $(grep -E '^/' < <(echo "$pdata") | wc -l ) -eq 1 ]] && _set_type " "
	fi

	pdata_new="$pdata"
    return 0
} #}}}

# $1: <dest-dev>
mbr2gpt() { #{{{
    logmsg "mbr2gpt"
    local dest="$1"
    local overlap=$(echo q | gdisk "$dest" | grep -E '\d*\s*blocks!' | awk '{print $1}')
    local pdata=$(sfdisk -d "$dest")

    if [[ $overlap -gt 0 ]]; then
        local sectors=$(echo "$pdata" | tail -n 1 | grep -o -P 'size=\s*(\d*)' | awk '{print $2}')
        sfdisk "$dest" < <(echo "$pdata" | sed -e "$ s/$sectors/$((sectors - overlap))/")
    fi

    sync_block_dev "$dest"
    sgdisk -z "$dest"
    sgdisk -g "$dest"
    sync_block_dev "$dest"

    pdata=$(sfdisk -d "$dest")
    pdata=$(echo "$pdata" | grep 'size=' | sed -e 's/^[^,]*,\s*//; s/uuid=[a-Z0-9-]*,\{,1\}//')
    pdata=$(echo -e "size=1024000, type=${ID_GPT_EFI^^}\n${pdata}")
    local size=$(echo "$pdata" | grep -o -P 'size=\s*(\d*)' | awk '{print $2}' | tail -n 1)
    pdata=$(echo "$pdata" | sed -e "s/$size/$((size - 1024000))/") #TODO what if n partitions with the same size?

    sfdisk "$dest" < <(echo "$pdata")
    sync_block_dev "$dest"
} #}}}

# $1: <file with lsblk dump>
# $2: <src-dev>
# $3: <dest-dev>
disk_setup() { #{{{
    logmsg "disk_setup"
    declare parts=() pvs_parts=()
    local file="$1"
    local src="$2"
    local dest="$3"

    #Collect all source paritions and their file systems
    _scan_src_parts() { #{{{
        local plist=$( echo "$file" \
            | grep 'TYPE="part"' \
            | grep -vE 'PARTTYPE="0x5"'
        )

        while read -r e; do
            read -r name kname fstype uuid partuuid type parttype mountpoint <<<"$e"
            eval "$name" "$kname" "$fstype" "$uuid" "$partuuid" "$type" "$parttype" "$mountpoint"

            [[ $SWAP_SIZE -eq 0 && $FSTYPE == swap ]] && continue

            if [[ $TYPE == part && $FSTYPE != crypto_LUKS ]]; then
                parts+=("${NAME}:${FSTYPE}")
            fi
        done < <(echo "$plist")
    } #}}}

    #Create file systems (including swap) or pvs volumes.
    _create_dests() { #{{{
        local plist=""
        plist=$(
            lsblk -Ppo NAME,KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE "$dest" \
                | grep -vE 'PARTTYPE="0x5"' \
                | grep -vE 'TYPE="disk"'
        ) #only partitions

        local name kname fstype uuid partuuid type parttype sname sfstype e n=0
        while read -r e; do
            read -r name kname fstype uuid partuuid type parttype <<<"$e"
            eval "$name" "$kname" "$fstype" "$uuid" "$partuuid" "$type" "$parttype"

            IFS=: read -r sname sfstype <<<${parts[$n]}

            if [[ $sfstype == swap ]]; then
                mkswap -f "$NAME" && continue
            elif [[ ${PARTTYPE} =~ $ID_GPT_LVM|0x${ID_DOS_LVM} ]]; then #LVM
                pvcreate -ff "$NAME"
            elif [[ ${PARTTYPE} =~ $ID_GPT_EFI|0x${ID_DOS_EFI} ]]; then #EFI
                mkfs -t vfat "$NAME"
                [[ $UEFI == true ]] && continue
            elif [[ -n ${sfstype// } ]]; then
                mkfs -t "$sfstype" "$NAME"
            else
                return 1
            fi
            n=$((n + 1))
        done < <(echo "$plist")
    } #}}}

    _scan_src_parts
    _create_dests
    sync_block_dev "$dest"
} #}}}

# $1: <Ref.>
# $2: <dest-mount>
boot_setup() { #{{{
    logmsg "boot_setup"
    declare -n sd="$1"
    declare dmnt="$2"

    local path=(
        "/cmdline.txt"
        "/etc/fstab"
        "/grub/grub.cfg"
        "/boot/grub/grub.cfg"
        "/etc/initramfs-tools/conf.d/resume"
    )

    local k d uuid fstype
    for k in "${!sd[@]}"; do
        for d in "${DESTS[@]}"; do
            sed -i "s|$k|${sd[$k]}|" \
                "$dmnt/${path[0]}" "$dmnt/${path[1]}" \
                "$dmnt/${path[2]}" "$dmnt/${path[3]}" \
                2>/dev/null

            #Resume file might be wrong, so we just set it explicitely
            if [[ -e $dmnt/${path[4]} ]]; then
                local name uuid fstype
                read -r name uuid fstype type <<<$(lsblk -lnpo name,uuid,fstype,type "$DEST" | grep 'swap')
                local rplc
                if [[ -z $name ]]; then
                    rplc="RESUME="
                elif [[ $type == lvm ]]; then
                    #For some reson UUID with LVM does not work, though update-initramfs will not complain.
                    rplc="RESUME=$name"
                else
                    rplc="RESUME=UUID=$uuid"
                fi
                sed -i -E "/RESUME=none/!s|^RESUME=.*|$rplc|i" "$dmnt/${path[4]}" #We don't overwrite none
            fi

            if [[ -e $dmnt/${path[1]} ]]; then
                #Make sure swap is set correctly.
                if [[ $SWAP_SIZE -eq 0 ]]; then
                    sed -i '/swap/d' "$dmnt/${path[1]}"
                else
                    read -r fstype uuid <<<$(lsblk -lnpo fstype,uuid "$DEST" ${PVS[@]} | grep '^swap')
                    sed -i -E "/\bswap/ s/[^ ]*/UUID=$uuid/" "$dmnt/${path[1]}"
                fi
            fi
        done
    done
} #}}}

# $1: <destination to mount>
# $2: <has efi> true|false
# $3: <add efi partition to fstab> true|false
# $4: <dest-dev>
grub_setup() { #{{{
    logmsg "grub_setup"
    local d="$1"
    local has_efi=$2
    local uefi=$3
    local dest="$4"
    local mp
    local resume=$(lsblk -lpo name,fstype $DEST | grep swap | awk '{print $1}')

    mount_ "$d"
    mp=$(get_mount $d) || exit_ 1 "Could not find mount journal entry for $d. Aborting!" #do not use local, $? will be affected!

    sed -i -E '/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*[^\"]||' "$mp/etc/default/grub"
    sed -i -E "/GRUB_CMDLINE_LINUX_DEFAULT=/ s|resume=[^ \"]*|resume=$resume|" "$mp/etc/default/grub"
    sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=n/' "$mp/etc/default/grub"
    sed -i 's/^/#/' "$mp/etc/crypttab"
    mount_chroot "$mp"

    {
        local m ddev rest
        for m in $(echo ${!MOUNTS[@]} | tr ' ' '\n' | grep -E '^/' | grep -vE '^/dev' | sort -u); do
            if [[ -n ${SRC2DEST[${MOUNTS[$m]}]} ]]; then
                IFS=: read -r ddev rest <<<${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}
                mount_ $ddev -p "$mp/$m" || exit_ 1 "Failed to mount $ddev to ${mp/$m}."
            fi
        done
    }

    {
        if [[ $uefi == true && $has_efi == true ]]; then
            local name uuid parttype
            read -r name uuid parttype <<<"$(lsblk -pPo name,uuid,parttype "$dest" | grep -i $ID_GPT_EFI)"
            eval "$name" "$uuid" "$parttype"
            echo -e "UUID=${UUID}\t/boot/efi\tvfat\tumask=0077\t0\t1" >>"$mp/etc/fstab"
            mkdir -p "$mp/boot/efi" && mount_ "$NAME" -p "$mp/boot/efi"
        fi
    }

    {
        local d
        for d in ${DISABLED_MOUNTS[@]}; do
            sed -i "\|\s$d\s| s|^|#|" "$mp/etc/fstab"
        done
    }

    if [[ $has_efi == true ]]; then
        local apt_pkgs="grub-efi-amd64-signed shim-signed"
    else
        local apt_pkgs="grub-pc"
    fi

    pkg_remove "$mp" "$REMOVE_PKGS" || return 1
    pkg_install "$mp" "$dest" "$apt_pkgs" || return 1

    create_rclocal "$mp"
    umount_chroot
    return 0
} #}}}

# $1: <password>
# $2: <destination to mount>
# $3: <dest-dev>
# $4: <luks_lvm_name>
# $5: <encrypt_part>
crypt_setup() { #{{{
    logmsg "crypt_setup"
    local passwd="$1"
    local d="$2"
    local dest="$3"
    local luks_lvm_name="$4"
    local encrypt_part="$5"
    local mp="${MNTPNT}/$d"

    mount_ "$d" && { mpnt=$(get_mount $d) || exit_ 1 "Could not find mount journal entry for $d. Aborting!"; }
    mount_chroot "$mp"

    {
        local m ddev rest
        for m in $(echo ${!MOUNTS[@]} | tr ' ' '\n' | grep -E '^/' | grep -vE '^/dev' | sort -u); do
            if [[ -n ${SRC2DEST[${MOUNTS[$m]}]} ]]; then
                IFS=: read -r ddev rest <<<${DESTS[${SRC2DEST[${MOUNTS[$m]}]}]}
                mount_ $ddev -p "$mp/$m" || exit_ 1 "Failed to mount $ddev to ${mp/$m}."
            fi
        done
    }

    {
        if [[ $UEFI == true && $HAS_EFI == true ]]; then
            local name uuid parttype
            read -r name uuid parttype <<<"$(lsblk -pPo name,uuid,parttype "$DEST" | grep -i $ID_GPT_EFI)"
            eval "$name" "$uuid" "$parttype"
            echo -e "UUID=${UUID}\t/boot/efi\tvfat\tumask=0077\t0\t1" >>"$mp/etc/fstab"
            mkdir -p "$mp/boot/efi" && mount_ "$NAME" -p "$mp/boot/efi"
        fi
    }

    local apt_pkgs=(cryptsetup keyutils)

    if [[ $HAS_EFI == true ]]; then
        apt_pkgs+=(grub-efi-amd64)
    else
        apt_pkgs+=(grub-pc)
    fi

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

    sed -i -E '/GRUB_CMDLINE_LINUX=/ s|[a-z=]*UUID=[-0-9a-Z]*[^ ]*[^\"]||' "$mp/etc/default/grub"

    grep -q 'GRUB_CMDLINE_LINUX' "$mp/etc/default/grub" \
        && sed -i -E "/GRUB_CMDLINE_LINUX=/ s|\"(.*)\"|\"cryptdevice=UUID=$(cryptsetup luksUUID $encrypt_part):$luks_lvm_name \1\"|" "$mp/etc/default/grub" \
        || echo "GRUB_CMDLINE_LINUX=cryptdevice=UUID=$(cryptsetup luksUUID $encrypt_part):$luks_lvm_name" >>"$mp/etc/default/grub"

    grep -q 'GRUB_ENABLE_CRYPTODISK' "$mp/etc/default/grub" \
        && sed -i -E '/GRUB_ENABLE_CRYPTODISK=/ s/=./=y/' "$mp/etc/default/grub" \
        || echo "GRUB_ENABLE_CRYPTODISK=y" >>"$mp/etc/default/grub"

    sed -i -E "/GRUB_CMDLINE_LINUX_DEFAULT=/ s|resume=[^ \"]*|resume=$resume|" "$mp/etc/default/grub"

    pkg_remove "$mp" "$REMOVE_PKGS" || return 1
    pkg_install "$mp" "$dest" "${apt_pkgs[*]}" || return 1

    create_rclocal "$mp"
    umount_chroot
} #}}}

# $1: <full path>
# $2: <type>
# $3: <size>
create_image() { #{{{
    logmsg "create_image"
    local img="$1"
    local type="$2"
    local size="$3"
    local options=""

    case "$type" in
    vdi)
        options="$options -o static=on"
        ;;
    esac
    qemu-img create -f $type $options $img $size || return 1
} #}}}
#}}}

#--- Value conversion and calculation --- {{{

# $1: <file>
pad_novalue() { #{{{
    local file="$1"
    while echo "$file" | sed '/\.\./!{q10}' > /dev/null; do
        file=$(echo "$file" | sed 's/\.\./\.NOVALUE\./')
    done
    echo "$file"
} #}}}

# $1: <bytes>
to_readable_size() { #{{{
    local size=$(to_byte $1)
    local dimension=B

    local d
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
    local np p=$1
    [[ $p =~ ^[0-9]+K ]] && echo $((${p%[a-zA-Z]} * 2 ** 10))
    [[ $p =~ ^[0-9]+M ]] && echo $((${p%[a-zA-Z]} * 2 ** 20))
    [[ $p =~ ^[0-9]+G ]] && echo $((${p%[a-zA-Z]} * 2 ** 30))
    [[ $p =~ ^[0-9]+T ]] && echo $((${p%[a-zA-Z]} * 2 ** 40))
    { [[ $p =~ ^[0-9]+$ ]] && echo $p; } || return 1
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_kbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 10))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_mbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 20))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_gbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 30))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_tbyte() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 2 ** 40))
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
validate_size() { #{{{
    [[ $1 =~ ^[0-9]+(K|M|G|T) ]] && return 0 || return 1
} #}}}

# $1: <bytes> | <number>[K|M|G|T]
to_sector() { #{{{
    local v=$1
    validate_size "$v" && v=$(to_byte "$v")
    echo $((v / 512))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_kbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / 2))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_mbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / (2 * 2 ** 10)))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_gbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / (2 * 2 ** 20)))
} #}}}

# $1: <sectos> of 512 Bytes
sector_to_tbyte() { #{{{
    local v=$1
    [[ ! $v =~ ^[0-9]+$ ]] && return 1
    echo $((v / (2 * 2 ** 30)))
} #}}}
#}}}
#}}}

# PUBLIC - To be used in Main() only ----------------------------------------------------------------------------------{{{

Cleanup() { #{{{
    {
        logmsg "Cleanup"
        if [[ $IS_CLEANUP == true ]]; then
            umount_
            [[ $SCHROOT_HOME =~ ^/tmp/ ]] && rm -rf "$SCHROOT_HOME" #TODO add option to overwrite and show warning
            rm "$F_SCHROOT_CONFIG"
            [[ $VG_SRC_NAME_CLONE && -b $DEST ]] && vgchange -an "$VG_SRC_NAME_CLONE"
            [[ $ENCRYPT_PWD ]] && cryptsetup close "/dev/mapper/$LUKS_LVM_NAME"

            [[ -n $DEST_IMG ]] && qemu-nbd -d $DEST_NBD
            if [[ -n $SRC_IMG ]]; then
                vgchange -an ${VG_SRC_NAME}
                qemu-nbd -d $SRC_NBD
            fi

            find "$MNTPNT" -xdev -depth -type d -empty ! -exec mountpoint -q {} \; -exec rmdir {} \;
            rmdir "$MNTPNT"
        fi
        systemctl --runtime unmask sleep.target hibernate.target suspend.target hybrid-sleep.target
        lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE" &>/dev/null
    } &>/dev/null

    #Check if system files have been changed for execution and restore
    local f failed=()
    for f in "${!CHG_SYS_FILES[@]}"; do
        if [[ ${CHG_SYS_FILES["$f"]} == $(md5sum "${BACKUP_FOLDER}/${f}" | awk '{print $1}') ]]; then
            cp "${BACKUP_FOLDER}/${f}" "$f"
        else
            failed+=("$f")
        fi
    done
    [[ ${#failed[@]} -gt 0 ]] && message -n -t "Backups of original file(s) ${f[*]} changed. Will not restore. Check ${BACKUP_FOLDER}."

    exec 1>&3
    tput cnorm

    exec 200>&-
    exit "$EXIT" #Make sure we really exit the script!
} #}}}

To_file() { #{{{
    logmsg "To_file"
    if [ -n "$(ls "$DEST")" ]; then return 1; fi

    pushd "$DEST" >/dev/null || return 1

    _save_disk_layout() { #{{{
        logmsg "To_file@_save_disk_layout"
        local snp=$(
            sudo lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role \
                | grep 'snap' \
                | sed -e 's/^\s*//' \
                | awk '{print $1}'
        )

        [[ -z $snp ]] && snp="NOSNAPSHOT"

        {
            pvs --noheadings -o pv_name,vg_name,lv_active \
                | grep 'active$' \
                | sed -e 's/active$//;s/^\s*//' \
                | uniq \
                | grep -E "\b$VG_SRC_NAME\b" >$F_PVS_LIST

            vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free,lv_active \
                | grep 'active$' \
                | sed -e 's/active$//;s/^\s*//' \
                | uniq \
                | grep -E "\b$VG_SRC_NAME\b" >$F_VGS_LIST

            lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role,lv_dm_path \
                | grep -v 'snap' \
                | grep 'active public.*' \
                | sed -e 's/^\s*//; s/\s*$//' \
                | grep -E "\b$VG_SRC_NAME\b"  >$F_LVS_LIST

            SECTORS_SRC="$(blockdev --getsz $SRC)"
            ctx_set SECTORS_SRC
            sfdisk -d "$SRC" >"$F_PART_TABLE"
        }

        sleep 3 #IMPORTANT !!! So changes by sfdisk can settle.
        #Otherwise resultes from lsblk might still show old values!
        $LSBLK_CMD "$SRC" | grep -v "$snp" >"$F_PART_LIST"
    } #}}}

    message -c -t "Creating backup of disk layout"
    {
        _save_disk_layout
        init_srcs "$($LSBLK_CMD ${VG_DISKS[@]:-$SRC})"
        local av=""
        for k in "${!DEVICE_MAP[@]}"; do av+="[$k]=\"${DEVICE_MAP[$k]}\" "; done
        echo "DEVICE_MAP=($av)" > $F_DEVICE_MAP
        mounts
    }
    message -y

    if [[ $IS_LVM ]]; then
        local VG_SRC_NAME=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | awk '{print $2}')
        if [[ -z $VG_SRC_NAME ]]; then
            while read -r e g; do
                grep -q "${SRC##*/}" < <(dmsetup deps -o devname "$e" | sed 's/.*(\(\w*\).*/\1/g') && VG_SRC_NAME="$g"
            done < <(pvs --noheadings -o pv_name,vg_name | xargs)
        fi

        local lvs_data=$(lvs --noheadings -o lv_name,lv_dm_path,vg_name \
            | grep "\b${VG_SRC_NAME}\b"
        )

        local src_vg_free=$( vgs --noheadings --units m --nosuffix -o vg_name,vg_free \
            | grep "\b${VG_SRC_NAME}\b" \
            | awk '{print $2}'
        )
    fi

    local s g=0 mpnt  sdev fs spid ptype type used size

    _copy() { #{{{
        local sdev="$1" mpnt="$2" file="$3" excludes=()
        local cmd="tar --warning=none --atime-preserve=system --numeric-owner --xattrs --directory=$mpnt"

        [[ -n $4 ]] && excludes=(${EXCLUDES[$4]//:/ })

        if [[ -z $excludes ]]; then
            cmd="$cmd --exclude=run/* --exclude=/tmp/* --exclude=/proc/* --exclude=/dev/* --exclude=/sys/*"
        else
            for ex in ${excludes[@]}; do
                cmd="$cmd --exclude=$ex"
            done
        fi

        if [[ $INTERACTIVE == true ]]; then
            message -u -c -t "Creating backup for $sdev [ scan ]"
            local size=$(du --bytes --exclude=/run/* --exclude=/tmp/* --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* -s $mpnt | awk '{print $1}')
            if [[ $SPLIT == true ]]; then
                cmd="$cmd -Scpf - . | pv --interval 0.5 --numeric -s $size | split -b 1G - $file"
            else
                cmd="$cmd -Scpf - . | pv --interval 0.5 --numeric -s $size > $file"
            fi

            local e
            while read -r e; do
                [[ $e -ge 100 ]] && e=100 #Just a precaution
                message -u -c -t "Creating backup for $sdev [ $(printf '%02d%%' $e) ]"
            done < <(eval "$cmd" 2>&1)                                              #Note that with pv stderr holds the current percentage value!
            message -u -c -t "Creating backup for $sdev [ $(printf '%02d%%' 100) ]" #In case we very faster than the update interval of pv, especially when at 98-99%.
        else
            message -c -t "Creating backup for $sdev"
            if [[ $SPLIT == true ]]; then
                cmd="$cmd -Scpf - . | split -b 1G - $file"
            else
                cmd="$cmd -Scpf $file ."
            fi
            eval "$cmd"
        fi
        message -y
        g=$((g + 1))
    } #}}}

    for s in ${!SRCS[@]}; do
        local tdev sid=$s
        IFS=: read -r sdev fs spid ptype type mountpoint used size <<<${SRCS[$s]}
        local mount=${MOUNTS[$sid]:-${MOUNTS[$spid]}}

        if [[ $type == lvm ]]; then
            local lv_src_name=$(grep $sdev <<<"$lvs_data" | awk '{print $1}')
        fi

        if [[ $type == lvm && "${src_vg_free%%.*}" -ge "500" ]]; then
            tdev="/dev/${VG_SRC_NAME}/$SNAP4CLONE"
            lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE" &>/dev/null #Just to be sure
            lvcreate -l100%FREE -s -n $SNAP4CLONE "${VG_SRC_NAME}/$lv_src_name"
        else
            [[ -z ${mountpoint// } ]] && tdev="$sdev" || tdev="$mountpoint"
        fi

        mount_ "$tdev" || exit_ 1 "Could not mount ${tdev}."
        mpnt=$(get_mount "$tdev")  || exit_ 1 "Could not find mount journal entry for $tdev. Aborting!"

        [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

        sid=${sid// }
        spid=${spid// }
        local file="${g}.${sid// }.${spid// }.${fs// }.${type// }.${used}.${sdev//\//_}.${mount//\//_}"

        _copy "$sdev" $mpnt "$file"

        for em in ${!EXT_PARTS[@]}; do
            local l=${MOUNTS[$s]}
            local e=${EXT_PARTS[$em]}

            if [[ $l == $(find_mount_part $em ) ]]; then
                local user password
                read -r user password <<<${CHOWN[$em]/:/ }

                mount_ "$e"
                local mpnt_e=$(get_mount $e) || exit_ 1 "Could not find mount journal entry for $e. Aborting!"
                file="${g}.${sid// }.${spid// }.${fs// }.${type// }.${used}.${sdev//\//_}.${mount//\//_}.${em//\//_}.${user}.${password}"

                _copy "$e" "$mpnt_e" "$file" "$em"
                umount_ "$e"
            fi
        done

        [[ -f $mpnt/grub/grub.cfg || -f $mpnt/grub.cfg || -f $mpnt/boot/grub/grub.cfg ]] && HAS_GRUB=true
        umount_ "$tdev"
        [[ $type == lvm ]] && lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE"

    done

    popd >/dev/null || return 1

    ctx_set SECTORS_SRC_USED
    ctx_set BOOT_PART
    ctx_set IS_LVM
    ctx_set TABLE_TYPE
    ctx_set HAS_GRUB
    ctx_save

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
    logmsg "Clone"
    local OPTIND

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
        logmsg "[ Clone ] _lvm_setup"
        local s1 s2
        local dest=$1
        declare -A src_lfs

        vgcreate "$VG_SRC_NAME_CLONE" $(pvs --noheadings -o pv_name | grep "$dest" | tr -d ' ')
        [[ $PVALL == true ]] && vg_extend "$VG_SRC_NAME_CLONE" "$SRC" "$DEST"

        local lvs_cmd='lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role,lv_dm_path'
        local lvm_data=$({ [[ $_RMODE == true ]] && cat "$SRC/$F_LVS_LIST" || $lvs_cmd; } | grep -E "\b$VG_SRC_NAME\b")

        local vg_data=$(vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free | grep -E "\b$VG_SRC_NAME\b|\b$VG_SRC_NAME_CLONE\b")
        [[ $_RMODE == true ]] && vg_data=$(echo -e "$vg_data\n$(cat $SRC/$F_VGS_LIST)")

        declare -i fixd_size_dest=0
        declare -i fixd_size_src=0

        _create_fixed() { #{{{ TODO works, but should be factored out to avoid multiple nesting!
            local part="$1"
            local part_size=$2

            for d in ${DEVICE_MAP[$part]}; do
                if echo "$lvm_data" | grep -q "$d\|$part"; then
                    local name size
                    read -r name size <<<$(echo "$lvm_data" | grep "$d\|$part" | awk '{print $1, $3}')
                    local part_size_src=${size%%.*}
                    local part_size_dest=${size%%.*}

                    [[ $part_size -ge 0 ]] && part_size_dest=$(to_mbyte ${part_size}K)

                    if [[ $part_size_dest -gt 0 ]]; then
                        fixd_size_src+=$part_size_src
                        fixd_size_dest+=$part_size_dest
                        lvcreate --yes -L$part_size_dest -n "$name" "$VG_SRC_NAME_CLONE"
                    fi
                fi
            done

            if [[ -n ${TO_LVM[$part]} ]]; then
                local partid=$(get_uuid $part)
                local lv_name=${TO_LVM[$part]}
                IFS=: read -r sname fs spid ptype type mp used size <<<"${SRCS[$partid]}"
                size=$(to_mbyte ${size}K)
                local part_size_src=${size%%.*}
                local part_size_dest=${size%%.*}

                [[ $part_size -ge 0 ]] && part_size_dest=$(to_mbyte ${part_size}K)

                if [[ $part_size_dest -gt 0 ]]; then
                    fixd_size_src+=$part_size_src
                    fixd_size_dest+=$part_size_dest
                    lvcreate --yes -L$part_size_dest -n $lv_name "$VG_SRC_NAME_CLONE"
                fi
            fi
        } #}}}

        [[ -n $SWAP_PART ]] && _create_fixed "$SWAP_PART" $SWAP_SIZE
        [[ -n $BOOT_PART ]] && _create_fixed "$BOOT_PART" $BOOT_SIZE

        {
            local vg_name vg_size vg_free e src_vg_free
            while read -r e; do
                read -r vg_name vg_size vg_free <<<"$e"
                [[ $vg_name == "$VG_SRC_NAME" ]] && s1=$((${vg_size%%.*} - ${vg_free%%.*} - $fixd_size_src)) && src_vg_free=${vg_free%%.*}
                [[ $vg_name == "$VG_SRC_NAME_CLONE" ]] && s2=$((${vg_free%%.*} - $fixd_size_dest - $VG_FREE_SIZE))
            done < <(echo "$vg_data")
            [[ $VG_FREE_SIZE -eq 0  ]] && s2=$((s2 - src_vg_free))
        }

        {
            local sname fs spid ptype type used mp size f lsize lv_size
            for f in ${!SRCS[@]}; do
                IFS=: read -r sname fs spid ptype type mp used size <<<"${SRCS[$f]}"
                if grep -qE "${sname}" < <(echo "${!TO_LVM[@]}" | tr ' ' '\n'); then
                    lv_size=$(to_mbyte ${size}K)
                    s2=$((s2 - lv_size))
                fi
            done
        }

        if [[ $ALL_TO_LVM == true && $IS_LVM == false ]]; then
        {
            local vg_name vg_size vg_free e src_vg_free
            while read -r e; do
                read -r vg_name vg_size vg_free <<<"$e"
                [[ $vg_name == "$VG_SRC_NAME_CLONE" ]] && s2=$((${vg_free%%.*} - $fixd_size_dest - $VG_FREE_SIZE))
            done < <(echo "$vg_data")
            [[ $VG_FREE_SIZE -eq 0  ]] && s2=$((s2 - src_vg_free))
            local name kdev fstype uuid puuid type parttype mountpoint size

            local f=$({ [[ $_RMODE == true ]] && cat "$SRC/$F_PART_LIST" || $LSBLK_CMD "$SRC"; } | grep 'SWAP')
            read -r name kdev fstype uuid puuid type parttype mountpoint size <<<"$f"
            eval declare "$name" "$kdev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"
            src_swap=$(to_mbyte $SIZE)
            s1=$(sector_to_mbyte $SECTORS_SRC)
            s1=$((s1 - src_swap))
        }
        fi

        scale_factor=$(echo "scale=4; $s2 / $s1" | bc)

        {
            local lv_name vg_name lv_size vg_size vg_free lv_active lv_role lv_dm_path e size
            while read -r e; do
                read -r lv_name vg_name lv_size vg_size vg_free lv_active lv_role lv_dm_path <<<"$e"
                if [[ $vg_name == $VG_SRC_NAME && -n $VG_SRC_NAME ]]; then
                    [[ $lv_dm_path == "$SWAP_PART" ]] && continue
                    [[ -n $LVM_EXPAND && $lv_name == "$LVM_EXPAND" ]] && continue
                    [[ $lv_role =~ snapshot ]] && continue

                    if ((s1 < s2)); then
                        lvcreate --yes -L"${lv_size%%.*}" -n "$lv_name" "$VG_SRC_NAME_CLONE"
                    else
                        size=$(echo "scale=4; $lv_size * $scale_factor" | bc)
                        lvcreate --yes -L${size%%.*} -n "$lv_name" "$VG_SRC_NAME_CLONE"
                    fi
                fi
            done < <(echo "$lvm_data")
        }


        {
            local sname fs spid ptype type mp used size f lsize lv_size
            for f in "${!SRCS[@]}"; do
                IFS=: read -r sname fs spid ptype type mp used size <<<"${SRCS[$f]}"
                if [[ -n ${TO_LVM[$sname]} && $sname != $BOOT_PART ]] ; then
                    lv_size=$(to_mbyte ${size}K) #TODO to_mbyte should be able to deal with floats
                    if ((s1 < s2)); then
                        lvcreate --yes -L"${lv_size%%.*}" -n "${TO_LVM[$sname]}" "$VG_SRC_NAME_CLONE"
                    else
                        lsize=$(echo "scale=4; $lv_size * $scale_factor" | bc)
                        lvcreate --yes -L${lsize%%.*} -n "${TO_LVM[$sname]}" "$VG_SRC_NAME_CLONE"
                    fi
                fi
            done
        }

        [[ -n $LVM_EXPAND ]] && lvcreate --yes -l"${LVM_EXPAND_BY:-100}%FREE" -n "$LVM_EXPAND" "$VG_SRC_NAME_CLONE"

        {
            local name fs pid ptype type mp used size s
            for f in "${!SRCS[@]}"; do
                IFS=: read -r name fs pid ptype type mp used size <<<"${SRCS[$f]}"
                [[ $type == 'lvm' ]] && src_lfs[${name##*-}]=$fs
                [[ $type == 'part' ]] && grep -qE "${name}" < <(echo "${!TO_LVM[@]}" | tr ' ' '\n') && src_lfs[${TO_LVM[$name]}]=$fs
            done
        }

        {
            local lv_name dm_path type e
            while read -r e; do
                read -r lv_name dm_path type <<<"$e"
                [[ $dm_path =~ swap ]] && mkswap -f "$dm_path" && continue
                [[ -z ${src_lfs[$lv_name]} ]] && exit_ 1 "Unexpected Error" #Yes, I know... but has to do for the moment!
                { [[ "${src_lfs[$lv_name]}" == swap ]] && mkswap -f "$dm_path"; } || mkfs -t "${src_lfs[$lv_name]}" "$dm_path"
            done < <(lvs --no-headings -o lv_name,dm_path $VG_SRC_NAME_CLONE | awk '{print $1,$2}')
        }
    } #}}}

    _prepare_disk() { #{{{
        logmsg "[ Clone ] _prepare_disk"
        if hash lvm 2>/dev/null; then
            # local vgname=$(vgs -o pv_name,vg_name | eval grep "'${DEST}|${VG_DISKS/ /|}'" | awk '{print $2}')
            local vgname=$(vgs -o pv_name,vg_name | grep "${DEST}" | awk '{print $2}')
            vgreduce --removemissing "$vgname"
            vgremove -f "$vgname"
            pvremove -f "${DEST}*"

            local e
            while read -r e; do
                echo "pvremove -f $e"
                pvremove "$e" || exit_ 1 "Cannot remove PV $e"
            done < <(pvs --noheadings -o pv_name,vg_name | grep -E '(/\w*)+(\s+)$')
        fi

        dd oflag=direct if=/dev/zero of="$DEST" bs=512 count=100000
        dd oflag=direct bs=512 if=/dev/zero of="$DEST" count=4096 seek=$(($(blockdev --getsz $DEST) - 4096)) #TODO still needed?

        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"

        sleep 3

        if [[ $ENCRYPT_PWD ]]; then
            encrypt "$ENCRYPT_PWD" "$DEST" "$LUKS_LVM_NAME"
        else
            local ptable="$(if [[ $_RMODE == true ]]; then cat "$SRC/$F_PART_TABLE"; else sfdisk -d "$SRC"; fi)"
            expand_disk "$SECTORS_SRC" "$SECTORS_DEST" "$ptable" 'ptable'
            sfdisk --force "$DEST" < <(echo "$ptable")
            sfdisk -Vq "$DEST" || return 1
            [[ $UEFI == true ]] && mbr2gpt $DEST && HAS_EFI=true
        fi
        partprobe "$DEST"
    } #}}}

    _finish() { #{{{
        [[ -z $1 ]] && return 1 #Just to protect ourselves
        logmsg "[ Clone ] _finish"
        [[ -f "$1/etc/hostname" && -n $HOST_NAME ]] && echo "$HOST_NAME" >"$1/etc/hostname"
        [[ -f $1/grub/grub.cfg || -f $1/grub.cfg || -f $1/boot/grub/grub.cfg ]] && HAS_GRUB=true
        [[ ${#SRC2DEST[@]} -gt 0 ]] && boot_setup "SRC2DEST" "$1"
        [[ ${#PSRC2PDEST[@]} -gt 0 ]] && boot_setup "PSRC2PDEST" "$1"
        [[ ${#NSRC2NDEST[@]} -gt 0 ]] && boot_setup "NSRC2NDEST" "$1"
    } #}}}

    _from_file() { #{{{
        logmsg "[ Clone ] _from_file"
        local files=()
        pushd "$SRC" >/dev/null || return 1

        files=([0-9]*)

        #Now, we are ready to restore files from previous backup images
        local file mpnt i uuid puuid fs type sused dev mnt dir ddev dfs dpid dptype dtype davail user group o_user o_group
        for file in "${files[@]}"; do
            IFS=. read -r i uuid puuid fs type sused dev mnt dir user group<<<"$(pad_novalue "$file")"
            IFS=: read -r ddev dfs dpid dptype dtype davail <<<"${DESTS[${SRC2DEST[$uuid]}]}"
            dir=${dir//_//}
            mnt=${mnt//_//}

            if [[ -n $ddev ]]; then
                mount_ "$ddev" && { mpnt=$(get_mount $ddev) || exit_ 1 "Could not find mount journal entry for $ddev. Aborting!"; }
                if [[ -n $dir ]]; then
                    mpnt=$(realpath -s $mpnt/$dir)
                    mnt=$(realpath -s $mnt/$dir && mkdir -p $mpnt)
                    o_user=$(stat -c "%u" $mpnt)
                    o_group=$(stat -c "%g" $mpnt)
                fi
                pushd "$mpnt" >/dev/null || return 1


                [[ $SYS_HAS_EFI == false && $HAS_EFI == true ]] && exit_ 1 "Cannot clone UEFI system. Current running system does not support UEFI."

                ((davail - sused <= 0)) \
                    && exit_ 10 "Require $(to_readable_size ${sused}K) but destination is only $(to_readable_size ${davail}K)"

                local cmd="tar --same-owner -xf - -C $mpnt"
                [[ -n $XZ_OPT ]] && cmd="$cmd --xz"

                if [[ $INTERACTIVE == true ]]; then
                    local size=$(du --bytes -c "${SRC}/${file}" | tail -n1 | awk '{print $1}')
                    cmd="pv --interval 0.5 --numeric -s $size \"${SRC}\"/${file}* | $cmd"
                    [[ $fs == vfat ]] && cmd="fakeroot $cmd"
                    while read -r e; do
                        [[ $e -ge 100 ]] && e=100
                        message -u -c -t "Restoring ${dev//_//} ($mnt) to $ddev [ $(printf '%02d%%' $e) ]"
                        #Note that with pv stderr holds the current percentage value!
                    done < <((eval "$cmd") 2>&1)
                    message -u -c -t "Restoring ${dev//_//} ($mnt) to $ddev [ $(printf '%02d%%' 100) ]"
                else
                    message -c -t "Restoring ${dev//_//} ($mnt) to $ddev"
                    cmd="$cmd < ${SRC}/${file}"
                    [[ $fs == vfat ]] && cmd="fakeroot $cmd"
                    eval "$cmd"
                fi

                # Tar will change parent folder permissions because all contend was saved with '.'.
                # So we either restore the original values or the ones provided by argument overwrites.
                if [[ -n $dir ]]; then
                    chown ${user:-$o_user} $mpnt
                    chgrp ${group:-$o_group} $mpnt
                fi

                popd >/dev/null || return 1
                _finish "$mpnt" 2>/dev/null
                umount_ "$ddev"
            fi
            message -y
        done

        popd >/dev/null || return 1
        return 0
    } #}}}

        _copy() { #{{{
            local sdev=$1 ddev=$2 smpnt=$3 dmpnt=$4 excludes=() cmd
            [[ -n $5 ]] && excludes=(${EXCLUDES[$5]//:/ })

            if [[ -n $excludes ]]; then
                for ex in ${excludes[@]}; do
                    cmd="$cmd --exclude=/$ex"
                done
            else
                cmd="--exclude=/run/* --exclude=/tmp/* --exclude=/proc/* --exclude=/dev/* --exclude=/sys/*"
            fi

            if [[ $INTERACTIVE == true ]]; then
                message -u -c -t "Cloning $sdev to $ddev [ scan ]"
                local size=$(rsync -aSXxH --stats --dry-run $cmd "$smpnt/" "$dmpnt" \
                    | grep -oP 'Number of files: \d*(,\d*)*' \
                    | cut -d ':' -f2 \
                    | tr -d ' ' \
                    | sed -e 's/,//g'
                )

                {
                    local e
                    while read -r e; do
                        [[ $e -ge 100 ]] && e=100
                        message -u -c -t "Cloning $sdev to $ddev [ $(printf '%02d%%' $e) ]"
                    done < <(rsync -vaSXxH $cmd "$smpnt/" "$dmpnt" | pv --interval 0.5 --numeric -le -s "$size" 2>&1 >/dev/null)
                }
                message -u -c -t "Cloning $sdev to $ddev [ $(printf '%02d%%' 100) ]"
            else
                message -c -t "Cloning $sdev to $ddev"
                rsync -aSXxH $cmd "$smpnt/" "$dmpnt"
            fi
            message -y
        } #}}}

    _clone() { #{{{
        logmsg "[ Clone ] _clone"

        local lvs_data=$(lvs --noheadings -o lv_name,lv_dm_path,vg_name \
            | grep "\b${VG_SRC_NAME}\b"
        )

        local src_vg_free=$( vgs --noheadings --units m --nosuffix -o vg_name,vg_free \
            | grep "\b${VG_SRC_NAME}\b" \
            | awk '{print $2}'
        )

        local s smpnt dmpnt sdev sfs spid sptype stype sused ssize ddev dfs dpid dptype dtype davail
        for s in ${SRCS_ORDER[@]}; do
            IFS=: read -r sdev sfs spid sptype stype mountpoint sused ssize <<<${SRCS[$s]}
            IFS=: read -r ddev dfs dpid dptype dtype davail <<<${DESTS[${SRC2DEST[$s]}]}

            [[ $SYS_HAS_EFI == false && $HAS_EFI == true ]] \
                && exit_ 1 "Cannot clone UEFI system. Current running system does not support UEFI."

            if [[ $stype == lvm ]]; then
                local lv_src_name=$(grep $sdev <<<"$lvs_data" | awk '{print $1}')
            fi

            if [[ $stype == lvm && "${src_vg_free%%.*}" -ge "500" ]]; then
                local tdev="/dev/${VG_SRC_NAME}/$SNAP4CLONE"
                lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE" &>/dev/null #Just to be sure
                lvcreate -l100%FREE -s -n $SNAP4CLONE "${VG_SRC_NAME}/$lv_src_name"
            else
                local tdev="$sdev"
            fi

            mount_ "$tdev"
            smpnt=$(get_mount "$tdev") || exit_ 1 "Could not find mount journal entry for $tdev. Aborting!"

            mount_ "$ddev"
            dmpnt=$(get_mount "$ddev") || exit_ 1 "Could not find mount journal entry for $tdev. Aborting!"

            ((davail - sused <= 0)) && exit_ 10 "Require $(to_readable_size ${sused}K) but $ddev is only $(to_readable_size ${davail}K)"

            _copy "$sdev" "$ddev" "$smpnt" "$dmpnt"

            for em in ${!EXT_PARTS[@]}; do
                local e=${EXT_PARTS[$em]}
                local l=${MOUNTS[$s]}
                if [[ $l == $(find_mount_part $em ) ]]; then
                    local user password
                    read -r user password <<<${CHOWN[$em]/:/ }

                    mount_ "$e"
                    local smpnt_e=$(get_mount $e) || exit_ 1 "Could not find mount journal entry for $e. Aborting!"

                    local o_user=$(stat -c "%u" "$dmpnt/${em/$l/}")
                    local o_group=$(stat -c "%g" "$dmpnt/${em/$l/}")

                    _copy "$e" "$ddev:$em" "$smpnt_e" "$dmpnt/${em/$l/}" $em

                    chown ${user:-$o_user} "$dmpnt/${em/$l/}"
                    chgrp ${group:-$o_group} "$dmpnt/${em/$l/}"

                    umount_ "$e"
                fi
            done

            _finish "$dmpnt"
            umount_ "$ddev"
            umount_ "$tdev"
            [[ $stype == lvm ]] && lvremove -f "${VG_SRC_NAME}/$SNAP4CLONE"

        done
        return 0
    } #}}}

    _src2dest() { #{{{
        logmsg "[ Clone ] _src2dest"

        local si=0
        local di=0

        local i sdev sfs spid sptype stype srest ddev dfs dpid dptype dtype drest
        for ((i = 0; i < ${#SRCS_ORDER[@]}; i++)); do
            IFS=: read -r sdev sfs spid sptype stype srest <<<${SRCS[${SRCS_ORDER[$i]}]}
            IFS=: read -r ddev dfs dpid dptype dtype drest <<<${DESTS[${DESTS_ORDER[$i]}]}

            SRC2DEST[${SRCS_ORDER[$i]}]=${DESTS_ORDER[$i]}
            [[ -n $spid && -n $dpid ]] && PSRC2PDEST[$spid]=$dpid
            [[ -n $sdev && -n $ddev ]] && NSRC2NDEST[$sdev]=$ddev
        done
    } #}}}

    message -c -t "Cloning disk layout"
    {
        local f=$([[ $_RMODE == true ]] && cat "$SRC/$F_PART_LIST" || $LSBLK_CMD ${VG_DISKS[@]:-$SRC})

        init_srcs "$f"
        [[ $_RMODE == true ]] && eval $(cat $F_DEVICE_MAP)
        mounts

        {
            if [[ $ALL_TO_LVM == true ]]; then
                local y sdevname fs spid ptype type rest
                for y in "${SRCS_ORDER[@]}"; do
                    IFS=: read -r sdevname fs spid ptype type rest <<<"${SRCS[$y]}"
                    if [[ $type == part ]]; then
                        if [[ ! ${ptype} =~ $ID_GPT_LVM|0x${ID_DOS_LVM} \
                        && ! ${ptype} =~ $ID_GPT_EFI|0x${ID_DOS_EFI} ]]; then
                            name="${MOUNTS[$y]##*/}"
                            TO_LVM[$sdevname]="${name:-root}"
                        fi
                    fi
                done
            fi
        }

        {
            if [[ -n $ENCRYPT_PWD ]]; then
                local f name fstype partuuid parttype type used avail
                for f in "${SRCS_ORDER[@]}"; do
                    IFS=: read -r name fstype partuuid parttype type used avail <<<"${SRCS[$f]}"
                    if ! grep -qE "${name}" < <(echo "${!TO_LVM[@]}" | tr ' ' '\n'); then
                        [[ $type == part && ! $parttype =~ $ID_GPT_EFI|0x${ID_DOS_EFI} ]] \
                            && exit_ 1 "Cannot encrypt disk. All partitions (except for EFI) must be of type 'lvm'."
                    fi
                done
            fi
        }

        _prepare_disk
        sync_block_dev $DEST

        {
            if [[ -n $ENCRYPT_PWD ]]; then
                if [[ $HAS_EFI == true ]]; then
                    local dev type
                    read -r dev type <<<$(sfdisk -l -o Device,Type-UUID $DEST | grep ${ID_GPT_EFI^^})
                    mkfs -t vfat "$dev"
                fi
                pvcreate -ffy "/dev/mapper/$LUKS_LVM_NAME" && udevadm settle
                _lvm_setup "/dev/mapper/$LUKS_LVM_NAME" && udevadm settle
            else
                disk_setup "$f" "$SRC" "$DEST" || exit_ 2 "Disk setup failed!"
                if echo "${SRCS[*]}" | grep -q 'lvm' || [[ $ALL_TO_LVM == true ]]; then
                    _lvm_setup "$DEST"
                    sleep 3
                fi
            fi
        }

        #Now collect what we have created
        set_dest_uuids
        _src2dest
    }
    message -y

    if [[ $_RMODE == true ]]; then
        _from_file || return 1
    else
        _clone || return 1
    fi

    if [[ $HAS_GRUB == true ]]; then
        message -c -t "Installing Grub"
        {
            local ddev rest
            IFS=: read -r ddev rest <<<${DESTS[${SRC2DEST[${MOUNTS['/']}]}]}
            [[ -z $ddev ]] && exit_ 1 "Unexpected error - empty destination."
            if [[ $ENCRYPT_PWD ]]; then
                crypt_setup "$ENCRYPT_PWD" $ddev "$DEST" "$LUKS_LVM_NAME" "$ENCRYPT_PART" || return 1
            else
                [[ $HAS_EFI == true && $SYS_HAS_EFI == false ]] && return 1
                grub_setup $ddev "$HAS_EFI" "$UEFI" "$DEST" || return 1
            fi
        }
        message -y
    fi
    return 0
} #}}}

#}}}


Main() { #{{{
    local args_count=$# #getop changes the $# value. To be sure we save the original arguments count.
    local args=$@       #Backup original arguments.

    _validate_block_device() { #{{{
        logmsg "Main@_validate_block_device"
        local t=$(lsblk --nodeps --noheadings -o TYPE "$1")
        ! [[ $t =~ disk|loop ]] && exit_ 1 "Invalid block device. $1 is not a disk."
    } #}}}

    _is_valid_lv() { #{{{
        logmsg "Main@_is_valid_lv"
        local lv_name="$1"
        local vg_name="$2"

        if [[ $_RMODE == true ]]; then
            grep -qw "$lv_name" < <(awk '{print $1}' "$SRC/$F_LVS_LIST" | sort -u)
        else
            lvs --noheadings -o lv_name,vg_name | grep -w "$vg_name" | grep -qw "$1"
        fi
    } #}}}

    _is_valid_lv_name() { #{{{
        logmsg "Main@_is_valid_lv_name"
        local lv_name="$1"
        [[ $lv_name =~ ^[a-zA-Z0-9_][a-zA-Z0-9+_.-]* ]] && return 0
        return 1
    } #}}}

    _is_partition() { #{{{
        logmsg "Main@_is_partition"
        local part=$1

        [[ -n $part && $part =~ $SRC ]] || return 1
        local name parttype type fstype
        read -r name parttype type fstype <<<$(lsblk -Ppo NAME,PARTTYPE,TYPE,FSTYPE "$part")
        eval "$name" "$parttype" "$type" "$fstype"
        [[ $TYPE == part && -n $FSTYPE && ! $FSTYPE =~ ^(crypto_LUKS|LVM2_member)$ && $PARTTYPE != $ID_GPT_EFI ]] && return 0
        return 1
    } #}}}

    _run_schroot() { #{{{
        logmsg "Main@_run_schroot"
        # debootstrap --make-tarball=bcrm.tar --include=git,locales,lvm2,bc,pv,parallel,qemu-utils stretch ./dbs2
        # debootstrap --unpack-tarball=$(dirname $(readlink -f $0))/bcrm.tar --include=git,locales,lvm2,bc,pv,parallel,qemu-utils,rsync stretch /tmp/dbs

        [[ -s $SCRIPTPATH/$F_SCHROOT ]] || exit_ 2 "Cannot run schroot because the archive containing it - $F_SCHROOT - is missing."
        [[ -n $(ls -A "$SCHROOT_HOME") ]] && exit_ 2 "Schroot home not empty!"

        echo_ "Creating chroot environment. This might take a while ..."
        { mkdir -p "$SCHROOT_HOME" && tar xf "${SCRIPTPATH}/$F_SCHROOT" -C "$_"; } \
            || exit_ 1 "Faild extracting chroot. See the log $F_LOG for details."

        mount_chroot "$SCHROOT_HOME"

        [[ -n $DEST_IMG ]] && mount_ "${DEST_IMG%/*}" -p "$SCHROOT_HOME/${DEST_IMG%/*}" -b
        [[ -n $SRC_IMG ]] && mount_ "${SRC_IMG%/*}" -p "$SCHROOT_HOME/${SRC_IMG%/*}" -b

        if [[ -d "$SRC" && -b $DEST ]]; then
            { mkdir -p "$SCHROOT_HOME/$SRC" && mount_ "$SRC" -p "$SCHROOT_HOME/$SRC" -b; } \
                || exit_ 1 "Failed preparing chroot for restoring from backup."
        elif [[ -b "$SRC" && -d $DEST ]]; then
            { mkdir -p "$SCHROOT_HOME/$DEST" && mount_ "$DEST" -p "$SCHROOT_HOME/$DEST" -b; } \
                || exit_ 1 "Failed preparing chroot for backup creation."
        fi

        echo -n "$(< <(echo -n "
            [bcrm]
            type=plain
            directory=${SCHROOT_HOME}
            profile=desktop
            preserve-environment=true
        "))" | sed -e '/./,$!d; s/^\s*//' >$F_SCHROOT_CONFIG

        cp -r $(dirname $(readlink -f $0)) "$SCHROOT_HOME"
        echo_ "Now executing chroot in $SCHROOT_HOME"
        rm "$PIDFILE" && schroot -c bcrm -d /sf_bcrm -- bcrm.sh ${args//--schroot/} #Do not double quote args to avoid wrong interpretation!

        umount_chroot

        umount_ "$SCHROOT_HOME/$DEST"
        umount_ "$SCHROOT_HOME/${SRC_IMG%/*}"
        umount_ "$SCHROOT_HOME/${DEST_IMG%/*}"
    } #}}}

    _prepare_locale() { #{{{
        logmsg "Main@_prepare_locale"
        mkdir -p $BACKUP_FOLDER
        local cf="/etc/locale.gen"
        CHG_SYS_FILES["$cf"]=$(md5sum "$cf" | awk '{print $1}')

        mkdir -p "${BACKUP_FOLDER}/${cf%/*}" && cp "$cf" "${BACKUP_FOLDER}/${cf}"
        echo "en_US.UTF-8 UTF-8" >"$cf"
        locale-gen >/dev/null || return 1
    } #}}}

    #If boot is a directory on /, returns ""
    # $1: <Ref. to store boot partition name>
    _find_boot() { #{{{
        logmsg "Main@_find_boot"
        local ldata=$($LSBLK_CMD $SRC)
        declare -n boot_part="$1"

        local lvs_list=$(lvs -o lv_dmpath,lv_role)

        _set() { #{{{
            local name=$1
            local mountpoint=$2
            local mp
            [[ -z ${mountpoint// } ]] && mp="${name}" || mp="${mountpoint}"
            mount_ "$mp" || exit_ 1 "Could not mount ${mp}."
            mpnt=$(get_mount $mp) || exit_ 1 "Could not find mount journal entry for $mp. Aborting!"
            if [[ -f ${mpnt}/etc/fstab ]]; then
                {
                    local part=$(awk '$1 ~ /^[^;#]/' "${mpnt}/etc/fstab" | grep -E "\s+/boot\s+" | awk '{print $1}')
                    if [[ -n $part ]]; then
                        local name kdev fstype uuid puuid type parttype mountpoint size
                        read -r name kdev fstype uuid puuid type parttype mountpoint size <<<$(echo "$ldata" | grep "=\"${part#*=}\"")
                        eval declare "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint" "$size"
                        boot_part=$KNAME
                    fi
                }
            fi
            umount_ "$mp"
        } #}}}

        local mpnt f name mountpoint fstype type
        if [[ $IS_LVM == true ]]; then
            local parts=$(lsblk -lpo name,fstype,mountpoint | grep "${VG_SRC_NAME//-/--}-" | grep -iv 'swap')
            while read -r name fstype mountpoint; do
                if grep "$name" <<<"$lvs_list" | grep -vq "snapshot"; then
                    [[ -n $fstype ]] && _set $name $mountpoint
                fi
            done <<<"$parts"
        else
            parts=$(lsblk -lpo name,type,fstype,mountpoint $SRC | grep 'part' | grep -iv 'swap')
            while read -r name type fstype mountpoint; do
                [[ -n $fstype ]] && _set $name $mountpoint
            done <<<"$parts"
        fi
        [[ -z $boot_part ]] && return 1 || return 0
    } #}}}

    _dest_size() { #{{{
        logmsg "Main@_dest_size"
        local used size dest_size=0

        if [[ -d $DEST ]]; then
            read -r size used <<<$(df --block-size=1M --output=size,used $DEST | tail -n 1)
            dest_size=$((size - used))
        else
            if [[ $PVALL == true ]]; then
                local d
                for d in $(lsblk -po name,type | grep disk | grep -v "$DEST" | awk '{print $1}'); do
                    dest_size=$((dest_size + $(blockdev --getsize64 "$d")))
                done
            else
                dest_size=$(blockdev --getsize64 "$DEST")
            fi
            dest_size=$(to_mbyte ${dest_size})
        fi
        echo $dest_size
    } #}}}

    _src_size() { #{{{
        logmsg "Main@_src_size"
        declare -n __src_size=$1
        __src_size=0
        local plist=$(lsblk -nlpo fstype,type,kname,name,mountpoint "$SRC" | grep '^\S' | grep -v LVM2_member | awk 'BEGIN {OFS=":"} {print $1,$3,$4,$5}')
        local lvs_list=$(lvs -o lv_dmpath,lv_role)

        local fs dev name mountpoint swap_size=0
        while IFS=: read -r fs dev name mountpoint; do
            if grep "$name" <<<"$lvs_list" | grep -vq "snapshot" && [[ -n ${fs// } ]]; then
                if [[ $SWAP_SIZE -lt 0 && $fs == swap ]]; then
                    swap_size=$(swapon --show=size,name --bytes --noheadings | grep $dev | awk '{print $1}') #no swap = 0
                    swap_size=$(to_kbyte ${swap_size:-0})
                fi

                [[ -z ${mountpoint// } && $fs != swap ]] && { mount_ $dev || exit_ 1 "Could not mount ${dev}."; }
                __src_size=$((swap_size + __src_size + $(df -k --output=used $dev | tail -n -1)))
                [[ -z ${mountpoint// } ]] && umount_ "$dev"
            fi
        done <<<"$plist"

        __src_size=$(to_mbyte ${__src_size}K)
    } #}}}

    trap Cleanup INT TERM EXIT

    exec 3>&1 4>&2
    tput sc

    { >&3; } 2<> /dev/null || exit_ 9
    { >&4; } 2<> /dev/null || exit_ 9

    option=$(getopt \
        -o 'huqczps:d:e:n:m:w:b:H:' \
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
            vg-free-size:,
            use-all-pvs,
            make-uefi,
            source,
            destination,
            compress,
            quiet,
            schroot,
            boot-size:,
            no-cleanup,
            to-lvm:,
            all-to-lvm,
            disable-mount:,
            include-partition:,
            check' \
        -n "$(basename "$0" \
        )" -- "$@")

    [[ $? -ne 0 ]] && usage

    eval set -- "$option"

    [[ $1 == -h || $1 == --help || $args_count -eq 0 ]] && usage #Don't have to be root to get the usage info

    #Force root
    [[ $(id -u) -ne 0 ]] && exec sudo "$0" "$@"

    echo >"$F_LOG"
    { hash pv && INTERACTIVE=true; } || message -i -t "No progress will be shown. Consider installing package: pv"

    SYS_HAS_EFI=$([[ -d /sys/firmware/efi ]] && echo true || echo false)

    {
        #Make sure BASH is the right version so we can use array references!
        local v=$(echo "${BASH_VERSION%.*}" | tr -d '.')
        ((v < 43)) && exit_ 1 "ERROR: Bash version must be 4.3 or greater!"
    }

    #Lock the script, only one instance is allowed to run at the same time!
    exec 200>"$PIDFILE"
    flock -n 200 || exit_ 1 "Another instance with PID $pid is already running!"
    pid=$$
    echo $pid 1>&200

    #Do not use /tmp! It will be excluded on backups!
    MNTPNT=$(mktemp -d -p /mnt) || exit_ 1 "Could not set temporary mountpoint."

    systemctl --runtime mask sleep.target hibernate.target suspend.target hybrid-sleep.target &>/dev/null

    PKGS=()
    while true; do
        case "$1" in
        '-h' | '--help')
            usage
            shift 1; continue
            ;;
        '-s' | '--source')
            SRC=$(readlink -e "$2") || exit_ 1 "Specified source $2 does not exist!"
            shift 2; continue
            ;;
        '--source-image')
            read -r SRC_IMG IMG_TYPE <<<"${2//:/ }"

            [[ -n $SRC_IMG && -z $IMG_TYPE ]] && exit_ 1 "Missing type attribute"
            [[ $IMG_TYPE =~ ^raw$|^vdi$|^vmdk$|^qcow2$ ]] || exit_ 2 "Invalid image type in $1 $2"
            [[ ! -e "$SRC_IMG" ]] && exit_ 1 "Specified image file does not exists."

            ischroot || modprobe nbd max_part=16 || exit_ 1 "Cannot load nbd kernel module."

            PKGS+=(qemu-img)
            CREATE_LOOP_DEV=true
            shift 2; continue
            ;;
        '--destination-image')
            read -r DEST_IMG IMG_TYPE IMG_SIZE <<<"${2//:/ }"

            [[ -n $DEST_IMG && -z $IMG_TYPE ]] && exit_ 1 "Missing type attribute"
            [[ $IMG_TYPE =~ ^raw$|^vdi$|^vmdk$|^qcow2$ ]] || exit_ 2 "Invalid image type in $1 $2"
            [[ ! -e "$DEST_IMG" && -z $IMG_SIZE ]] && exit_ 1 "Specified image file does not exists."

            if [[ -n $DEST_IMG && -n $IMG_SIZE ]]; then
                validate_size "$IMG_SIZE" || exit_ 2 "Invalid size attribute in $1 $2"
            fi

            ischroot || modprobe nbd max_part=16 || exit_ 1 "Cannot load nbd kernel module."

            PKGS+=(qemu-img)
            CREATE_LOOP_DEV=true
            shift 2; continue
            ;;
        '-d' | '--destination')
            DEST=$(readlink -e "$2") || exit_ 1 "Specified destination $2 does not exist!"
            shift 2; continue
            ;;
        '-n' | '--new-vg-name')
            VG_SRC_NAME_CLONE="$2"
            _is_valid_lv_name $VG_SRC_NAME_CLONE || exit_ 1 "Valid characters for VG names are: 'a-z A-Z 0-9 + _ . -'. VG names cannot begin with a hyphen."
            shift 2; continue
            ;;
        '-e' | '--encrypt-with-password')
            ENCRYPT_PWD="$2"
            [[ -z "${ENCRYPT_PWD// }" ]] && exit_ 2 "Invalid password."
            PKGS+=(cryptsetup)
            shift 2; continue
            ;;
        '-H' | '--hostname')
            HOST_NAME="$2"
            shift 2; continue
            ;;
        '-u' | '--make-uefi')
            UEFI=true;
            shift 1; continue
            ;;
        '-p' | '--use-all-pvs')
            PVALL=true
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
            { validate_size "$2" && MIN_RESIZE=$(to_mbyte "$2"); } || exit_ 2 "Invalid size specified.
                Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
            shift 2; continue
            ;;
        '-w' | '--swap-size')
            { validate_size "$2" && SWAP_SIZE=$(to_kbyte "$2"); } || exit_ 2 "Invalid size specified.
                Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
            shift 2; continue
            ;;
        '-b' | '--boot-size')
            { validate_size "$2" && BOOT_SIZE=$(to_kbyte "$2"); } || exit_ 2 "Invalid size specified.
                Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
            shift 2; continue
            ;;
        '--lvm-expand')
            read -r LVM_EXPAND LVM_EXPAND_BY <<<"${2/:/ }"
            [[ "${LVM_EXPAND_BY:-100}" =~ ^0*[1-9]$|^0*[1-9][0-9]$|^100$ ]] || exit_ 2 "Invalid size attribute in $1 $2"
            shift 2; continue
            ;;
        '--vg-free-size')
            { validate_size "$2" && VG_FREE_SIZE=$(to_mbyte "$2"); } || exit_ 2 "Invalid size specified.
                Use K, M, G or T suffixes to specify kilobytes, megabytes, gigabytes and terabytes."
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
        '--disable-mount')
            DISABLED_MOUNTS+=("$2")
            shift 2; continue
            ;;
        '--no-cleanup')
            IS_CLEANUP=false
            shift 1; continue
            ;;
        '--all-to-lvm')
            ALL_TO_LVM=true
            shift 1; continue
            ;;
        '--include-partition')
            local part mp fstype type user group excludes
            for x in ${2//,/ }; do
                read -r k v <<<"${x/=/ }"
                if [[ -n $k && -n $v ]]; then
                    [[ $k == user ]] && user=$v
                    [[ $k == group ]] && group=$v
                    [[ $k == part ]] && part=$v
                    [[ $k == dir ]] && mp=$v
                    excludes=$v
                elif [[ -n $k ]]; then
                    excludes=${excludes}:$k
                fi
            done

            [[ -b $part ]] && read -r type fstype <<<$(lsblk -lpno type,fstype $part) || exit_ 2 "$part not a block device."
            if [[ $type == part || -z $fstype ]]; then
                [[ -n $user && $user =~ ^[0-9]+$ || -z $user ]] || exit_ 1 "Invalid user ID."
                [[ -n $group && $group =~ ^[0-9]+$ || -z $group ]] || exit_ 1 "Invalid group ID."
                EXT_PARTS[$mp]=$part
                EXCLUDES[$mp]=$excludes
                CHOWN[$mp]=$user:$group
            else
                exit_ 2 "$part is not a partition"
            fi
            shift 2; continue
            ;;
        '--to-lvm')
            {
                local k v
                read -r k v <<<"${2/:/ }"
                [[ -z $v ]] && exit_ 1 "Missing LV name"
                if _is_valid_lv_name $v; then
                    [[ -n ${TO_LVM[$k]} ]] && exit_ 1 "$k already specified. Duplicate parameters?"
                    TO_LVM[$k]=$v
                else
                    exit_ 1 "Invalid LV name '$v'."
                fi
            }
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

    grep -q 'LVM2_member' < <([[ -d $SRC ]] && cat "$SRC/$F_PART_LIST" || lsblk -o FSTYPE "$SRC") && PKGS+=(lvm)

    PKGS+=(awk rsync tar flock bc blockdev fdisk sfdisk locale-gen git mkfs.vfat parted)
    [[ -d $SRC ]] && PKGS+=(fakeroot) && _RMODE=true

    local packages=()
    #Inform about ALL missing but necessary tools.
    for c in "${PKGS[@]}"; do
        echo "$c" >>/tmp/f

        hash "$c" 2>/dev/null || {
            case "$c" in
            lvm)
                packages+=(lvm2)
                ;;
            qemu-img)
                packages+=(qemu-utils)
                ;;
            blockdev)
                packages+=(util-linux)
                ;;
            mkfs.vfat)
                packages+=(dosfstools)
                ;;
            *)
                packages+=("$c")
                ;;
            esac
            abort='exit_ 1'
        }
    done

    exec >$F_LOG 2>&1

    [[ -n $abort ]] && message -n -t "ERROR: Some packages missing. Please install packages: ${packages[*]}"
    eval "$abort"

    [[ -b "$SRC" && -d $DEST && -n "$(ls "$DEST")" ]] && exit_ 1 "Destination not empty!"

    if [[ $SCHROOT == true ]]; then
        _run_schroot
        exit_ 0
    fi

    if [[ -n $SRC_IMG ]]; then
        { qemu-nbd --cache=writeback -f "$IMG_TYPE" -c $SRC_NBD "$SRC_IMG"; } || exit_ 1 "QEMU Could not load image. Check $F_LOG for details."
        SRC=$SRC_NBD
        sleep 3
    fi

    [[ -n $DEST && -n $DEST_IMG && -n $IMG_TYPE && -n $IMG_SIZE ]] && exit_ 1 "Invalid combination."
    [[ -d $DEST && $BOOT_SIZE -gt 0 ]] && exit_ 1 "Invalid combination."

    if [[ -n $DEST_IMG ]]; then
        [[ ! -e $DEST_IMG ]] && { create_image "$DEST_IMG" "$IMG_TYPE" "$IMG_SIZE" || exit_ 1 "Image creation failed."; }
        chmod +rwx "$DEST_IMG"
        { qemu-nbd --cache=writeback -f "$IMG_TYPE" -c $DEST_NBD "$DEST_IMG"; } || exit_ 1 "QEMU Could not load image. Check $F_LOG for details."
        DEST=$DEST_NBD
        sleep 3
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

    if [[ -b $SRC ]]; then
        lsblk -lpo parttype "$SRC" | grep -qi $ID_GPT_EFI && HAS_EFI=true
        lsblk -lpo type "$SRC" | grep -qi 'crypt' && HAS_LUKS=true
	fi

    {
        if [[ -b $DEST ]]; then
            local pv_name vg_name
            read pv_name vg_name < <(pvs -o pv_name,vg_name --no-headings | grep "$DEST")
            [[ -n $vg_name ]] && exit_ 1 "Destination has physical volumes still assigned to VG $vg_name".
            unset pv_name vg_name
        fi

        local d
        for d in "$SRC" "$DEST"; do
            [[ -b $d ]] && _validate_block_device $d
        done
    }

    [[ $(realpath "$SRC") == $(realpath "$DEST") ]] &&
        exit_ 1 "Source and destination cannot be the same!"

    [[ -n $(lsblk --noheadings -o mountpoint $DEST 2>/dev/null) ]] &&
        exit_ 1 "Invalid device condition. Some or all partitions of $DEST are mounted."

    {
        for part in ${EXT_PARTS[@]}; do
            if [[ -b $SRC ]]; then
                grep "^$part/*\$" -q < <(lsblk -lnpo name "$SRC") && exit_ 2 "Cannot include partition ${part}. It is part of the source device ${SRC}."
            fi
            if [[ -b $DEST ]]; then
                grep "^$part/*\$" -q < <(lsblk -lnpo name "$DEST") && exit_ 2 "Cannot include partition ${part}. It is part of the source device ${DEST}."
            fi
        done
    }

    [[ $PVALL == true && -n $ENCRYPT_PWD ]] && exit_ 1 "Encryption only supported for simple LVM setups with a single PV!"

    {
        #If empyt, nothing happens!
        local l
        for l in ${!TO_LVM[@]}; do
            _is_partition $l || exit_ 1 "$l is not a valid source partition for LV conversion!"
        done
    }

    {
        #Check that all expected files exists when restoring
        if [[ -d $SRC ]]; then
            [[ -s $SRC/$F_CHESUM && $IS_CHECKSUM == true ||
                -s $SRC/$F_CONTEXT &&
                -s $SRC/$F_PART_LIST &&
                -s $SRC/$F_DEVICE_MAP &&
                -s $SRC/$F_PART_TABLE ]] || exit_ 2 "Cannot restore dump, one or more meta files are missing or empty."
            if [[ $IS_LVM == true ]]; then
                [[ -s $SRC/$F_VGS_LIST &&
                -s $SRC/$F_LVS_LIST &&
                -s $SRC/$F_PVS_LIST ]] || exit_ 2 "Cannot restore dump, one or more meta files for LVM are missing or empty."
            fi

            local f
            local mnts=$(grep -v -i 'swap' "$SRC/$F_PART_LIST" \
                | grep -Po 'MOUNTPOINT="[^\0]+?"' \
                | grep -v 'MOUNTPOINT=""' \
                | cut -d '=' -f 2 \
                | tr -d '"' \
                | tr -s "/" "_"
            ) #TODO What if mount point has spaces?

            for f in $mnts; do
                grep "$f\$" <(ls -A "$SRC") || exit_ 2 "$SRC folder missing files."
            done
        fi
    }

    if [[ -d $SRC && $IS_CHECKSUM == true ]]; then
        message -c -t "Validating checksums"
        {
            validate_m5dsums "$SRC" "$F_CHESUM" || { message -n && exit_ 1; }
        }
        message -y
    fi

    ctx_init

    [[ $UEFI == true && $SYS_HAS_EFI == false ]] &&
        exit_ 1 "Cannot convert to UEFI because system booted in legacy mode. Check your UEFI firmware settings!"

    [[ $HAS_EFI == true && $UEFI == true ]] && UEFI=false #Ignore -u if destination is alread EFI-enabled.

    {
        local src_size=0
        if [[ -d $SRC ]]; then
            src_size=$(sector_to_mbyte $SECTORS_SRC_USED)
        else
            _src_size 'src_size'
        fi

        local dest_size=$(_dest_size)

        (( src_size < dest_size )) \
            || exit_ 1 "Destination too small: Need at least $(to_readable_size ${src_size}M) but $DEST is only $(to_readable_size ${dest_size}M)"

        if [[ -b $SRC ]]; then
            SECTORS_SRC=$(blockdev --getsz "$SRC")
            SECTORS_SRC_USED=$(to_sector ${src_size}M)
            TABLE_TYPE=$(blkid -o value -s PTTYPE $SRC)
        fi

        [[ -b $DEST ]] \
            && SECTORS_DEST=$(to_sector ${dest_size}M)

        unset dest_size
    }

    {
        #Make sure source or destination folder are not mounted on the same disk to backup to or restore from.
        local d
        for d in "$SRC" "$DEST" "$DEST_IMG"; do
            [[ -f $d ]] && d=$(dirname $d)
            if [[ -d $d ]]; then
                local disk=()
                disk+=($(df --block-size=1M $d | tail -n 1 | awk '{print $1}'))
                disk+=($(lsblk -psnlo name,type $disk 2>/dev/null | grep disk | awk '{print $1}'))
                [[ ${disk[-1]} == $SRC || ${disk[-1]} == $DEST ]] && exit_ 1 "Source and destination cannot be the same!"
            fi
        done
    }

    VG_SRC_NAME=($(awk '{print $2}' < <(if [[ -d $SRC ]]; then cat "$SRC/$F_PVS_LIST"; else pvs --noheadings -o pv_name,vg_name | grep "$SRC"; fi) | sort -u))

    if [[ -z $VG_SRC_NAME && $HAS_LUKS == true ]]; then
        luks=$(grep -q "$SRC" < <(dmsetup deps -o devname) | awk '{print $1}' | tr -d ':')
        VG_SRC_NAME=($(awk '{print $2}' < <(pvs --noheadings -o pv_name,vg_name | grep "$luks") | sort -u))
    fi

    [[ ${#VG_SRC_NAME[@]} -gt 1 ]] && exit_ 1 "Unsupported situation: PVs of $SRC assigned to multiplge VGs."

    if [[ -z $VG_SRC_NAME ]]; then
        while read -r e g; do
            grep -q ${SRC##*/} < <(dmsetup deps -o devname | sort -u | sed 's/.*(\(\w*\).*/\1/g') && VG_SRC_NAME=$g
        done < <(if [[ -d $SRC ]]; then cat "$SRC/$F_PVS_LIST"; else pvs --noheadings -o pv_name,vg_name; fi)
    else
        vg_disks "$VG_SRC_NAME" "VG_DISKS" && IS_LVM=true
        if [[ -b $SRC ]] && grep -q 'LVM2_member' < <(lsblk -lpo fstype $SRC); then
            grep -q lvm < <(lsblk -lpo type $SRC) || exit_ 1 "Found LVM, but LVs have not been activated. Did you forget to run 'vgchange -ay $VG_SRC_NAME' ?"
        fi
    fi

    [[ $ALL_TO_LVM == true && -z $VG_SRC_NAME && -z $VG_SRC_NAME_CLONE ]] && exit_ 1 "You need to provide a VG name when convertig a standard disk to LVM."

    {
        if [[ $IS_LVM == true ]]; then
            local l lvs=$(lvs --no-headings -o lv_name $VG_SRC_NAME | xargs | tr ' ' '\n')
            for l in ${!TO_LVM[@]}; do
                grep -qE "\b${TO_LVM[$l]}\b" < <(echo "$lvs") && exit_ 1 "LV name '${TO_LVM[$l]}' already exists. Cannot convert "
            done

            if [[ -n $LVM_EXPAND ]]; then
                ! _is_valid_lv "$LVM_EXPAND" "$VG_SRC_NAME" \
                && exit_ 2 "Volumen name ${LVM_EXPAND} does not exists in ${VG_SRC_NAME}!"
            fi

            [[ -z $VG_SRC_NAME_CLONE ]] \
                && VG_SRC_NAME_CLONE=${VG_SRC_NAME}_${CLONE_DATE}

            [[ ${VG_SRC_NAME[0]} == "$VG_SRC_NAME_CLONE" ]] && exit_ 1 "VG with name '$VG_SRC_NAME_CLONE' already exists!"

            if [[ -b $DEST ]]; then
                #Even whenn SRC and DEST have dirrent VG names, another one could already exists!
                vgs --no-headings -o vg_name | grep -qE "\b$VG_SRC_NAME_CLONE\b" \
                    && exit_ 1 "VG with name '$VG_SRC_NAME_CLONE' already exists!"

                if [[ -b $SRC ]]; then
                    grep -q "${VG_SRC_NAME_CLONE//-/--}-" < <(dmsetup deps -o devname) \
                    && exit_ 2 "Generated VG name $VG_SRC_NAME_CLONE already exists!"
                fi
            fi
        fi
    }

    SWAP_PART=$(if [[ -d $SRC ]]; then
        grep 'swap' "$SRC/$F_PART_LIST" | awk '{print $1}' | cut -d '"' -f 2
    else
        lsblk -lpo name,fstype "$SRC" | grep swap | awk '{print $1}'
    fi)

    EFI_PART=$(if [[ -d $SRC ]]; then
        grep "${ID_GPT_EFI^^}" "$SRC/$F_PART_TABLE" | awk '{print $1}'
    else
        sfdisk -d $SRC | grep "${ID_GPT_EFI^^}" | awk '{print $1}'
    fi)

    #Context already initialized, only when source is a disk is of interest here
    if [[ -b $SRC && -z $BOOT_PART ]]; then
        _find_boot 'BOOT_PART' || exit_ 1 "No boot partition found."
    fi

    [[ $BOOT_SIZE -gt 0 && -z $BOOT_PART ]] && exit_ 1 "Boot is equal to root partition."

    {
        #In case another distribution is used when cloning, e.g. cloning an Ubuntu system with Debian Live CD.
        [[ ! -e /run/resolvconf/resolv.conf ]] && mkdir /run/resolvconf && cp /run/NetworkManager/resolv.conf /run/resolvconf/
        [[ ! -e /run/NetworkManager/resolv.conf ]] && mkdir /run/NetworkManager && cp /run/resolvconf/resolv.conf /run/NetworkManager/
    } 2>/dev/null

    _prepare_locale || exit_ 1 "Could not prepare locale!"


    #TODO avoid return values and use exit_ instead?
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

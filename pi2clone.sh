#! /usr/bin/env bash

# Copyright (C) 2017-2018 Marcel Lautenbach
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


    # while read -r e; do
    #     read -r dev size<<< "$e"
    #     size=$(( size * 1024 ))
    # done < <( df -x tmpfs -x devtmpfs --output=source,avai )

F_PART_LIST='part_list'
F_VGS_LIST='vgs_list'
F_LVS_LIST='lvs_list'
F_PVS_LIST='pvs_list'
F_SECTORS_SRC='sectors'
F_SECTORS_USED='sectors_used'
F_PART_TABLE='part_table'
F_CHESUM='check.md5'
F_LOG='/tmp/pi2clone.log'


SCRIPTNAME=$(basename "$0")
PIDFILE="/var/run/$SCRIPTNAME"
INTERACTIVE=false
export LVM_SUPPRESS_FD_WARNINGS=true

declare -A MNTJRNL
declare -A FILESYSTEMS MOUNTS NAMES PARTUUIDS UUIDS TYPES PUUIDS2UUIDS
declare -A SRC_LFS DESTS SRC2DEST PSRC2PDEST NSRC2NDEST

declare SPUUIDS=() SUUIDS=()
declare DPUUIDS=() DUUIDS=()
declare SFS=() LMBRS=() SRCS=() LDESTS=() LSRCS=()

declare VG_SRC_NAME VG_SRC_NAME_CLONE

declare HAS_GRUB=false
declare IS_LVM=false
declare CLONE_DATE=$(date '+%d%m%y')

declare COUNT=0

USAGE="
Usage: $(basename $0) [-h] -s src -d dest

Where:
    -h  Show this help text
    -s  Source block device or folder
    -d  Destination block device or folder
    -q  Quiet, do not show any output
    -i  Interactive, showing progress bars
"

### DEBUG ONLY

printarr() { declare -n __p="$1"; for k in "${!__p[@]}"; do printf "%s=%s\n" "$k" "${__p[$k]}" ; done ;  }


### PRIVATE - only used by PUBLIC functions

mount_() {
    local cmd="mount"

    local OPTIND
    local src="$1"
    local path="/mnt/$src"
    shift

    while getopts ':p:t:' option; do
        case "$option" in
        t)  cmd+=" -t $OPTARG"
            ;;
        p)  path="$OPTARG"
            ;;
        :)  printf "missing argument for -%s\n" "$OPTARG" >&2
            ;;
        ?)  printf "illegal option: -%s\n" "$OPTARG" >&2
            ;;
        esac
    done
    shift $((OPTIND - 1))

    mkdir -p "$path"
    $cmd "$src" "$path" && MNTJRNL["$src"]="$path" || return 1
}

umount_() {
    local OPTIND
    local cmd="umount"
    while getopts ':R' option; do
        case "$option" in
        R)  cmd+=" -R"
            ;;
        :)  printf "missing argument for -%s\n" "$OPTARG" >&2
            ;;
        \?) printf "illegal option: -%s\n" "$OPTARG" >&2
            ;;
        esac
    done
    shift $((OPTIND - 1))

    if [[ $# -eq 0 ]]; then
        for m in "${MNTJRNL[@]}"; do $cmd -l "$m"; done
        return 0
    fi

    if [[ "${MNTJRNL[$1]}" ]]; then
        $cmd "${MNTJRNL[$1]}" && unset MNTJRNL["$1"] || exit 1
    fi
}

exit_() {
    [[ $5 -eq 5 ]] && echo -e "Method call error: \t${2}()\t$3"
    [[ $1 -eq 1 && -n $2 ]] && message -c "$2" && message -n && Cleanup $1
    Cleanup $1
}

message() {
    local OPTIND
    local status
    clr_c=$(tput bold; tput setaf 3)
    clr_y=$(tput setaf 2)
    clr_n=$(tput setaf 1)
    clr_rmso=$(tput sgr0)

    while getopts ':ncy' option; do
        case "$option" in
            y)  status="${clr_y}✔${clr_rmso} $2"
                tput rc
                ;;
            n)  status="${clr_n}✘${clr_rmso} $2"
                tput rc
                ;;
            c)  status="${clr_c}➤${clr_rmso} $2"
                tput sc
                ;;
            :)  exit_ "${FUNCNAME[0]}" "missing argument for $OPTARG" 5
                ;;
            ?)  exit_ "${FUNCNAME[0]}"  "illegal option: $OPTARG" 5
                ;;
        esac
    done
    shift $((OPTIND - 1))

    [[ $status ]] && echo -e "$status" || exit_ "${FUNCNAME[0]}" "Required option parameters missing" 5
}

setHeader() {
    tput csr 2 $((`tput lines` - 2))
    tput cup 0 0
    tput el
    echo "$1"
    tput el
    echo -n "$2"
    tput cup 3 0
}

expand_disk() {
    local ss=$(if [[ -d $1 ]]; then cat $F_SECTORS_SRC; else blockdev --getsz $1; fi)
    local ds=$(blockdev --getsz $2)

    local expand_factor=$(echo "$ds / $ss" | bc)
    local size new_size
    local pdata=$(if [[ -f "$3" ]]; then cat "$3"; else echo "$3"; fi)

    while read -r e; do
        size=
        new_size=

        if [[ $e =~ ^/ ]]; then
            echo $e | grep -qE 'size=\s*([0-9])' && \
            size=$(echo "$e" | sed -rE 's/.*size=\s*([0-9]*).*/\1/')
        fi

        if [[ -n "$size" ]]; then
            new_size=$(echo "scale=2; $size * $expand_factor" | bc) && \
            pdata=$(sed 's/$size/${new_size%%.*}/' < <(echo "$pdata"))
        fi
    done < <( if [[ -f "$pdata" ]]; then cat "$pdata"; else echo "$pdata"; fi)

    pdata=$(sed '/type=5/ s/size=.*,//' < <(echo "$pdata"))
    pdata=$(sed '$ s/size=.*,//g' < <(echo "$pdata"))

    #return
    echo "$pdata"
}

create_m5dsums() {
    # find "$1" -type f \! -name '*.md5' -print0 | xargs -0 md5sum -b > "$1/$2"
    pushd "$1" || return 1
    find . -type f \! -name '*.md5' -print0 | parallel --no-notice -0 md5sum -b > "$2"
    popd || return 1
    validate_m5dsums "$1" "$2" || return 1
}

validate_m5dsums() {
    pushd "$1" || return 1
    md5sum -c "$2" --quiet || return 1
    popd || return 1
}

set_dest_uuids() {
    DPUUIDS=() DUUIDS=() DNAMES=()
    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $TYPE == disk ]] && continue
        [[ -n $UUID ]] && DESTS[$UUID]="$NAME"
        DPUUIDS+=($PARTUUID)
        DUUIDS+=($UUID)
        DNAMES+=($NAME)
    done < <( lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" | sort -k 2,2 )
}

count() {
    local x=$(swapon --show=size,name --bytes --noheadings | grep $1 | sed -e 's/\s+*.*//')
    COUNT=$(( $(df -k --output=used $KNAME | tail -n -1) + $COUNT ))
    COUNT=$(( $(echo ${x:=0} / 1024 | bc) + $COUNT ))
}

set_src_uuids() {
    SPUUIDS=() SUUIDS=() SNAMES=()
    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mountpoint<<< "$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $TYPE == disk ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $FSTYPE == LVM2_member ]] && LMBRS[${NAME: -1}]="$UUID"
        [[ $TYPE == part && $FSTYPE != LVM2_member ]] && SFS[${NAME: -1}]="$FSTYPE"
        SPUUIDS+=($PARTUUID)
        SUUIDS+=($UUID)
        SNAMES+=($NAME)
        [[ -b $SRC ]] && count $KNAME
    done < <( if [[ -n $1 ]]; then cat "$1" | sort -k 2,2; 
              else lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" | sort -k 2,2;
              fi )
}

init_srcs() {
    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mountpoint<<< "$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $FSTYPE == LVM2_member || $FSTYPE == swap || $TYPE == disk ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $TYPE == lvm ]] && LSRCS+=($NAME) && IS_LVM=true
        [[ $TYPE == part ]] && SRCS+=($NAME)
        FILESYSTEMS[$NAME]="$FSTYPE"
        PARTUUIDS[$NAME]="$PARTUUID"
        UUIDS[$NAME]="$UUID"
        TYPES[$NAME]="$TYPE"
        [[ -n $UUID ]] && NAMES[$UUID]=$NAME
        [[ -n $PARTUUID ]] && NAMES[$PARTUUID]=$NAME
        [[ -n $UUID && -n $PARTUUID ]] && PUUIDS2UUIDS[$PARTUUID]="$UUID"
    done < <( if [[ -n $1 ]]; then cat "$1"; 
              else lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC";
              fi )
}

disk_setup() {
    while read -r e; do
        read -r kname name fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kname" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        if [[ ${SFS[${NAME: -1}]} == swap ]]; then
            mkswap "$NAME"
        else
            [[ ${SFS[${NAME: -1}]} ]] && mkfs -t "${SFS[${NAME: -1}]}" "$NAME"
            [[ ${LMBRS[${NAME: -1}]} ]] && pvcreate "$NAME"
        fi
    done < <( lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" )
    sleep 3
}

boot_setup() {
    p=$(declare -p "$1")
    eval "declare -A sd=${p#*=}"

    for k in "${!sd[@]}"; do
        for d in "${DESTS[@]}"; do
            sed -i "s|$k|${sd[$k]}|" \
                "/mnt/$d/cmdline.txt" "/mnt/$d/etc/fstab" \
                "/mnt/$d/grub/grub.cfg" "/mnt/$d/boot/grub/grub.cfg" "/mnt/$d/etc/initramfs-tools/conf.d/resume" \
                2>/dev/null
        done
    done
}

create_rclocal() {
    mv "$1/etc/rc.local" "$1/etc/rc.local.bak" 2>/dev/null
    printf '%s' '#! /usr/bin/env bash
    while read -r e; do
        read -r dev type<<< "$e"
        eval "$dev" "$type"
        if [[ $TYPE == disk ]] && dd bs=512 count=1 if=/dev/sda 2>/dev/null | strings | grep -q GRUB; then 
            update-initramfs -u -k all
            grub-install $NAME
            update-grub
        fi
    done < <(lsblk -Ppo NAME,TYPE)
    rm /etc/rc.local
    mv /etc/rc.local.bak /etc/rc.local 2>/dev/null
    reboot' > "$1/etc/rc.local"
    chmod +x "$1/etc/rc.local"
}

grub_setup() {
    local d="$1"
    local b="$2"

    mount_ "$d"
    [[ -n $b ]] && mount "$b" "/mnt/$d/boot"

    for f in sys dev dev/pts proc; do 
        mount --bind "/$f" "/mnt/$d/$f";
    done

    grub-install --boot-directory="/mnt/$d/boot" "$DEST"
    # chroot /mnt/$d update-grub
    chroot "/mnt/$d" apt-get install -y binutils
    create_rclocal "/mnt/$d"
    umount_ -R "$d"
}

mounts() {
    for x in "${SRCS[@]}" "${LSRCS[@]}"; do
        local sdev=$x
        local sid=${UUIDS[$sdev]}

        mkdir -p "/mnt/$sdev"

        mount_ "$sdev"

        f[0]='cat /mnt/$sdev/etc/fstab | grep "^UUID" | sed -e "s/UUID=//" | tr -s " " | cut -d " " -f1,2'
        f[1]='cat /mnt/$sdev/etc/fstab | grep "^PARTUUID" | sed -e "s/PARTUUID=//" | tr -s " " | cut -d " " -f1,2'
        f[2]='cat /mnt/$sdev/etc/fstab | grep "^/" | tr -s " " | cut -d " " -f1,2'

        if [[ -f /mnt/$sdev/etc/fstab ]]; then
            for ((i=0;i<${#f[@]};i++)); do
                while read -r e; do 
                    read -r name mnt<<< "$e"
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
}

usage() {
    printf "%s\n" "$USAGE"
    exit 1
}


### PUBLIC - To be used in MAIN only

Cleanup() {
    exec 1>&3 2>&4
    [[ -d $SRC/lvm_ ]] && rm -rf "$SRC/lmv_"
    umount_
    message -n
    exit ${1:-255}
}

To_file() {
    pushd "$DEST" >/dev/null || return 1

    _save_disk_layout() {
    local vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | cut -d ' ' -f2)
    local snp=$(sudo lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role | grep 'snap' | sed -e 's/^\s*//' | cut -d ' ' -f 1)
    [[ -z $snp ]] && snp="NOSNAPSHOT"

        {
            pvs --noheadings -o pv_name,vg_name,lv_active | grep "$SRC" | grep 'active$' | uniq | sed -e 's/active$//;s/^\s*//' > $F_PVS_LIST
            vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free,lv_active | grep 'active$' | uniq | sed -e 's/active$//;s/^\s*//' > $F_VGS_LIST
            lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free,lv_active,lv_role | grep -v 'snap' | grep 'active public.*' | sed -e 's/active public.*//;s/^\s*//' > $F_LVS_LIST
            blockdev --getsz $SRC > $F_SECTORS_SRC
            sfdisk -d "$SRC" > $F_PART_TABLE
        } >/dev/null 2>>$F_LOG

        sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. 
                #Otherwise resultes from lsblk might still show old values!
        lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" | uniq | grep -v $snp > $F_PART_LIST
    }

    message -c "Creating backup of disk layout." 
    {
        _save_disk_layout
        init_srcs
        set_src_uuids
        mounts
    } >/dev/null 2>>$F_LOG
    message -y

    VG_SRC_NAME=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | cut -d ' ' -f2)

    for x in SRCS LSRCS; do
        eval declare -n s="$x"

        for ((i=0;i<${#s[@]};i++)); do
            local sdev=${s[$i]}
            local sid=${UUIDS[$sdev]}
            local spid=${PARTUUIDS[$sdev]}
            local fs=${FILESYSTEMS[$sdev]}
            local type=${TYPES[$sdev]}
            local mount=${MOUNTS[$sid]}

            local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | cut -d ' ' -f1)
            local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${VG_SRC_NAME}" | uniq | cut -d ' ' -f2)

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
            } >/dev/null 2>>$F_LOG

            cmd="tar --warning=none --directory=/mnt/$tdev --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* --atime-preserve --numeric-owner --xattrs"

            if $INTERACTIVE; then 
                local size=$(du --bytes --exclude=/proc/* --exclude=/sys/* -s /mnt/$tdev | tr -s '\t' ' ' | cut -d ' ' -f 1)
                cmd="$cmd -Scpf - . | pv --rate --timer --eta -pe -s $size > ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_}" 
            else
                cmd="$cmd -Scpf - . | split -b 1G - ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_} "  
            fi

            message -c "Creating backup for $sdev"
            {
                eval "$cmd"
                umount_ "/dev/${VG_SRC_NAME}/$tdev"
                lvremove -f "${VG_SRC_NAME}/$tdev"
            } >/dev/null 2>>$F_LOG
            message -y
        done

        for ((i=0;i<${#s[@]};i++)); do umount_ "${s[$i]}"; done
    done

    $IS_LVM && rm /etc/lvm/backup/* && vgcfgbackup > /dev/null && cp -r /etc/lvm/backup lvm

    popd >/dev/null || return 1
    echo $COUNT > $DEST/$F_SECTORS_USED
    message -c "Creating checksums"
    {
        create_m5dsums "$DEST" "$F_CHESUM"
    } >/dev/null 2>>$F_LOG
    message -y
}

Clone() {
    local OPTIND

    while getopts ':r' option; do
        case "$option" in
        r)  _RMODE=true
            ;;
        :)  printf "missing argument for -%s\n" "$OPTARG" >&2
            return 1
            ;;
        \?) printf "illegal option: -%s\n" "$OPTARG" >&2
            return 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    _lvm_setup() {
        local size s1 s2

        while read -r e; do
            read -r pv_name vg_name<<< "$e"
            [[ -z $vg_name && $pv_name =~ $DEST ]] && vgcreate "$VG_SRC_NAME_CLONE" "$pv_name"
        done < <( pvs --noheadings -o pv_name,vg_name )

        while read -r e; do
            read -r vg_name vg_size vg_free<<< "$e"
            [[ $vg_name == "$VG_SRC_NAME" ]] && s1=$((${vg_size%%.*}-${vg_free%%.*}))
            [[ $vg_name == "$VG_SRC_NAME_CLONE" ]] && s2=${vg_size%%.*}
        done < <( if [[ $_RMODE ]]; then cat $F_VGS_LIST;
                  else vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free;
                  fi )

        denom_size=$((s1<s2?s2:s1))

        # It might happen that a volume is so small, that it is only 0% in size. In this case we assume the
        # lowest possible value: 1%. This also means we have to decrease the maximum possible size. E.g. two volumes
        # with 0% and 100% would have to be 1% and 99% to make things work.
        local max_size=100

        while read -r e; do
            read -r lv_name vg_name lv_size vg_size vg_free lv_role<<< "$e"
            [[ $lv_role =~ snapshot ]] && continue
            size=$(echo "$lv_size * 100 / $denom_size" | bc)

            if ((s1<s2)); then
                lvcreate --yes -L${lv_size} -n "$lv_name" "$VG_SRC_NAME_CLONE"
            else
                (( size == 0 )) && size=1 && max_size=$((max_size - size))
                (( size == 100 )) && size=$((size - max_size))
                lvcreate --yes -l${size}%VG -n "$lv_name" "$VG_SRC_NAME_CLONE"
            fi
        done < <( if [[ $_RMODE ]]; then cat $F_LVS_LIST;
                  else lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free;
                  fi )


        for d in $SRC $DEST; do
            while read -r e; do
                read -r kname name fstype type<<< "$e"
                eval "$kname" "$name" "$fstype" "$type"
                [[ $TYPE == 'lvm' && $d == "$SRC" ]] && SRC_LFS[${NAME##*-}]=$FSTYPE
                if [[ $TYPE == 'lvm' && $d == "$DEST" ]]; then
                    { [[ "${SRC_LFS[${NAME##*-}]}" == swap ]] && mkswap "$NAME"; } || mkfs -t "${SRC_LFS[${NAME##*-}]}" "$NAME";
                fi
            done < <( if [[ -d $d ]]; then cat $F_PART_LIST; else lsblk -Ppo KNAME,NAME,FSTYPE,TYPE "$d"; fi )
        done
    }

    _prepare_disk() {
        if hash lvm 2>/dev/null; then
            vgchange -q -an "$VG_SRC_NAME_CLONE"
            vgremove -q -f "$VG_SRC_NAME_CLONE"
        fi

        dd if=/dev/zero of="$DEST" bs=512 count=100000
        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"
        
        sleep 3
        sfdisk --force "$DEST" < <(expand_disk "$SRC" "$DEST" "$(if [[ $_RMODE ]]; then cat $F_PART_TABLE; else sfdisk -d $SRC; fi)")
        sleep 3
    }

    _finish() {
        [[ -f /mnt/$ddev/grub/grub.cfg || -f /mnt/$ddev/grub.cfg || -f /mnt/$ddev/boot/grub/grub.cfg ]] && HAS_GRUB=true

        boot_setup "SRC2DEST"
        boot_setup "PSRC2PDEST"
        if [[ ${#LMBRS[@]} -gt 0 ]]; then boot_setup "NSRC2NDEST"; fi

        umount_ "$sdev"
        umount_ "$ddev"
    }

    _from_file() {
        declare -A files
        for file in [0-9]*; do
            files[${file::-2}]=1
        done
        #Now, we are ready to restore files from previous backup images
        for file in ${!files[@]}; do
            message -c "Restoring $file"
            {
                read -r i uuid puuid fs type dev mnt <<< "$e" <<< "${file//./ }";
                local ddev=${DESTS[${SRC2DEST[$uuid]}]}

                MOUNTS[${mnt//_/\/}]="$uuid"
                if [[ -n $ddev ]]; then
                mount_ "$ddev" -t "$fs"
                pushd "/mnt/$ddev" >/dev/null || return 1
                if [[ $fs == vfat ]]; then
                    fakeroot cat ${SRC}/${file}* | tar -xf - -C "/mnt/$ddev"
                else
                    cat ${SRC}/${file}* | tar -xf - -C "/mnt/$ddev"
                fi
                popd >/dev/null || return 1
                _finish
                fi
            } >/dev/null 2>>$F_LOG
            message -y
        done

        return 0
    }

    _clone() {
        for x in SRCS LSRCS; do
            eval declare -n s="$x"

            for ((i=0;i<${#s[@]};i++)); do
                local sdev=${s[$i]}
                local sid=${UUIDS[$sdev]}
                local ddev=${DESTS[${SRC2DEST[$sid]}]}

                [[ -z ${FILESYSTEMS[$sdev]} ]] && continue

                mkdir -p "/mnt/$ddev" "/mnt/$sdev"

                local tdev=$sdev

                {
                    if [[ $x == LSRCS && ${#LMBRS[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                        local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | cut -d ' ' -f1)
                        local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${VG_SRC_NAME}" | uniq | cut -d ' ' -f2)
                        tdev='snap4clone'
                        mkdir -p "/mnt/$tdev"
                        lvremove -q -f "${VG_SRC_NAME}/$tdev"
                        lvcreate -l100%FREE -s -n snap4clone "${VG_SRC_NAME}/$lv_src_name" && \
                        sleep 3 && \
                        mount_ "/dev/${VG_SRC_NAME}/$tdev" -p "/mnt/$tdev" || return 1
                    else
                        mount_ "$sdev"
                    fi
                } >/dev/null 2>>$F_LOG

                mount_ "$ddev"

                message -c "Cloning $sdev to $ddev"
                {
                    if $INTERACTIVE; then
                        local size=$( \
                            rsync -aSXxH --stats --dry-run "/mnt/$tdev/" "/mnt/$ddev" \
                        | grep -oP 'Number of files: \d*(,\d*)*' \
                        | cut -d ':' -f2 \
                        | tr -d ' ' \
                        | sed -e 's/,//' \
                        )
                        rsync -vaSXxH "/mnt/$tdev/" "/mnt/$ddev" | pv -lep -s "$size"
                    else
                        rsync -aSXxH "/mnt/$tdev/" "/mnt/$ddev"
                    fi

                    sleep 3
                    umount_ "/dev/${VG_SRC_NAME}/$tdev"
                    lvremove -q -f "${VG_SRC_NAME}/$tdev"

                    _finish
                } >/dev/null 2>>$F_LOG
                message -y
            done
        done

        return 0
    }

    if [[ $_RMODE ]]; then
        message -c "Validating checksums"
        {
            pushd "$SRC" || return 1
            validate_m5dsums "$SRC" "$F_CHESUM" || { message -n && exit_ 1; }
        } >/dev/null 2>>$F_LOG
        message -y
    fi

    message -c "Cloning disk layout"
    {
        local f=$([[ $_RMODE ]] && echo $F_PART_LIST)
        _prepare_disk #First collect what we have in our backup
        init_srcs $f
        set_src_uuids $f #Then create the filesystems and PVs
        disk_setup

        if [[ ${#LMBRS[@]} -gt 0 ]]; then
            _lvm_setup $f
            sleep 3
        fi

        set_dest_uuids     #Now collect what we have created

        if [[ ${#SUUIDS[@]} != "${#DUUIDS[@]}" || ${#SPUUIDS[@]} != "${#DPUUIDS[@]}" || ${#SNAMES[@]} != "${#DNAMES[@]}" ]]; then
            echo >&2 "Source and destination tables for UUIDs, PARTUUIDs or NAMES did not macht. This should not happen!"
            return 1
        fi

        for ((i=0;i<${#SUUIDS[@]};i++)); do SRC2DEST[${SUUIDS[$i]}]=${DUUIDS[$i]}; done
        for ((i=0;i<${#SPUUIDS[@]};i++)); do PSRC2PDEST[${SPUUIDS[$i]}]=${DPUUIDS[$i]}; done
        for ((i=0;i<${#SNAMES[@]};i++)); do NSRC2NDEST[${SNAMES[$i]}]=${DNAMES[$i]}; done

        [[ ! $_RMODE ]] && mounts
    } >/dev/null 2>>$F_LOG
    message -y

    [[ -d $SRC ]] && COUNT=$(cat $SRC/$F_SECTORS_USED)

    local cnt
    [[ -b $DEST ]] && cnt=$(echo $(lsblk --bytes -o SIZE,TYPE $DEST | grep 'disk' | sed -e 's/\s+*.*//') / 1024 | bc)
    [[ -d $DEST ]] && cnt=$(df -k --output=avail $DEST | tail -n -1)

    (( cnt - COUNT <= 0 )) && exit_ 1 "Require $((COUNT/1024))M but destination is only $((cnt/1024))M"

    if [[ $_RMODE ]]; then
        _from_file || return 1
        popd >/dev/null || return 1
    else
        _clone || return 1
    fi

    if $HAS_GRUB; then
        message -c "Installing Grub"
        {
            if [[ -n  ${MOUNTS[/boot]} ]]; then
                grub_setup ${DESTS[${SRC2DEST[${MOUNTS[/]}]}]} ${DESTS[${SRC2DEST[${MOUNTS[/boot]}]}]} || return 1
            else
                grub_setup ${DESTS[${SRC2DEST[${MOUNTS[/]}]}]} || return 1
            fi
        } >/dev/null 2>>$F_LOG
        message -y
    fi
}

Main() {
    [[ -b $SRC && -b $DEST ]] && Clone
    [[ -d "$SRC" && -b $DEST ]] && Clone -r
    [[ -b "$SRC" && -d $DEST ]] && To_file
}


### ENTRYPOINT
exec 3>&1 4>&2
trap Cleanup INT TERM

tput sc
echo > $F_LOG

# exec 2> /dev/null
#Force root
if [ "$(id -u)" != "0" ]; then
  exec sudo "$0" "$@" 
fi


#Inform about ALL missing but necessary tools.
for c in parallel rsync tar flock bc blockdev fdisk sfdisk; do
    hash $c 2>/dev/null || { echo >&2 "ERROR: $c missing."; abort='exit 1'; }
done
eval "$abort"


#Lock the script, only one instance is allowed to run at the same time!
exec 200>"$PIDFILE"
flock -n 200 || exit 1
pid=$$
echo $pid 1>&200

#Make sure BASH is the right version so we can use array references!
v=$(echo "${BASH_VERSION%.*}" | tr -d '.')
(( v<43 )) && echo "ERROR: Bash version must be 4.3 or greater!" && exit 1

[[ $(id -u) != 0 ]] && exec sudo "$0" "$@"

while getopts ':hiqs:d:n:' option; do
    case "$option" in
        h)  usage
            ;;
        s)  SRC=$OPTARG
            ;;
        d)  DEST=$OPTARG
            ;;
        n)  VG_SRC_NAME_CLONE=$OPTARG
            ;;
        q)  exec &> /dev/null
            ;;
        i)  { hash pv 2>/dev/null && INTERACTIVE=true; } || 
            { echo >&2 "WARNING: Package pv is not installed. Interactive mode disabled."; }
            ;;
        :)  printf "missing argument for -%s\n" "$OPTARG"
            usage
            ;;
        ?)  printf "illegal option: -%s\n" "$OPTARG"
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

[[ -z $SRC || -z $DEST ]] && \
    usage

[[ -d $SRC && ! -b $DEST ]] && \
    echo "$DEST is not a valid block device." && exit 1

[[ -d $DEST && ! -b $SRC ]] && \
    echo "$DEST is not a valid block device." && exit 1

[[ ! -d $SRC && ! -b $SRC && -b $DEST ]] && \
    echo "Invalid device or directory: $SRC" && exit 1

[[ -b $SRC && ! -b $DEST && ! -d $DEST ]] && \
    echo "Invalid device or directory: $DEST" && exit 1

if [[ -d $SRC ]]; then
  [[ -f $SRC/$F_PART_LIST &&
     -f $SRC/$F_VGS_LIST &&
     -f $SRC/$F_LVS_LIST &&
     -f $SRC/$F_PVS_LIST &&
     -f $SRC/$F_SECTORS_SRC &&
     -f $SRC/$F_SECTORS_USED &&
     -f $SRC/$F_PART_TABLE ]] || { message -n "Cannot restore dump, files missing" && exit 1; }
fi


VG_SRC_NAME=$(echo $(if [[ -d $SRC ]]; then cat $SRC/$F_PVS_LIST; else pvs --noheadings -o pv_name,vg_name | grep "$SRC"; fi) | sed -e 's/^\s*//' | cut -d ' ' -f2 | uniq)
[[ -z $VG_SRC_NAME_CLONE ]] && VG_SRC_NAME_CLONE=${VG_SRC_NAME}_${CLONE_DATE}

Main


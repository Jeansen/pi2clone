#! /usr/bin/env bash

# Copyright (C) 2017-2018 Marcel Lautenbach
#
# Thisrogram is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License asublished by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Thisrogram is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with thisrogram.  If not, see <http://www.gnu.org/licenses/>.

USAGE=$(cat <<EOF

$(basename "$0") [-h] -s src -d dest

where:
    -h  Show this help text
    -s  Source block device or folder
    -d  Destination block device or folder
EOF
)

to_file() {
    declare -A filesystems mounts partuuids uuids types
    local src="$1" dest="$2" islvm=false
    local srcs=()

    pushd "$dest" >/dev/null

    sfdisk -d "$src" > part_table
    lsblk -Ppo KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$src" | uniq > part_list

    while read -r e; do
        read -r dev fstype uuid puuid type parttype mnt<<< "$e"
        eval "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mnt"
        [[ $FSTYPE == swap || $FSTYPE == LVM2_member ]] && continue
        [[ $TYPE == lvm ]] && lsrcs+=($KNAME) && islvm=true
        [[ $TYPE == part ]] && srcs+=($KNAME)
        filesystems[$KNAME]="$FSTYPE"
        mounts[$KNAME]="$MOUNTPOINT"
        partuuids[$KNAME]="$PARTUUID"
        uuids[$KNAME]="$UUID"
        types[$KNAME]="$TYPE"
    done < <(lsblk -Ppo KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$src")

    for x in srcs lsrcs; do
        eval declare -n s="$x"

        for ((i=0;i<${#s[@]};i++)); do
            local sdev=${s[$i]}
            local sid=${uuids[$sdev]}
            local spid=${partuuids[$sdev]}
            local fs=${filesystems[$sdev]}
            local type=${types[$sdev]}

            mkdir -p "/mnt/$sdev"
            mount "$sdev" -t "$fs" "/mnt/$sdev"

            tar -Scpf "${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}" \
                --directory="/mnt/$sdev" \
                --exclude=proc/* \
                --exclude=dev/* \
                --exclude=sys/* \
                --atime-preserve \
                --numeric-owner \
                --xattrs .
        done

        for ((i=0;i<${#s[@]};i++)); do umount "/mnt/${s[$i]}"; done
    done

    $islvm && vgcfgbackup && cp -r /etc/lvm/backup lvm

    popd >/dev/null
}

from_file() {
    declare -A lfs dests src2dest psrc2pdest
    local src="$1" dest="$2"
    local sfs=() lmbrs=() srcs=() 
    local spuuids=() suuids=() 
    local dpuuids=() duuids=()

    _set_uuids() {
        local src_dest=$1
        local file=$2
        [[ $src_dest == dest ]] && dpuuids=() duuids=()
        [[ $src_dest == src ]] && spuuids=() suuids=()

        while read -r e; do
            read -r dev fstype uuid puuid type parttype mnt<<< "$e"
            eval "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mnt"
            [[ $FSTYPE == swap ]] && continue
            if [[ $src_dest == dest ]]; then
                [[ -n $UUID ]] && dests[$UUID]=$KNAME
                dpuuids+=($PARTUUID)
                duuids+=($UUID)
            fi
            if [[ $src_dest == src ]]; then
                [[ $TYPE == lvm ]] && lfs[$KNAME]=$FSTYPE
                [[ $FSTYPE == LVM2_member ]] && lmbrs[${KNAME: -1}]="$UUID"
                [[ $TYPE == part && $FSTYPE != LVM2_member ]] && sfs[${KNAME: -1}]=$FSTYPE
                spuuids+=($PARTUUID)
                suuids+=($UUID)
            fi
            if [[ $src_dest == mkfs ]]; then
                if [[ $TYPE == part ]]; then
                    [[ ${sfs[${KNAME: -1}]} ]] && mkfs -t "${sfs[${KNAME: -1}]}" "$KNAME"
                    [[ ${lmbrs[${KNAME: -1}]} ]] && pvcreate "$KNAME" 2>/dev/null
                fi
            fi
        done < <( if [[ -n $file ]]; then cat "$file"; 
                  else lsblk -Ppo KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$dest";
                  fi
                )
    }

    _boot_setup() {
        p=$(declare -p "$1")
        eval "declare -A sd=${p#*=}"

        for k in "${!sd[@]}"; do
            for d in "${dests[@]}"; do
                sed -i "s/$k/${sd[$k]}/" "/mnt/$d/cmdline.txt" "/mnt/$d/etc/fstab" 2>/dev/null
            done
        done
    }

    _lvm_setup() {
        #Now replace UUIDs from backup with new ones - only for lvm
        for ((i=0;i<${#suuids[@]};i++)); do 
            sed -i "s/${suuids[$i]}/${duuids[$i]}/" lvm/*;
        done

        #Finally resstore lvm partitions ...
            for f in lvm/*; do
                vgcfgrestore -f "$f" "${f##*/}"
                vgchange -ay "${f##*/}"
            done

        #... create filesystems on the just created LVs ...
        for key in "${!lfs[@]}"; do 
            mkfs -t "${lfs[$key]}" "$key";
        done
    }

    pushd "$src" >/dev/null

    dd if=/dev/zero of="$dest" bs=512 count=100000 
    sleep 3 #NOTE: This is necessary to have changes made by dd, mkfs and sfdisk settle. In addition, sleep hat to be 
            #on its on line!

    sfdisk --force "$dest" < part_table 
    sleep 3

    #First collect what we have in our backup
    _set_uuids "src" "part_list"

    #Then create the filesystems and PVs
    _set_uuids "mkfs" 
    sleep 3

    #Now collect what we have created
    _set_uuids "dest"

    if [[ -d lvm ]]; then
        _lvm_setup 
        sleep 3
        #... and after that collect what we have created, again
        _set_uuids "dest"
    fi

    if [[ ${#suuids[@]} != "${#duuids[@]}" || ${#spuuids[@]} != "${#dpuuids[@]}" ]]; then
        echo "Source and destination tables for UUIDs or PARTUUIDs did not macht. This should not happen!"
        exit 1
    fi

    for ((i=0;i<${#suuids[@]};i++)); do src2dest[${suuids[$i]}]=${duuids[$i]}; done
    for ((i=0;i<${#spuuids[@]};i++)); do psrc2pdest[${spuuids[$i]}]=${dpuuids[$i]}; done

    #Now, we are ready to restore files from previous backup images
    for file in [0-9]*; do
        if [[ -n $file ]]; then
            read -r i uuid puuid fs type dev <<< "$e" <<< "${file//./ }";
            local ddev=${dests[${src2dest[$uuid]}]}

            if [[ -n $ddev ]]; then
                mkdir -p "/mnt/$ddev"
                mount "$ddev" -t "$fs" "/mnt/$ddev"

                pushd "/mnt/$ddev" >/dev/null
                if [[ $fs == vfat ]]; then
                    fakeroot tar -xf "${src}/${file}" -C "/mnt/$ddev"
                else
                    tar -xf "${src}/${file}" -C "/mnt/$ddev"
                fi
                popd >/dev/null
            fi
        fi
    done

    popd >/dev/null

    _boot_setup "src2dest"
    _boot_setup "psrc2pdest"

    for k in "${!dests[@]}"; do umount "/mnt/${dests[$k]}"; done
}

clone() {
    declare -A filesystems mounts partuuids
    local src="$1" dest="$2"
    local dests=() srcs=()

    dd if=/dev/zero of="$dest" bs=512 count=100000

    sfdisk --force "$dest" < <(sfdisk -d "$src")

    sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. 
            #Otherwise resultes from lsblk might still show old values!

    for disk in $src $dest; do
        while read -r e; do
            read -r dev fstype uuid part parttype mnt<<< "$e"
            eval "$dev" "$fstype" "$uuid" "$part" "$parttype" "$mnt"
            filesystems[$KNAME]="$FSTYPE"
            mounts[$KNAME]="$MOUNTPOINT"
            partuuids[$KNAME]="$PARTUUID"
            [[ $disk =~ $src ]] && ((PARTTYPE != 5)) && srcs+=($KNAME)
            [[ $disk =~ $dest ]] && ((PARTTYPE != 5)) && dests+=($KNAME)
        done < <(lsblk -Ppo KNAME,FSTYPE,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT | grep "$disk" | grep 'part')
    done

    for ((i=0;i<${#srcs[@]};i++)); do
        local sdev=${srcs[$i]}
        local ddev=${dests[$i]}
        local fs=${filesystems[$sdev]}

        [[ $fs == swap ]] && continue
        mkfs -t "$fs" "$ddev"

        sleep 3 #IMPORTANT !!! So changes by mkfs can settle.

        mkdir -p "/mnt/$ddev"
        mkdir -p "/mnt/$sdev"
        mount "$ddev" -t "${filesystems[$sdev]}" "/mnt/$ddev"
        mount "$sdev" -t "${filesystems[$sdev]}" "/mnt/$sdev"

        rsync -aSXxH "/mnt/$sdev/" "/mnt/$ddev"
    done

    for ((i=0;i<${#srcs[@]};i++)); do
        local sid=${partuuids[${srcs[$i]}]}
        local did=${partuuids[${dests[$i]}]}

        for d in "${dests[@]}"; do
            sed -i "s/$sid/$did/" "/mnt/$d/cmdline.txt" 2>/dev/null
            sed -i "s/$sid/$did/" "/mnt/$d/etc/fstab" 2>/dev/null
        done
    done

    for ((i=0;i<${#srcs[@]};i++)); do
        umount "/mnt/${dests[$i]}"
        umount "/mnt/${srcs[$i]}"
    done
}

main() {
    local src="$1"
    local dest="$2"
    [[ -b $SRC && -b $DEST ]] && clone "$src" "$dest"
    [[ -d "$SRC" && -b $DEST ]] && from_file "$src" "$dest"
    [[ -b "$SRC" && -d $DEST ]] && to_file "$src" "$dest"
}


### ENTRYPOINT

v=$(echo "${BASH_VERSION%.*}" | tr -d '.')
(( v<43 )) && echo "ERROR: Bash version must be 4.3 or greater!" && exit 1

[[ $(id -u) != 0 ]] && exec sudo "$0" "$@"

while getopts ':hs:d:' option; do
    case "$option" in
        h) echo "$USAGE" && exit
            ;;
        s) SRC=$OPTARG
            ;;
        d) DEST=$OPTARG
            ;;
        :) printf "missing argument for -%s\n" "$OPTARG" >&2
            echo "$USAGE" && exit 1
            ;;
        \?) printf "illegal option: -%s\n" "$OPTARG" >&2
            echo "$USAGE" && exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

[[ -z $SRC || -z $DEST ]] && \
    echo "$USAGE" && exit 1

[[ -d $SRC && ! -b $DEST ]] && \
    echo "$DEST is not a valid block device." && exit 1

[[ -d $DEST && ! -b $SRC ]] && \
    echo "$DEST is not a valid block device." && exit 1

[[ ! -d $SRC && ! -b $SRC && -b $DEST ]] && \
    echo "Invalid device or directory: $SRC" && exit 1

[[ -b $SRC && ! -b $DEST && ! -d $DEST ]] && \
    echo "Invalid device or directory: $DEST" && exit 1


main "$SRC" "$DEST"


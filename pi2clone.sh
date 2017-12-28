#! /usr/bin/env bash

# Copyright (C) 2017 Marcel Lautenbach
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
    declare -A filesystems mounts partuuids
    local src="$1" dest="$2"
    local srcs=()

    pushd "$dest" >/dev/null
    sfdisk -d "$src" > part_table

    while read -r e; do
        read -r dev fstype uuid part parttype mnt<<< "$e"
        eval "$dev" "$fstype" "$uuid" "$part" "$parttype" "$mnt"
        filesystems[$KNAME]="$FSTYPE"
        mounts[$KNAME]="$MOUNTPOINT"
        partuuids[$KNAME]="$PARTUUID"
        ((PARTTYPE != 5 )) && srcs+=($KNAME)
    done < <(lsblk -Ppo KNAME,FSTYPE,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT | grep "$src" | grep 'part')

    for ((i=0;i<${#srcs[@]};i++)); do
        local sdev=${srcs[$i]}
        local sid=${partuuids[$sdev]}
        local fs=${filesystems[$sdev]}

        mkdir -p "/mnt/$sdev"
        mount "$sdev" -t "$fs" "/mnt/$sdev"

        tar -Scpf "${i}.${sid}.${fs}.${sdev//\//_}" --directory="/mnt/$sdev" --exclude=proc/* --exclude=dev/* --exclude=sys/* --atime-preserve --numeric-owner --xattrs .
    done

    popd >/dev/null

    for ((i=0;i<${#srcs[@]};i++)); do umount "/mnt/${srcs[$i]}"; done
}

from_file() {
    local src="$1" dest="$2"
    local srcs=() dests=() duuids=() suuids=()

    pushd "$src" >/dev/null

    dd if=/dev/zero of="$dest" bs=512 count=100000
    sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. Otherwise resultes from lsblk might still show old values!

    sfdisk --force "$dest" < part_table
    sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. Otherwise resultes from lsblk might still show old values!

    while read -r e; do
        read -r dev fstype uuid part parttype mnt<<< "$e"
        eval "$dev" "$fstype" "$uuid" "$part" "$parttype" "$mnt"
        ((PARTTYPE != 5 )) && dests+=($KNAME)
        duuids+=($PARTUUID)
    done < <(lsblk -Ppo KNAME,FSTYPE,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT | grep "$dest" | grep 'part')

    for file in [0-9]*; do
        if [[ -n $file ]]; then
            read -r i uuid fs dev tool <<< "$e" <<< "${file//./ }";
            suuids+=($uuid)
            local ddev=${dests[$i]}

            mkfs -t "$fs" "$ddev"

            sleep 3

            mkdir -p "/mnt/$ddev"
            mount "$ddev" -t "$fs" "/mnt/$ddev"

            pushd "/mnt/$ddev" >/dev/null
            tar -xf "${src}/${file}" -C "/mnt/$ddev"
            popd >/dev/null
        fi
    done
    popd >/dev/null

    for ((i=0;i<${#suuids[@]};i++)); do
        local sid=${suuids[$i]}
        local did=${duuids[$i]}

        for d in "${dests[@]}"; do
            sed -i "s/PARTUUID=$sid/PARTUUID=$did/" "/mnt/$d/cmdline.txt" 2>/dev/null
            sed -i "s/PARTUUID=$sid/PARTUUID=$did/" "/mnt/$d/etc/fstab" 2>/dev/null
        done
    done

    for ((i=0;i<${#dests[@]};i++)); do umount "/mnt/${dests[$i]}"; done
}

clone() {
    declare -A filesystems mounts partuuids
    local src="$1" dest="$2"
    local dests=() srcs=()

    dd if=/dev/zero of="$dest" bs=512 count=100000

    sfdisk --force "$dest" < <(sfdisk -d "$src")

    sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. Otherwise resultes from lsblk might still show old values!

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
            sed -i "s/PARTUUID=$sid/PARTUUID=$did/" "/mnt/$d/cmdline.txt" 2>/dev/null
            sed -i "s/PARTUUID=$sid/PARTUUID=$did/" "/mnt/$d/etc/fstab" 2>/dev/null
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

if ! hash dump; then
    echo "ERROR! Package dump missing!" && exit 1
fi

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


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


SCRIPTNAME=$(basename "$0")
PIDFILE="/var/run/$SCRIPTNAME"
INTERACTIVE=false
export LVM_SUPPRESS_FD_WARNINGS=true

USAGE="
Usage: $(basename $0) [-h] -s src -d dest

Where:
    -h  Show this help text
    -s  Source block device or folder
    -d  Destination block device or folder
    -q  Quiet, do not show any output
    -i  Interactive, showing progress bars
"

usage() {
    printf "%s\n" "$USAGE"
    exit 1
}

cleanup() {
    [[ -d $SRC/lvm_ ]] && rm -rf $SRC/lmv_
    exit 255
}

to_file() {
    declare -A filesystems mounts partuuids uuids types
    local src="$1" dest="$2" islvm=false
    local srcs=()

    pushd "$dest" >/dev/null

    sfdisk -d "$src" > part_table
    sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. 
            #Otherwise resultes from lsblk might still show old values!
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
    done < <(lsblk -Ppo KNAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$src") #use par_list

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


            cmd="tar --directory=/mnt/$sdev --exclude=proc/* --exclude=dev/* --exclude=sys/* --atime-preserve --numeric-owner --xattrs"
            if $INTERACTIVE; then 
                local size=$(du --bytes --exclude=proc/* --exclude=sys/* -s /mnt/$sdev | tr -s '\t' ' ' | cut -d ' ' -f 1)
                cmd="$cmd -Scpf - . | pv --rate --timer --eta -pe -s $size > ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}" 
            else
                cmd="$cmd -Scpf ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_} ."  
            fi
            echo "Creating backup for $sdev"
            eval "$cmd"
        done

        for ((i=0;i<${#s[@]};i++)); do umount "/mnt/${s[$i]}" 2>/dev/null; done
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
        cp -r lvm lvm_
        for ((i=0;i<${#suuids[@]};i++)); do 
            sed -i "s/${suuids[$i]}/${duuids[$i]}/" lvm_/*;
        done

        #Finally resstore lvm partitions ...
        for f in lvm_/*; do
            vgcfgrestore -f "$f" "${f##*/}"
            vgchange -ay "${f##*/}"
        done
        rm -rf lvm_

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

    for k in "${!dests[@]}"; do umount "/mnt/${dests[$k]}" 2>/dev/null; done
} 

clone() {
    local src="$1" dest="$2"
    declare -A filesystems mounts partuuids uuids types
    declare -A src_lfs dest_lfs dests src2dest psrc2pdest

    local spuuids=() suuids=() 
    local dpuuids=() duuids=()
    local sfs=() lmbrs=() srcs=() ldests=()
    local vg_src_name vg_src_name_clone

    _set_uuids() {
        local src_dest=$1
        local mkfs=$2
        [[ $src_dest == dest ]] && dpuuids=() duuids=()
        [[ $src_dest == src ]] && spuuids=() suuids=()

        while read -r e; do
            read -r kdev dev fstype uuid puuid type parttype mnt<<< "$e"
            eval "$kdev" "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mnt"
            [[ $FSTYPE == swap ]] && continue
            if [[ $src_dest == dest ]]; then
                [[ -n $UUID ]] && dests[$UUID]=$NAME
                dpuuids+=($PARTUUID)
                duuids+=($UUID)
            fi
            if [[ $src_dest == src ]]; then
                [[ $FSTYPE == LVM2_member ]] && lmbrs[${NAME: -1}]="$UUID"
                [[ $TYPE == part && $FSTYPE != LVM2_member ]] && sfs[${NAME: -1}]=$FSTYPE
                spuuids+=($PARTUUID)
                suuids+=($UUID)
            fi
            if [[ -n $mkfs ]]; then
                if [[ $TYPE == part ]]; then
                    [[ ${sfs[${NAME: -1}]} ]] && mkfs -t "${sfs[${NAME: -1}]}" "$NAME"
                    [[ ${lmbrs[${NAME: -1}]} ]] && pvcreate "$NAME" 2>/dev/null
                fi
            fi
        done < <( eval lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "\$$src_dest" )
    }

    _lvm_setup() {
        vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | cut -d ' ' -f2)
        vg_src_name_clone="${vg_src_name}_clone"
        
        while read -r e; do
            read -r pv_name vg_name<<< "$e"
            [[ -z $vg_name ]] && vgcreate "$vg_src_name_clone" "$pv_name"
        done < <( pvs --noheadings -o pv_name,vg_name )

        while read -r e; do
            read -r lv_name vg_name lv_size<<< "$e"
            lvcreate -L "$lv_size" -n "$lv_name" "$vg_src_name_clone"
        done < <( lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size )

        for d in $SRC $DEST; do
            while read -r e; do
                read -r kdev dev fstype type<<< "$e"
                eval "$kdev" "$dev" "$fstype" "$type"
                [[ $TYPE == 'lvm' && $d == "$SRC" ]] && src_lfs[${NAME##*$vg_src_name-}]=$FSTYPE 
                [[ $TYPE == 'lvm' && $d == "$DEST" ]] && mkfs -t "${src_lfs[${NAME##*$vg_src_name_clone-}]}" "$NAME";
            done < <( eval lsblk -Ppo KNAME,NAME,FSTYPE,TYPE "$d" )
        done
    }

    _prepare_disk() {
        local vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$src" | xargs | cut -d ' ' -f2)
        local vg_src_name_clone="${vg_src_name}_clone"

        vgchange -an "$vg_src_name_clone" 2>/dev/null
        vgremove -f "$vg_src_name_clone" 2>/dev/null

        dd if=/dev/zero of="$dest" bs=512 count=100000
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

    _prepare_disk

    sleep 3

    sfdisk --force "$dest" < <(sfdisk -d "$src")

    sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. 
            #Otherwise resultes from lsblk might still show old values!

    while read -r e; do
        read -r kdev dev fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kdev" "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mnt"
        [[ $FSTYPE == swap || $FSTYPE == LVM2_member ]] && continue
        [[ $TYPE == lvm ]] && lsrcs+=($NAME) && islvm=true
        [[ $TYPE == part ]] && srcs+=($NAME)
        filesystems[$NAME]="$FSTYPE"
        mounts[$NAME]="$MOUNTPOINT"
        partuuids[$NAME]="$PARTUUID"
        uuids[$NAME]="$UUID"
        types[$NAME]="$TYPE"
    done < <(lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$src")

    #First collect what we have in our backup
    _set_uuids "src"

    #Then create the filesystems and PVs
    _set_uuids "dest" "mkfs" 
    sleep 3

    #Now collect what we have created
    _set_uuids "dest"

    if [[ ${#lmbrs[@]} -gt 0 ]]; then 
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

    for x in srcs lsrcs; do
        eval declare -n s="$x"

        for ((i=0;i<${#s[@]};i++)); do
            local sdev=${s[$i]}
            local sid=${uuids[$sdev]}
            local spid=${partuuids[$sdev]}
            local fs=${filesystems[$sdev]}
            local type=${types[$sdev]}

            local ddev=${dests[${src2dest[$sid]}]}
            mkdir -p "/mnt/$ddev"
            mkdir -p "/mnt/$sdev"

            if [[ $x == lsrcs ]]; then
                mkdir -p "/mnt/snap4clone"
                lvcreate -l100%FREE -s -n snap4clone "${vg_src_name}/$lv_name"
                sleep 3
                mount "/dev/${vg_src_name}/snap4clone" -t "${filesystems[$sdev]}" "/mnt/snap4clone"
            else
                mount "$sdev" -t "${filesystems[$sdev]}" "/mnt/$sdev"
            fi

            mount "$ddev" -t "${filesystems[$sdev]}" "/mnt/$ddev"

            echo "Cloning $sdev"
            if [[ $x == lsrcs ]]; then
                if $INTERACTIVE; then
                    local size=$( \
                          rsync -aSXxH --stats --dry-run "/mnt/snap4clone/" "/mnt/$ddev" \
                        | grep -oP 'Number of files: \d*(,\d*)*' \
                        | cut -d ':' -f2 \
                        | tr -d ' ' \
                        | sed -e 's/,//' \
                    )
                    rsync -vaSXxH "/mnt/snap4clone/" "/mnt/$ddev" | pv -lep -s "$size" >/dev/null
                else
                    rsync -aSXxH "/mnt/snap4clone/" "/mnt/$ddev"
                fi
                sleep 3
                umount "/mnt/snap4clone/" 2>/dev/null
                lvremove -f "${vg_src_name}/snap4clone"
            else
                if $INTERACTIVE; then
                    local size=$( \
                          rsync -aSXxH --stats --dry-run "/mnt/$sdev/" "/mnt/$ddev" \
                        | grep -oP 'Number of files: \d*(,\d*)*' \
                        | cut -d ':' -f2 \
                        | tr -d ' ' \
                        | sed -e 's/,//' \
                    )
                    rsync -vaSXxH "/mnt/$sdev/" "/mnt/$ddev" | pv -lep -s "$size" >/dev/null
                else
                    rsync -aSXxH "/mnt/$sdev/" "/mnt/$ddev"
                fi
            fi

            sed -i "s/$vg_src_name/$vg_src_name_clone/" "/mnt/$ddev/cmdline.txt" "/mnt/$ddev/etc/fstab" 2>/dev/null
        done

        _boot_setup "src2dest"
        _boot_setup "psrc2pdest"

        for ((i=0;i<${#s[@]};i++)); do umount "/mnt/${s[$i]}" 2>/dev/null; done
        for ((i=0;i<${#s[@]};i++)); do umount "/mnt/${dests[${src2dest[${uuids[${s[$i]}]}]}]}" 2>/dev/null; done
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

trap cleanup INT

for c in rsync tar flock; do
    hash $c 2>/dev/null || { echo >&2 "ERROR: $c missing."; abort='exit 1'; }
done

eval $abort


#Lock the script, only one instance is allowed to run at the same time!
exec 200>"$PIDFILE"
flock -n 200 || exit 1
pid=$$
echo $pid 1>&200

#Make sure BASH is the right version so we can use array references!
v=$(echo "${BASH_VERSION%.*}" | tr -d '.')
(( v<43 )) && echo "ERROR: Bash version must be 4.3 or greater!" && exit 1

[[ $(id -u) != 0 ]] && exec sudo "$0" "$@"

while getopts ':hiqs:d:' option; do
    case "$option" in
        h)  usage
             ;;
        s)  SRC=$OPTARG
             ;;
        d)  DEST=$OPTARG
             ;;
        q)  exec &> /dev/null
             ;;
        i)  { hash pv 2>/dev/null && INTERACTIVE=true; } || 
            { echo >&2 "WARNING: Package pv is not installed. Interactive mode disabled."; }
             ;;
        :)  printf "missing argument for -%s\n" "$OPTARG" >&2
            usage
             ;;
        \?) printf "illegal option: -%s\n" "$OPTARG" >&2
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


main "$SRC" "$DEST"


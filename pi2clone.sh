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

declare -A lfs filesystems mounts names partuuids uuids types puuids2uuids
declare -A src_lfs dest_lfs dests src2dest psrc2pdest nsrc2ndest

spuuids=() suuids=() 
dpuuids=() duuids=()
sfs=() lmbrs=() srcs=() ldests=() lsrcs=()

declare vg_src_name vg_src_name_clone

has_grub=false
islvm=false

USAGE="
Usage: $(basename $0) [-h] -s src -d dest

Where:
    -h  Show this help text
    -s  Source block device or folder
    -d  Destination block device or folder
    -q  Quiet, do not show any output
    -i  Interactive, showing progress bars
"

#DEBUG ONLY
printarr() { declare -n __p="$1"; for k in "${!__p[@]}"; do printf "%s=%s\n" "$k" "${__p[$k]}" ; done ;  }

_set_dest_uuids() {
    dpuuids=() duuids=() dnames=()
    while read -r e; do
        read -r kdev dev fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kdev" "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $TYPE == disk ]] && continue
        [[ -n $UUID ]] && dests[$UUID]=$NAME
        dpuuids+=($PARTUUID)
        duuids+=($UUID)
        dnames+=($NAME)
    done < <( lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" )
}

_set_src_uuids() {
    spuuids=() suuids=() snames=()
    while read -r e; do
        read -r kdev dev fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kdev" "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $TYPE == disk ]] && continue
        [[ $FSTYPE == LVM2_member ]] && lmbrs[${NAME: -1}]="$UUID"
        [[ $TYPE == part && $FSTYPE != LVM2_member ]] && sfs[${NAME: -1}]=$FSTYPE
        spuuids+=($PARTUUID)
        suuids+=($UUID)
        snames+=($NAME)
    done < <( if [[ -n $1 ]]; then cat "$1"; 
            else lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC";
            fi
            )
}
_init_srcs() {
    while read -r e; do
        read -r kdev dev fstype uuid puuid type parttype mountpoint<<< "$e"
        eval "$kdev" "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $FSTYPE == LVM2_member || $FSTYPE == swap || $TYPE == disk ]] && continue
        [[ $TYPE == lvm ]] && lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -qv && lsrcs+=($NAME) && islvm=true
        [[ $TYPE == part ]] && srcs+=($NAME)
        filesystems[$NAME]="$FSTYPE"
        partuuids[$NAME]="$PARTUUID"
        uuids[$NAME]="$UUID"
        types[$NAME]="$TYPE"
        [[ -n $UUID ]] && names[$UUID]=$NAME
        [[ -n $PARTUUID ]] && names[$PARTUUID]=$NAME
        [[ -n $UUID && -n $PARTUUID ]] && puuids2uuids[$PARTUUID]="$UUID"
    done < <( if [[ -n $1 ]]; then cat "$1"; 
            else lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC";
            fi
            )
}

_disk_setup() {
    while read -r e; do
        read -r kdev dev fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kdev" "$dev" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        if [[ ${sfs[${NAME: -1}]} == swap ]]; then
            mkswap "$NAME"
        else
            [[ ${sfs[${NAME: -1}]} ]] && mkfs -t "${sfs[${NAME: -1}]}" "$NAME"
            [[ ${lmbrs[${NAME: -1}]} ]] && pvcreate "$NAME" 2>/dev/null
        fi
    done < <( lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" )
}

_boot_setup() {
    p=$(declare -p "$1")
    eval "declare -A sd=${p#*=}"

    for k in "${!sd[@]}"; do
        for d in "${dests[@]}"; do
            sed -i "s|$k|${sd[$k]}|" \
                "/mnt/$d/cmdline.txt" "/mnt/$d/etc/fstab" \
                "/mnt/$d/grub/grub.cfg" "/mnt/$d/boot/grub/grub.cfg" "/mnt/$d/etc/initramfs-tools/conf.d/resume" \
                2>/dev/null
        done
    done
}

_create_rclocal() {
    mv $1/etc/rc.local $1/etc/rc.local.bak 2>/dev/null
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
    reboot' > $1/etc/rc.local
    chmod +x $1/etc/rc.local
}

_grub_setup() {
    local d=$1
    local b=$2

    mount $d /mnt/$d
    [[ -n $b ]] && mount $b /mnt/$d/boot

    for f in sys dev dev/pts proc; do 
        mount --bind /$f /mnt/$d/$f;
    done
    grub-install --boot-directory=/mnt/$d/boot $DEST
    # chroot /mnt/$d update-grub
    chroot /mnt/$d apt-get install -y binutils
    _create_rclocal "/mnt/$d"
    umount -R /mnt/$d
}

_mounts() {
    for x in "${srcs[@]}" "${lsrcs[@]}"; do
        local sdev=$x
        local sid=${uuids[$sdev]}

        mkdir -p "/mnt/$sdev"

        mount "$sdev" "/mnt/$sdev"

        f[0]='cat /mnt/$sdev/etc/fstab | grep "^UUID" | sed -e "s/UUID=//" | tr -s " " | cut -d " " -f1,2'
        f[1]='cat /mnt/$sdev/etc/fstab | grep "^PARTUUID" | sed -e "s/PARTUUID=//" | tr -s " " | cut -d " " -f1,2'
        f[2]='cat /mnt/$sdev/etc/fstab | grep "^/" | tr -s " " | cut -d " " -f1,2'

        if [[ -f /mnt/$sdev/etc/fstab ]]; then
            for ((i=0;i<${#f[@]};i++)); do
                while read -r e; do 
                    read -r dev mnt<<< "$e"
                    if [[ $i -eq 0 && -n ${names[$dev]} ]]; then
                        mounts[$mnt]="$dev" && mounts[$dev]="$mnt"
                    elif [[ $i -eq 1 && -n ${names[$dev]} ]]; then
                        mounts[$mnt]="${puuids2uuids[$dev]}" && mounts[${puuids2uuids[$dev]}]="$mnt"
                    else
                        mounts[$mnt]="${uuids[$sdev]}" && mounts[${uuids[$sdev]}]="$mnt"
                    fi
                done < <(eval "${f[$i]}")
            done
        fi

        umount "/mnt/$sdev"
    done
}

usage() {
    printf "%s\n" "$USAGE"
    exit 1
}

cleanup() {
    [[ -d $SRC/lvm_ ]] && rm -rf $SRC/lmv_
    exit 255
}

to_file() {
    pushd "$DEST" >/dev/null

    sfdisk -d "$SRC" > part_table
    sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. 
            #Otherwise resultes from lsblk might still show old values!
    lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" | uniq > part_list

    _init_srcs
    _set_src_uuids

    vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | cut -d ' ' -f2)

    _mounts

    for x in srcs lsrcs; do
        eval declare -n s="$x"

        for ((i=0;i<${#s[@]};i++)); do
            local sdev=${s[$i]}
            local sid=${uuids[$sdev]}
            local spid=${partuuids[$sdev]}
            local fs=${filesystems[$sdev]}
            local type=${types[$sdev]}
            local mount=${mounts[$sid]}

            echo "SDEV "$sdev
            echo "SID "$sid

            local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | cut -d ' ' -f1)
            local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${vg_src_name}" | uniq | cut -d ' ' -f2)

            [[ -z ${filesystems[$sdev]} ]] && continue

            mkdir -p "/mnt/$sdev"

            local tdev=$sdev

            if [[ $x == lsrcs && ${#lmbrs[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                echo "USING snapshot"
                local tdev='snap4clone'
                mkdir -p "/mnt/$tdev"
                lvcreate -l100%FREE -s -n snap4clone "${vg_src_name}/$lv_src_name"
                sleep 3
                mount "/dev/${vg_src_name}/$tdev" "/mnt/$tdev"
            else
                mount "$sdev" -t "${filesystems[$sdev]}" "/mnt/$sdev"
            fi

            cmd="tar --directory=/mnt/$tdev --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* --atime-preserve --numeric-owner --xattrs"

            if $INTERACTIVE; then 
                local size=$(du --bytes --exclude=/proc/* --exclude=/sys/* -s /mnt/$tdev | tr -s '\t' ' ' | cut -d ' ' -f 1)
                cmd="$cmd -Scpf - . | pv --rate --timer --eta -pe -s $size > ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_}" 
            else
                cmd="$cmd -Scpf ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_} ."  
            fi
            echo "Creating backup for $sdev"
            eval "$cmd"

            umount "/mnt/$tdev/" 2>/dev/null
            lvremove -f "${vg_src_name}/$tdev" 2> /dev/null

        done

        for ((i=0;i<${#s[@]};i++)); do umount "/mnt/${s[$i]}" 2>/dev/null; done
    done

    $islvm && rm /etc/lvm/backup/* && vgcfgbackup && cp -r /etc/lvm/backup lvm

    popd >/dev/null
}

from_file() {
    _lvm_setup() {
        #Now replace UUIDs from backup with new ones - only for lvm
        cp -r lvm lvm_
        for ((i=0;i<${#suuids[@]};i++)); do 
            for j in lvm_/*; do [[ -f $j ]] && sed -i "s/${suuids[$i]}/${duuids[$i]}/" "$j"; done
        done

        #Finally resstore lvm partitions ...
        for f in lvm_/*; do
            if [[ -f $f ]]; then
                vgcfgrestore -f "$f" "${f##*/}"
                vgchange -ay "${f##*/}"
            fi
        done
        rm -rf lvm_

        for d in $1 $DEST; do
            while read -r e; do
                read -r kdev dev fstype type<<< "$e"
                eval "$kdev" "$dev" "$fstype" "$type"
                [[ $TYPE == 'lvm' && $d == "part_list" ]] && src_lfs[${NAME##*-}]=$FSTYPE 
                if [[ $TYPE == 'lvm' && $d == "$DEST" ]]; then
                    { [[ "${src_lfs[${NAME##*-}]}" == swap ]] && mkswap "$NAME"; } || mkfs -t "${src_lfs[${NAME##*-}]}" "$NAME";
                fi
            done < <( if [[ -n $1 ]]; then cat "$1"; 
                    else lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$d";
                    fi
                    )
        done
    }

    _prepare_disk() {
        dd if=/dev/zero of="$DEST" bs=512 count=100000
        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"
    }


    pushd "$SRC" >/dev/null

    _prepare_disk
    sleep 3 

    sfdisk --force "$DEST" < part_table 
    sleep 3

    _init_srcs "part_list" 
    _set_src_uuids "part_list"
    _disk_setup
    sleep 3
    _set_dest_uuids     #Now collect what we have created

    if [[ -d lvm ]]; then
        _lvm_setup "part_list" 
        sleep 3
    fi

    _set_dest_uuids     #Now collect what we have created

    if [[ ${#suuids[@]} != "${#duuids[@]}" || ${#spuuids[@]} != "${#dpuuids[@]}" || ${#snames[@]} != "${#dnames[@]}" ]]; then
        echo "Source and destination tables for UUIDs, PARTUUIDs or NAMES did not macht. This should not happen!"
        exit 1
    fi

    for ((i=0;i<${#suuids[@]};i++)); do src2dest[${suuids[$i]}]=${duuids[$i]}; done
    for ((i=0;i<${#spuuids[@]};i++)); do psrc2pdest[${spuuids[$i]}]=${dpuuids[$i]}; done
    for ((i=0;i<${#snames[@]};i++)); do nsrc2ndest[${snames[$i]}]=${dnames[$i]}; done

    #Now, we are ready to restore files from previous backup images
    for file in [0-9]*; do
        if [[ -n $file ]]; then
            read -r i uuid puuid fs type dev mnt <<< "$e" <<< "${file//./ }";
            local ddev=${dests[${src2dest[$uuid]}]}
            
            mounts[${mnt//_/\/}]="$uuid"
            if [[ -n $ddev ]]; then
                mkdir -p "/mnt/$ddev"
                mount "$ddev" -t "$fs" "/mnt/$ddev"

                pushd "/mnt/$ddev" >/dev/null
                if [[ $fs == vfat ]]; then
                    fakeroot tar -xf "${SRC}/${file}" -C "/mnt/$ddev"
                else
                    tar -xf "${SRC}/${file}" -C "/mnt/$ddev"
                fi
                popd >/dev/null
            fi
        fi
    done

    popd >/dev/null
    sleep 3

    [[ -f /mnt/$ddev/grub/grub.cfg || -f /mnt/$ddev/grub.cfg || -f /mnt/$ddev/boot/grub/grub.cfg ]] && has_grub=true

    _boot_setup "src2dest"
    _boot_setup "psrc2pdest"
    # _boot_setup "nsrc2ndest"

    for k in "${!dests[@]}"; do umount "/mnt/${dests[$k]}" 2>/dev/null; done

    if $has_grub; then 
        if [[ -n  ${mounts[/boot]} ]]; then
            _grub_setup ${dests[${src2dest[${mounts[/]}]}]} ${dests[${src2dest[${mounts[/boot]}]}]}
        else
            _grub_setup ${dests[${src2dest[${mounts[/]}]}]}
        fi
    fi
} 

clone() {

    _lvm_setup() {
        vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | cut -d ' ' -f2)
        vg_src_name_clone="${vg_src_name}_clone"
        
        while read -r e; do
            read -r pv_name vg_name<<< "$e"
            [[ -z $vg_name ]] && vgcreate "$vg_src_name_clone" "$pv_name"
        done < <( pvs --noheadings -o pv_name,vg_name )

        while read -r e; do
            read -r lv_name vg_name lv_size vg_size vg_free<<< "$e"
            lvcreate --yes -l$(echo "$lv_size * 100 / $vg_size" | bc)%VG -n "$lv_name" "$vg_src_name_clone"
        done < <( lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free )

        for d in $SRC $DEST; do
            while read -r e; do
                read -r kdev dev fstype type<<< "$e"
                eval "$kdev" "$dev" "$fstype" "$type"
                [[ $TYPE == 'lvm' && $d == "$SRC" ]] && src_lfs[${NAME##*-}]=$FSTYPE 
                if [[ $TYPE == 'lvm' && $d == "$DEST" ]]; then
                    { [[ "${src_lfs[${NAME##*-}]}" == swap ]] && mkswap "$NAME"; } || mkfs -t "${src_lfs[${NAME##*-}]}" "$NAME";
                fi
            done < <( eval lsblk -Ppo KNAME,NAME,FSTYPE,TYPE "$d" )
        done
    }

    _prepare_disk() {
        if hash lvm 2>/dev/null; then
            local vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | cut -d ' ' -f2)
            local vg_src_name_clone="${vg_src_name}_clone"

            vgchange -an "$vg_src_name_clone" 2>/dev/null
            vgremove -f "$vg_src_name_clone" 2>/dev/null
        fi

        dd if=/dev/zero of="$DEST" bs=512 count=100000
        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"
    }

    _prepare_disk
    sleep 3

    sfdisk --force "$DEST" < <(sfdisk -d "$SRC")
    sleep 3 

    _init_srcs         #First collect what we have in our backup
    _set_src_uuids
    _disk_setup              #Then create the filesystems and PVs
    sleep 3

    if [[ ${#lmbrs[@]} -gt 0 ]]; then 
        _lvm_setup
        sleep 3
    fi

    _set_dest_uuids     #Now collect what we have created

    if [[ ${#suuids[@]} != "${#duuids[@]}" || ${#spuuids[@]} != "${#dpuuids[@]}" || ${#snames[@]} != "${#dnames[@]}" ]]; then
        echo "Source and destination tables for UUIDs, PARTUUIDs or NAMES did not macht. This should not happen!"
        exit 1
    fi

    for ((i=0;i<${#suuids[@]};i++)); do src2dest[${suuids[$i]}]=${duuids[$i]}; done
    for ((i=0;i<${#spuuids[@]};i++)); do psrc2pdest[${spuuids[$i]}]=${dpuuids[$i]}; done
    for ((i=0;i<${#snames[@]};i++)); do nsrc2ndest[${snames[$i]}]=${dnames[$i]}; done

    _mounts

    for x in srcs lsrcs; do
        eval declare -n s="$x"

        for ((i=0;i<${#s[@]};i++)); do
            local sdev=${s[$i]}
            local sid=${uuids[$sdev]}
            local ddev=${dests[${src2dest[$sid]}]}

            [[ -z ${filesystems[$sdev]} ]] && continue

            mkdir -p "/mnt/$ddev" "/mnt/$sdev"

            local tdev=$sdev

            if [[ $x == lsrcs && ${#lmbrs[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | cut -d ' ' -f1)
                local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${vg_src_name}" | uniq | cut -d ' ' -f2)
                echo "USING snapshot"
                tdev='snap4clone'
                mkdir -p "/mnt/$tdev"
                lvcreate -l100%FREE -s -n snap4clone "${vg_src_name}/$lv_src_name"
                sleep 3
                mount "/dev/${vg_src_name}/$tdev" "/mnt/$tdev"
            else
                mount "$sdev" "/mnt/$sdev"
            fi

            mount "$ddev" "/mnt/$ddev"

            echo "CLONING $sdev"
            if $INTERACTIVE; then
                local size=$( \
                        rsync -aSXxH --stats --dry-run "/mnt/$tdev/" "/mnt/$ddev" \
                    | grep -oP 'Number of files: \d*(,\d*)*' \
                    | cut -d ':' -f2 \
                    | tr -d ' ' \
                    | sed -e 's/,//' \
                )
                rsync -vaSXxH "/mnt/$tdev/" "/mnt/$ddev" | pv -lep -s "$size" >/dev/null
            else
                rsync -aSXxH "/mnt/$tdev/" "/mnt/$ddev"
            fi
            
            sleep 3

            umount "/mnt/$tdev/" 2>/dev/null
            lvremove -f "${vg_src_name}/$tdev" 2> /dev/null

            [[ -f /mnt/$ddev/grub/grub.cfg || -f /mnt/$ddev/grub.cfg || -f /mnt/$ddev/boot/grub/grub.cfg ]] && has_grub=true
            sed -i "s/$vg_src_name/$vg_src_name_clone/" "/mnt/$ddev/cmdline.txt" "/mnt/$ddev/etc/fstab" 2>/dev/null

            _boot_setup "src2dest"
            _boot_setup "psrc2pdest"
            if [[ ${#lmbrs[@]} -gt 0 ]]; then _boot_setup "nsrc2ndest"; fi

            umount "/mnt/$sdev" "/mnt/$ddev" 2>/dev/null
        done
    done

    if $has_grub; then 
        if [[ -n  ${mounts[/boot]} ]]; then
            _grub_setup ${dests[${src2dest[${mounts[/]}]}]} ${dests[${src2dest[${mounts[/boot]}]}]}
        else
            _grub_setup ${dests[${src2dest[${mounts[/]}]}]}
        fi
    fi
}

main() {
    [[ -b $SRC && -b $DEST ]] && clone
    [[ -d "$SRC" && -b $DEST ]] && from_file 
    [[ -b "$SRC" && -d $DEST ]] && to_file
}


### ENTRYPOINT

trap cleanup INT

for c in rsync tar flock bc; do
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

main


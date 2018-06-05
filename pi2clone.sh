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

declare -A MNTJRNL

    # while read -r e; do
    #     read -r dev size<<< "$e"
    #     size=$(( size * 1024 ))
    # done < <( df -x tmpfs -x devtmpfs --output=source,avai )


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


_message() {
	local OPTIND
    local status

	while getopts ':ncy' option; do
		case "$option" in
			y)  status="✔ $2"
          tput cuu1
				;;
			n)  status="✘ $2"
          tput cuu1
				;;
			c)  status="➤ $2"
				;;
		esac
	done
	shift $((OPTIND - 1))

    echo "$status"
}

_setHeader() {
    tput csr 2 $((`tput lines` - 2))
    tput cup 0 0
    tput el
    echo "$1"
    tput el
    echo -n "$2"
    tput cup 3 0
}

_mount() {
	local cmd="mount"

	local OPTIND
    local path
    local src="$1"
    shift

	while getopts ':p:t:' option; do
		case "$option" in
			t)  cmd+=" -t $OPTARG"
				;;
			p)  path="$OPTARG"
				;;
			:)  printf "missing argument for -%s\n" "$OPTARG" >&2
				;;
			\?) printf "illegal option: -%s\n" "$OPTARG" >&2
				;;
		esac
	done
	shift $((OPTIND - 1))

  mkdir -p "/mnt/$path"
  $cmd "$src" "${path:=/mnt/$src}" && MNTJRNL["$src"]="$path" || exit 1
}

_umount() {
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

_expand_disk() {
	local expand_factor=$(echo "$(blockdev --getsz $2) / $1" | bc)
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
	echo "$pdata"
}

_create_m5dsums() {
    _message -c "Creating checksums"
   find "$1" -type f \! -name '*.md5' -print0 | xargs -0 md5sum -b > "$1/$2"
   _validate_m5dsums "$1/$2" || _message -n && return 1
   _message -y
}

_validate_m5dsums() {
   md5sum -c "$1" > /dev/null || return 1
}


_set_dest_uuids() {
    dpuuids=() duuids=() dnames=()
    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $TYPE == disk ]] && continue
        [[ -n $UUID ]] && dests[$UUID]="$NAME"
        dpuuids+=($PARTUUID)
        duuids+=($UUID)
        dnames+=($NAME)
    done < <( lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" )
}

_set_src_uuids() {
    spuuids=() suuids=() snames=()
    while read -r e; do
        read -r kdev name fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $TYPE == disk ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $FSTYPE == LVM2_member ]] && lmbrs[${NAME: -1}]="$UUID"
        [[ $TYPE == part && $FSTYPE != LVM2_member ]] && sfs[${NAME: -1}]="$FSTYPE"
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
        read -r kdev name fstype uuid puuid type parttype mountpoint<<< "$e"
        eval "$kdev" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        [[ $PARTTYPE == 0x5 || $FSTYPE == LVM2_member || $FSTYPE == swap || $TYPE == disk ]] && continue
        lvs -o lv_dmpath,lv_role | grep "$NAME" | grep "snapshot" -q && continue
        [[ $NAME =~ real$|cow$ ]] && continue
        [[ $TYPE == lvm ]] && lsrcs+=($NAME) && islvm=true
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
        read -r kname name fstype uuid puuid type parttype mnt<<< "$e"
        eval "$kname" "$name" "$fstype" "$uuid" "$puuid" "$type" "$parttype" "$mountpoint"
        if [[ ${sfs[${NAME: -1}]} == swap ]]; then
            mkswap "$NAME"
        else
            [[ ${sfs[${NAME: -1}]} ]] && mkfs -t "${sfs[${NAME: -1}]}" "$NAME"
            [[ ${lmbrs[${NAME: -1}]} ]] && pvcreate "$NAME"
        fi
    done < <( lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$DEST" )
    sleep 3
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

_grub_setup() {
    local d="$1"
    local b="$2"

    _mount "$d"
    [[ -n $b ]] && mount "$b" "/mnt/$d/boot"

    for f in sys dev dev/pts proc; do 
        mount --bind "/$f" "/mnt/$d/$f";
    done
    grub-install --boot-directory="/mnt/$d/boot" "$DEST"
    # chroot /mnt/$d update-grub
    chroot "/mnt/$d" apt-get install -y binutils
    _create_rclocal "/mnt/$d"
    _umount -R "$d" 2>/dev/null
}

_mounts() {
    for x in "${srcs[@]}" "${lsrcs[@]}"; do
        local sdev=$x
        local sid=${uuids[$sdev]}

        mkdir -p "/mnt/$sdev"

        _mount "$sdev"

        f[0]='cat /mnt/$sdev/etc/fstab | grep "^UUID" | sed -e "s/UUID=//" | tr -s " " | cut -d " " -f1,2'
        f[1]='cat /mnt/$sdev/etc/fstab | grep "^PARTUUID" | sed -e "s/PARTUUID=//" | tr -s " " | cut -d " " -f1,2'
        f[2]='cat /mnt/$sdev/etc/fstab | grep "^/" | tr -s " " | cut -d " " -f1,2'

        if [[ -f /mnt/$sdev/etc/fstab ]]; then
            for ((i=0;i<${#f[@]};i++)); do
                while read -r e; do 
                    read -r name mnt<<< "$e"
                    if [[ -n ${names[$name]} ]]; then
                        mounts[$mnt]="$name" && mounts[$name]="$mnt"
                    elif [[ -n ${puuids2uuids[$name]} ]]; then
                        mounts[$mnt]="${puuids2uuids[$name]}" && mounts[${puuids2uuids[$name]}]="$mnt"
                    elif [[ -n ${uuids[$name]} ]]; then
                        mounts[$mnt]="${uuids[$name]}" && mounts[${uuids[$name]}]="$mnt"
                    fi
                done < <(eval "${f[$i]}")
            done
        fi

        _umount "$sdev"
    done
}

usage() {
    printf "%s\n" "$USAGE"
    exit 1
}

cleanup() {
    #TODO quiet
    [[ -d $SRC/lvm_ ]] && rm -rf "$SRC/lmv_"
    _umount
    _message -n
    exit 255
}

to_file() {
    pushd "$DEST" >/dev/null || return 1

    _save_disk_layout() {
        sfdisk -d "$SRC" > part_table
        sleep 3 #IMPORTANT !!! So changes by sfdisk can settle. 
                #Otherwise resultes from lsblk might still show old values!
        lsblk -Ppo KNAME,NAME,FSTYPE,UUID,PARTUUID,TYPE,PARTTYPE,MOUNTPOINT "$SRC" | uniq > part_list
    }

    _message -c "Creating backup of disk layout." && \
        _save_disk_layout && \
        _init_srcs && \
        _set_src_uuids && \
        _mounts && \
        _message -y

    vg_src_name=$(pvs --noheadings -o pv_name,vg_name | grep "$SRC" | xargs | cut -d ' ' -f2)

    for x in srcs lsrcs; do
        eval declare -n s="$x"

        for ((i=0;i<${#s[@]};i++)); do
            local sdev=${s[$i]}
            local sid=${uuids[$sdev]}
            local spid=${partuuids[$sdev]}
            local fs=${filesystems[$sdev]}
            local type=${types[$sdev]}
            local mount=${mounts[$sid]}

            local lv_src_name=$(lvs --noheadings -o lv_name,lv_dm_path | grep $sdev | xargs | cut -d ' ' -f1)
            local src_vg_free=$(lvs --noheadings --units m --nosuffix -o vg_name,vg_free | xargs | grep "${vg_src_name}" | uniq | cut -d ' ' -f2)

            [[ -z ${filesystems[$sdev]} ]] && continue

            local tdev=$sdev

            if [[ $x == lsrcs && ${#lmbrs[@]} -gt 0 && "${src_vg_free%%.*}" -ge "500" ]]; then
                #echo "USING snapshot"
                local tdev='snap4clone'
                lvremove -f "${vg_src_name}/$tdev" 2> /dev/null
                lvcreate -l100%FREE -s -n snap4clone "${vg_src_name}/$lv_src_name" &> /dev/null
                sleep 3
                _mount "/dev/${vg_src_name}/$tdev" -p "/mnt/$tdev"
            else
                _mount "$sdev" -t "${filesystems[$sdev]}"
            fi

            cmd="tar --warning=none --directory=/mnt/$tdev --exclude=/proc/* --exclude=/dev/* --exclude=/sys/* --atime-preserve --numeric-owner --xattrs"

            if $INTERACTIVE; then 
                local size=$(du --bytes --exclude=/proc/* --exclude=/sys/* -s /mnt/$tdev | tr -s '\t' ' ' | cut -d ' ' -f 1)
                cmd="$cmd -Scpf - . | pv --rate --timer --eta -pe -s $size > ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_}" 
            else
                cmd="$cmd -Scpf ${i}.${sid:-NOUUID}.${spid:-NOPUUID}.${fs}.${type}.${sdev//\//_}.${mount//\//_} ."  
            fi

            _message -c "Creating backup for $sdev"
            eval "$cmd"
            _message -y

            _umount "/dev/${vg_src_name}/$tdev"
            lvremove -f "${vg_src_name}/$tdev" &> /dev/null
        done

        for ((i=0;i<${#s[@]};i++)); do _umount "${s[$i]}"; done
    done

    $islvm && rm /etc/lvm/backup/* && vgcfgbackup > /dev/null && cp -r /etc/lvm/backup lvm

    popd >/dev/null || return 1
    _create_m5dsums "$DEST" "check.md5" || return 1
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
                read -r kname name fstype type<<< "$e"
                eval "$kname" "$name" "$fstype" "$type"
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
        dd if=/dev/zero of="$DEST" bs=512 count=100000 > /dev/null
        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"
        sfdisk --force "$DEST" < <(_expand_disk "$SRC" "$DEST" "$(sfdisk -d $SRC)") > /dev/null
    }


    pushd "$SRC" >/dev/null || return 1

    _validate_m5dsums "check.md5" || return 1

    _prepare_disk
    sleep 3 

	sfdisk --force "$DEST" < <(_expand_disk "$SRC" "$DEST" part_table)
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
                _mount "$ddev" -t "$fs"

                pushd "/mnt/$ddev" >/dev/null || return 1
                if [[ $fs == vfat ]]; then
                    fakeroot tar -xf "${SRC}/${file}" -C "/mnt/$ddev"
                else
                    tar -xf "${SRC}/${file}" -C "/mnt/$ddev"
                fi
                popd >/dev/null || return 1
            fi
        fi
    done

    popd >/dev/null || return 1
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

        local size s1 s2
        
        while read -r e; do
            read -r pv_name vg_name<<< "$e"
            [[ -z $vg_name ]] && vgcreate "$vg_src_name_clone" "$pv_name"
        done < <( pvs --noheadings -o pv_name,vg_name )

        while read -r e; do
            read -r vg_name vg_size vg_free<<< "$e"
            [[ $vg_name == "$vg_src_name" ]] && s1=$((${vg_size%%.*}-${vg_free%%.*}))
            [[ $vg_name == "$vg_src_name_clone" ]] && s2=${vg_size%%.*}
        done < <( vgs --noheadings --units m --nosuffix -o vg_name,vg_size,vg_free)

        denom_size=$((s1<s2?s2:s1))

        # It might happen that a volume is so small, that it is only 0% in size. In this case we assume the
        # lowest possible value: 1%. This also means we have to decrease the maximum possible size. E.g. two volumes
        # with 0% and 100% would have to be 1% and 99% to make things work.
        local max_size=100

        while read -r e; do
            read -r lv_name vg_name lv_size vg_size vg_free<<< "$e"
            size=$(echo "$lv_size * 100 / $denom_size" | bc)

            if ((s1<s2)); then
                lvcreate --yes -L${lv_size} -n "$lv_name" "$vg_src_name_clone"
            else
                (( size == 0 )) && size=1 && max_size=$((max_size - size))
                (( size == 100 )) && size=$((size - max_size))
                lvcreate --yes -l${size}%VG -n "$lv_name" "$vg_src_name_clone"
            fi
        done < <( lvs --noheadings --units m --nosuffix -o lv_name,vg_name,lv_size,vg_size,vg_free )

        for d in $SRC $DEST; do
            while read -r e; do
                read -r kname name fstype type<<< "$e"
                eval "$kname" "$name" "$fstype" "$type"
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

            vgchange -an "$vg_src_name_clone"
            vgremove -f "$vg_src_name_clone"
        fi

        dd if=/dev/zero of="$DEST" bs=512 count=100000
        #For some reason sfdisk < 2.29 does not create PARTUUIDs when importing a partition table.
        #But when we create a partition and afterward import a prviously dumped partition table, it works!
        # echo -e "n\np\n\n\n\nw\n" | fdisk "$DEST"
        
        sleep 3
        sfdisk --force "$DEST" < <(_expand_disk "$SRC" "$DEST" "$(sfdisk -d $SRC)")
        sleep 3
    }

    _message -c "Cloning disk layout"
    {
        _prepare_disk
        _init_srcs          #First collect what we have in our backup
        _set_src_uuids
        _disk_setup                #Then create the filesystems and PVs

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
    } &>/dev/null
    _message -y

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
                lvremove -f "${vg_src_name}/$tdev" 2> /dev/null
                lvcreate -l100%FREE -s -n snap4clone "${vg_src_name}/$lv_src_name"
                sleep 3
                _mount "/dev/${vg_src_name}/$tdev" -p "/mnt/$tdev"
            else
                _mount "$sdev"
            fi

            _mount "$ddev"

            _message -c "Cloning $sdev to $ddev"
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
            _umount "/dev/${vg_src_name}/$tdev"
            lvremove -f "${vg_src_name}/$tdev" 2> /dev/null

            [[ -f /mnt/$ddev/grub/grub.cfg || -f /mnt/$ddev/grub.cfg || -f /mnt/$ddev/boot/grub/grub.cfg ]] && has_grub=true
            sed -i "s/$vg_src_name/$vg_src_name_clone/" "/mnt/$ddev/cmdline.txt" "/mnt/$ddev/etc/fstab" 2>/dev/null

            _boot_setup "src2dest"
            _boot_setup "psrc2pdest"
            if [[ ${#lmbrs[@]} -gt 0 ]]; then _boot_setup "nsrc2ndest"; fi

            _umount "$sdev"
            _umount "$ddev"
            _message -y
        done
    done

    if $has_grub; then 
        _message -c "Installing Grub"
        {
            if [[ -n  ${mounts[/boot]} ]]; then
                _grub_setup ${dests[${src2dest[${mounts[/]}]}]} ${dests[${src2dest[${mounts[/boot]}]}]}
            else
                _grub_setup ${dests[${src2dest[${mounts[/]}]}]}
            fi
        } &>/dev/null
        _message -y
    fi
}

main() {
    [[ -b $SRC && -b $DEST ]] && clone
    [[ -d "$SRC" && -b $DEST ]] && from_file 
    [[ -b "$SRC" && -d $DEST ]] && to_file
}


### ENTRYPOINT

exec 2> /dev/null
#Force root
if [ "$(id -u)" != "0" ]; then
  exec sudo "$0" "$@" 
fi

trap cleanup INT TERM

for c in rsync tar flock bc blockdev fdisk sfdisk; do
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


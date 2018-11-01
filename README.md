# Backup, Clone, Restore and More (bcrm)

This project is a result of finding a solution for backing up and restoring my private systems in use. To some extend
one could say it is a combination of (relax-and-restore)[http://relax-and-recover.org] and
(borg)[https://www.borgbackup.org]. Though these are robust, solid and field-proven tools, I was missing the option to
do live backups without having to use a special rescue image. And I always wanted to do something like this myself :-)

## bcrm - what can it do for you?

While bcrm can do do a simple (file-based) clone from system A to B, it can actually do a lot more:

-   Clone or Restore a "legacy" system to an UEFI system and vice-versa.
-   Clone or Restore a system and encrypt it with LUKS
-   Clone or Restore LVM-base setups
-   Optionally create and validate checksums
-   Optionally compress backups
-   Do things in parallel (\*where possible)
-   Provide a simple UI (including progress counters)
-   Protect a user in doing too dangerous things

Check the [project page](https://github.com/Jeansen/pi2clone/projects/1) to see what is currently in development and the
backlog.

## Backup options

You can either clone or backup your system, that is:

-   Clone a (live) system (including LVM and GRUB) on another disk.
-   Backup a (live) system to a destination folder and restore from it (including LVM and GRUB).
-   If you use LVM you can also choose to encrypt the clone.

## Intended usage

Ideally, the system to be cloned uses LVM and has some free space left for the creation of a snapshot. Before the
creation of a clone or backup a snapshot will be created. A destination disk does not have to be the same size as the
source disk. It can be bigger or smaller. Just make sure it has enough space for all the data! But don't worry, bcrm
should be smart enough to figure out if the destination is to small, anyway.

When cloning LVM-based systems, the cloned volume group will get the postfix `_<ddmmjjjj>` appended. But you can
overwrite this with the `-n` option.

You will need at least 500MB of free space in your volume group, otherwise no snapshot will be created. In this case you
are on your own, should you clone a live system.

Be aware, that this script is not meant for server environments. I have created it to clone or backup my desktop and 
raspberry Pi systems. I have tested and used it with a standard Raspian installation and standard Debian installations
with and without LVM.

It is also possible to use encryption. That is you could clone a system and have it encrypted or vice versa. The usage
case is actually very limited because it is assumed the encryption is on the lowest level with LVM on top of it. With
this script it is now as easy as doing a normal clone but in addition have the script create the encryption layer. All
you have to do is provide the pass phrase.

## Other use cases

Of course, you can also backup or clone systems without LVM. If you are not cloning a live system, there is not much to
it. But, If you need to clone a live system that is not using LVM, make sure there is a minimum of activity. And even 
then it would be more secure to take the system offline and proceed from a Live CD.

# Usage

If you need help, just call the script without any options or use the `-h` option.  Otherwise there are only a handful
of options that are necessary, mainly: `-s` and `-d` each excepting a block device or a folder.

Let's assume your source disk that you want to clone or backup is `/dev/sda` and `/dev/sdb` is a destination disk.

## Clone

To clone a disk, us the following command:

    ./pi2clone.sh -s /dev/sda -d /dev/sdb

## Backup

To backup a disk, us the following command:

    ./pi2clone.sh -s /dev/sda -d /mnt/folder/to/clone/into [-x] [-c]

If you provide the `-x` option, you can have backup files compressed with xz and a compression ID of 4. 
And if you provide the `-c` option, checksums will be created for each backup file.

## Restore

Restoring is the inverse of a backup. Taken the above example, you would just switch the source and
destination:

    ./pi2clone.sh -s /mnt/folder/to/clone/into -d /dev/sda [-c]

If you provide the `-c` option, checksums (if available) will be validated before restoring from a backup.

## Checksums

If you do a backup, you can use the optional `-c` option. This will create checksums for each backup chunk. When you
restore the system later on, use the `-c` option again for validation.

## Encryption

If you use LVM you can use the `-e` option to encrypt your clone.

## LVM

When cloning or restoring you can use `-n vg-name` to provide a custeom volume group name.

## Safety

The script will take care that you do not fry your system. For instance:

-   Invalid combinations will not be accepted. 
-   Missing tools and programs will be anounced with installation instructions. 
-   Multiple instances will be prevented. 
-   Multiple checks are run to make sure the destination is actually suitable for a clone or backup.
-   And a lot more ...

# Contributing

Fork it, make a Pull Request, create Issues with suggestions, bugs or questions ... You are always welcome to 
contribute!

# Self-Promotion

Like pi2clone? Follow me and/or the repository on GitHub.

# License

GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007

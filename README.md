# pi2clone

This project is a result of finding a solution for backing up and restoring my private systems in use. To some extend 
one could say it is a combination of (relax-and-restore)[http://relax-and-recover.org] and (borg)[https://www.borgbackup.org]. Though these are robust, solid and field-proven
tools I was missing the option to do live backups without having to use a special rescue image. And I always wanted to do something like this myself :-)


## Backup options

You can either clone or backup your system, that is:
- Clone a (live) system (including LVM and GRUB) on another disk.
- Backup a (live) system to a destination folder and restore from it (including LVM and GRUB).
- If you use LVM you can also choose to encrypt the clone and therefore make.


## Intended usage

Ideally, the system to be cloned uses LVM and has some free space left for the creation of a snapshot. Before the
creation of a clone or backup a snapshot will be created. A destination disk does not have to be the same size as the
source disk. It can be bigger or smaller. Just make sure it has enough space for all the data!

In case of cloning LVM the cloned volume group will get the postfix `_<ddmmjjjj>` appended.

You will need at least 500MB of free space in your volume group, otherwise no snapshot will be created. In this case you
are on your own, should you clone a live system.

Be aware, that this script is not meant for server environments. I have created it to clone or backup my desktop and 
raspberry Pi systems. I have tested and used it with a standard Raspian installation and standard Debian installations
with and without LVM.

It is also possible to use encryption. That is you could clone a system and have it encrypted or vice versa. The usage case is actually very limited because it is assumed the encryption is on the lowes level with LVM on top of it. In either case, I often had the use case where I wanted to use my private system but totally encrypted. With this script it is now as easy as doing a normal clone but in addition have the script create the encryption layer. All you have to do is provide the pass phrase.


## Other use cases

Of course, you can also backup or clone systems without LVM. If you are not cloning a live system, there is not much to
it. But, If you need to clone a live system that is not using LVM, make sure there is a minimum of activity. And even 
then it would be more secure to take the system offline and proceed from a Live CD.


# Usage

If you need help, just call the script without any options or use the `-h` option.  Otherwise there are only a handful of options that are necessary, mainly: `-s` and `-d` each excepting a block device or a folder.

Let's assume your source disk that you want to clone or backup is `/dev/sda` and `/dev/sdb` is a destination disk.


## Clone

To clone a disk, us the following command:

    ./pi2clone.sh -s /dev/sda -d /dev/sdb


## Backup

To backup a disk, us the following command:

    ./pi2clone.sh -s /dev/sda -d /mnt/folder/to/clone/into

Backups will be compressed with xz and a compression ID of 3. This seems to be a fair value with respect to the time-compression reatio!

## Restore

Restoring is the inverse of a backup. Taken the above example, you would just switch the source and
destination:

    ./pi2clone.sh -s /mnt/folder/to/clone/into -d /dev/sda 

The script will take care that you do not fry your system. Invalid combinations will not be accepted!

## Checksums

If you provide do a backup, you can use the optional `-c` option. This will create checksums for each backup chunk. When you restore the system later on, use the `-c` option again for validation.

## Encryption

If you use LVM you can use the `-e` option to encrypt your clone.


# Contributing

Fork it, make a Pull Request, create Issues with suggestions, bugs or questions ... You are always welcome to 
contribute!

# Self-Promotion

Like pi2clone? Follow me and/or the repository on GitHub.

# License

GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007

                                                                                                                 




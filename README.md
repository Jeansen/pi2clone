# pi2clone

This project is a result of finding a solution for backing up and restoring my private systems in use. To some extend 
one could say it is a combination of (relax-and-restore)[] and (borg)[]. Though these are robust, solid and field-proven
tools I was missing the option to do live backups without having to use a special rescue image. 


## Backup options

You can either clone or backup your system, that is:
- Clone a (live) system on another disk.
- Backup a (live) system to a destination folder and restore from it.

GRUB is supported, too.


## Intended usage

Ideally, the system to be cloned uses LVM and has some free space left for the creation of a snapshot. Before the
creation of a clone or backup a snapshot will be created. A destination disk does not have to be the same size as the
source disk. It can be bigger or smaller. Just make sure it has enough space for all the data!

In case of cloning LVM the cloned volume group will get the postfix `_clone` appended.

You will need at least 500MB of free space in your volume group, otherwise no snapshot will be created. In this case you
are on your own, should you clone a live system.

Be aware, that this script is not meant for server environments. I have created it to clone or backup my desktop and 
raspberry Pi systems. I have tested and used it with a standard Raspian installation and standard Debian installations
with and without LVM.


## Other use cases

Of course, you can also backup or clone systems without LVM. If you are not cloning a live system, there is not much to
it. But, If you need to clone a live system that is not using LVM, make sure there is a minimum of activity. And even 
then it would be more secure to take the system offline.


# Usage

If you need help, just call the script without any options or use the `-h` option.  Otherwise there are only two options 
that are necessary: `-s` and `-d` each excepting a block device or a folder.

Let's assume your source disk that you want to clone or backup is `/dev/sda` and `/dev/sdb` is a destination disk.


## Clone

To clone a disk, us the following command:

    ./pi2clone.sh -s /dev/sda -d /dev/sdb


## Backup

To backup a disk, us the following command:

    ./pi2clone.sh -s /dev/sda -d /mnt/folder/to/clone/into


## Restore

Restoring a backup is the inverse of a backup. Taken the above example, you would just switch the source and
destination:

    ./pi2clone.sh -s /mnt/folder/to/clone/into -d /dev/sda 

Of course, it is not possible to restore a live system. Anyway, there is no check (yet) that makes sure you do not fry
a running system. So, for the time being, be careful to not accidentally use the wrong destination!


# Contributing

Fork it, make a Pull Request, create Issues with suggestions, bugs or questions ... You are always welcome to 
contribute!

# Self-Promotion

Like pi2clone? Follow me and/or the repository on GitHub.

# License

GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007

                                                                                                                 




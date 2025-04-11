# File Permissions

Weird file permission tricks to be aware of. Look at these when you receive `Permission denied` errors even if you should have access. Normal octal Linux file permissions (chmod/chown) is outside of this document's scope and you are already expected to know these.

## Filesystem Mount Read Only

1. Run `mount` and find the filesystem you are accessing (probably `/`). Does it have `ro` as an option?
2. If so, `mount -o rw,remount /` will remount as read-write. Make sure to change the mountpoint if it is not `/`.

## Immutable Attribute

Immutable means cannot change.

1. `lsattr <FILE>`.
2. If `i` is set (if others are set, Google them), it can be removed with `sudo chattr -i <FILE>`.

## ACLs

Files can have more complex permission sets than just octal perms. Run `getfacl <FILE>` to see.

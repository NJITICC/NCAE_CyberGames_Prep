# Systemd Error's

## Synopsis

`service.service, socket.socket, device.device, mount.mount, automount.automount, swap.swap, target.target, path.path, timer.timer, slice.slice, scope.scope`

## System Unit Search Path
```
/etc/systemd/system.control/*
/run/systemd/system.control/*
/run/systemd/transient/*
/run/systemd/generator.early/*
/etc/systemd/system/*
/etc/systemd/system.attached/*
/run/systemd/system/*
/run/systemd/system.attached/*
/run/systemd/generator/*
…
/usr/local/lib/systemd/system/*
/usr/lib/systemd/system/*
/run/systemd/generator.late/*
```

## User Unit Search Path
```
~/.config/systemd/user.control/*
$XDG_RUNTIME_DIR/systemd/user.control/*
$XDG_RUNTIME_DIR/systemd/transient/*
$XDG_RUNTIME_DIR/systemd/generator.early/*
~/.config/systemd/user/*
$XDG_CONFIG_DIRS/systemd/user/*
/etc/systemd/user/*
$XDG_RUNTIME_DIR/systemd/user/*
/run/systemd/user/*
$XDG_RUNTIME_DIR/systemd/generator/*
$XDG_DATA_HOME/systemd/user/*
$XDG_DATA_DIRS/systemd/user/*
…
/usr/local/lib/systemd/user/*
/usr/lib/systemd/user/*
$XDG_RUNTIME_DIR/systemd/generator.late/*
```

## Cat File for Configuration
Listing Current Units

To see a list of all of the active units that systemd knows about, we can use the list-units command:

`systemctl list-units`

## To see Properties

`systemctl show sshd.service`

or

`systemctl cat sshd.service`

## Editing Unit File

`sudo systemctl edit --full nginx.service`

If the files are deleted they should be reloaded

`sudo systemctl daemon-reload`
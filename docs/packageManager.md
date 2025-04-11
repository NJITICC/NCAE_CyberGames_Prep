# Package Manager Issues

Follow steps for issues with installing packages.

## dnf/rpm

### Package Not Found

1. Verify that the package actually exists. [pkgs.org](https://pkgs.org) is great for this. Make sure you select the right distro and that you're looking at 1st party repos (you can check distro with `cat /etc/os-release`).
2. If package exists, run `dnf install` with the `--refresh` flag and verify the repositories are loaded. If not, check `/etc/yum.repos.d` and see if anything is marked disabled.
3. If repositories are enabled, check `/etc/dnf/dnf.conf` (and other `/etc/dnf` config files) for `exclude` lines which manually filter out the packages. Remove these lines.

### Lockfile Errors

These errors occur when a lockfile exists. Lockfiles are intended to prevent race conditions of multiple processes running at once.

* Check Running Processes

    ```bash
    sudo ps aux 
    ```

    * If you notice something suspicious: `kill -9 <PID>` and try to install the package again. What is something suspicious? If another process is running you package manager! For example, if your using `apt` and another process is stuck using `apt` kill it and see if you can run `apt` again.
    * If `dnf`, `yum`, or `rpm` is open, another user (or something malicious) could be holding the lockfile. Communicate with the team.
* Check if the lockfiles are open by any processes. List of lockfiles are below.

    ```bash
    sudo lsof <LOCKFILE>
    ```

  * If the command has no output, the file is not open. If the file is used by one of the services, the output returns the process ID (PID). In that case, address the service as described in the earlier method.

  * Deleting lock file: If everything else fails, delete the lock files.

  ```bash
  sudo rm /var/cache/dnf/download_lock.pid
  sudo rm /var/cache/dnf/metadata_lock.pid
  sudo rm /var/lib/dnf/rpmdb_lock.pid
  ```

## apt/dpkg

### Package Not Found

1. Verify that the package actually exists. [pkgs.org](https://pkgs.org) is great for this. Make sure you select the right distro and that you're looking at 1st party repos (you can check distro with `cat /etc/os-release`).
2. If package exists, run `apt update` and verify the repositories are loaded. If not, check `/etc/apt/sources.list` and files in `/etc/apt/sources.list.d ` and see if anything is marked disabled.
3. Check `/etc/apt/preferences` and other `/etc/apt` files for held or ignore lines. Remove them if needed.

### Lockfile Errors

* `Could not get lock /var/lib/dpkg/lock`
* `Waiting for cache lock: Could not get lock /var/lib/dpkg/lock-frontend. It is held by the process ?`
* `Could not get lock /var/lib/dpkg/lock-frontend - open (11: Resource temporarily unavailable)`

These errors occur when a lockfile exists. Lockfiles are intended to prevent race conditions of multiple processes running at once.

#### Fixes

* Check Running Processes

    ```bash
    sudo ps aux 
    ```

    * If you notice something suspicious: `kill -9 <PID>` and try to install the package again. What is something suspicious? If another process is running you package manager! For example, if your using `apt` and another process is stuck using `apt` kill it and see if you can run `apt` again.
    * If `dpkg` or `apt` is open, another user (or something malicious) could be holding the lockfile. Communicate with the team.

* Check if the lockfiles are open by any processes. List of lockfiles are below.

    ```bash
    sudo lsof <LOCKFILE>
    ```

  * If the command has no output, the file is not open. If the file is used by one of the services, the output returns the process ID (PID). In that case, address the service as described in the earlier method.

* Deleting lock file: If everything else fails, delete the lock files.

  ```bash
  sudo rm /var/lib/dpkg/lock
  sudo rm /var/lib/apt/lists/lock
  sudo rm /var/lib/dpkg/lock-frontend
  sudo rm /var/cache/apt/archives/lock
  sudo dpkg --configure -a
  ```

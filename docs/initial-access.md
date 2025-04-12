# Initial Access

First steps to run once VMs are accessible. **Not for MikroTik router.**

**When running scripts:** Don't paste them directly into console. Paste them into a text file with vim, `chmod +x` the file, and run the file.

1. Set machine hostname:
    * `hostnamectl set-hostname web`
    * `hostnamectl set-hostname db`
    * `hostnamectl set-hostname dns`
    * `hostnamectl set-hostname shell`
    * `hostnamectl set-hostname backup`

2. Setup IP addresses:
    1. Copy [setup-networking](../setup-networking) into a script.
    2. Edit the IP, GATEWAY, and DNS variables to the appropriate values.
    3. `chmod +x` the file.
    4. Run the script.

3. Check for bad login scripts:
    * `/etc/profile`
    * `/etc/profile.d/*`
    * `/etc/bash.bashrc`
    * `/etc/bashrc`
    * `/etc/skel/.bashrc`
    * `/etc/skel/.profile`
    * `/etc/skel/.bash_profile`
    * **This does not have to be a fine comb search, but at least skim.**

4. Check `/usr/local/bin` and `/usr/local/sbin` for bad executables.
    * These should probably just be empty.

5. Run firewall setup scripts.

    1. Ensure that you run the correct script for the correct machine (the [team1](../firewallSetup/team1) directory has the latest scripts).
    2. Copy script to a file.
    3. `chmod +x` the file.
    4. Run the file.
    5. Paste [iptables-restore.service](../firewallSetup/iptables-restore.service) to `/etc/systemd/system/iptables-restore.service`.
    6. Run `systemctl daemon-reload`
    7. Run `systemctl enable iptables-restore`
    * Future changes to firewall will require running the save commands at the bottom of the firewall scripts.

6. Install command logger.
    1. Copy contents of [youdontevengohere.sh](../youdontevengohere.sh) to `/usr/local/bin/youdontevengohere.sh`
    2. `touch /var/log/hellothere.log`
    3. `chmod 666 /var/log/hellothere.log`
    4. `chattr +a /var/log/hellothere.log`
         * This sets the file to be append only.
    5. Edit `/etc/bash.bashrc` or `/etc/bashrc`, whichever exists. Add `source /usr/local/bin/youdontevengohere.sh` to the end of the file.
    * Now, all ran commands will be logged to `/var/log/hellothere.log` (at least with bash).

7. Install Shrek
    1. Copy contents of [getshrekd.sh](../getshrekd.sh) to `/usr/local/bin/getshrekd.sh`. Edit `GOOD_USERS` to be a list of our first names. This will be sent in Discord.
    2. `chmod +x /usr/local/bin/getshrekd.sh`
    3. Copy contents of [shrek.service](../shrek.service) to `/etc/systemd/system/shrek.service`.
    4. `systemctl daemon-reload`
    5. `systemctl enable --now shrek`
    * Shrek will monitor the logged in users and print obnoxious messages if anyone who shouldn't be logged in is.

8. Check for bad processes and connections.
    1. `ps aux`
    2. `netstat -tunap`
    * Found something? Quickest method to get rid of is quarantine.
      1. Kill the process.
      2. `mkdir /usr/quarantine`
      3. `mv <EXECUTABLE> /usr/quarantine`

9. Run [remote-ssh-setup](../remote-ssh-setup).

    * **Do not run the script from the GitHub.** A script with our public keys/names will be sent in Discord.
    * For the local access user, use the password that is in the team's spreadsheet (there is a passwords tab).
    * **If you are on the Shell/FTP machine:** The script will add a group limitation to who can sign in via SSH. This will need to be updated in `/etc/ssh/sshd_config` while setting up shell login.
    * This script will remove the root account credentials.
10. Notify group that initial access runbook is complete. Proceed with service setup.
11. Remove cronjobs and acron in "initial setup"
    * `systemctl disable --now cron`
    * `systemctl disable --now at.service`
    * `systemctl disable --now atd.service`

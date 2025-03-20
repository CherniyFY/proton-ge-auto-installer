# Proton-GE Auto-Installer

Created first and foremost for my personal use.

Automatically installs latest Proton-GE for Steam (snap installation) on Ubuntu (checked only 24.10).

Assumes all the defaults.

Ensure that the script is executable by running `chmod +x /path/to/proton-ge-auto-installer.sh`

# Scheduled usage

Create a directory

```
mkdir -p ~/.config/systemd/user
```

Create a service file

```
nano ~/.config/systemd/user/proton-ge-auto-installer.service
```

```
[Unit]
Description=Proton-GE Auto-Installer (User Service)

[Service]
Type=oneshot
ExecStart=/path/to/proton-ge-auto-installer.sh

[Install]
WantedBy=default.target
```

Create a timer file

```
nano ~/.config/systemd/user/proton-ge-auto-installer.timer
```

```
[Unit]
Description=Timer to run proton-ge-auto-installer.service every Tuesday at 11:45 AM

[Timer]
OnCalendar=Tue 11:45
Persistent=true

[Install]
WantedBy=timers.target
```

Reload the systemd daemon to recognize your new unit files and then enable and start the timer:

```
systemctl --user daemon-reload
systemctl --user enable proton-ge-auto-installer.timer
systemctl --user start proton-ge-auto-installer.timer
```

Сonfirm that the timer is active and scheduled correctly:

```
systemctl --user list-timers --all | grep proton-ge-auto-installer
```

Test the service manually:

```
systemctl --user start proton-ge-auto-installer.service
```

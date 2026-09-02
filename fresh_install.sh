#!/bin/bash
#
# fresh_install.sh - rebuild HomePI4 from a bare OS install
#
# WHAT THIS IS
#   A from-scratch record of everything that was set up on HomePI4 by hand,
#   turned into a script, so a full SD-card-dead / start-again disaster can
#   be recovered in one sitting instead of by memory. Captured 2026-09-02.
#
# HOW TO USE IT IF SOMETHING GOES WRONG PARTWAY THROUGH
#   Every step below prints a "--- STEP N: ... ---" banner and is written to
#   be safe to re-run (it checks whether it's already done and skips itself
#   if so). If a step fails: read the comment above it for context, then
#   either fix the underlying problem and re-run this whole script from the
#   top (earlier steps will just skip past themselves), or run the
#   individual command(s) from that step by hand.
#
#   Claude Code is installed as STEP 1, deliberately before anything else
#   that could go wrong, specifically so you have it available to help
#   debug the rest. If you hit a failure: open a terminal on the Pi (or SSH
#   in), cd to wherever this script lives, run `claude`, paste the error
#   Claude prints. It already has this script's context via the working
#   directory, plus it can read this file directly.
#
# PREREQUISITES (do these BEFORE running this script)
#   1. Flash a fresh "Raspberry Pi OS" image (NOT plain Debian) with the
#      Raspberry Pi Imager. Use the OS customization options in the Imager
#      to set: hostname = HomePI4, username = pi, enable SSH (key or
#      password), and connect it to your WiFi/network if not using
#      Ethernet. This was Debian 13 (trixie) based at time of writing.
#   2. Boot it, physically reattach the external USB hard drives (the ones
#      with UUIDs matched in STEP 7 below - /mnt/HDD, /mnt/HDD_backup,
#      /mnt/HDD_photos - they hold the last home_backup run's copy of
#      /home/pi, including your SSH keys, which this script restores in
#      STEP 9. Without those drives reattached, STEP 9 has nothing to
#      restore from and you'll need to set up GitHub SSH access by hand.)
#   3. SSH in as `pi` (or use a keyboard/monitor), save this script
#      somewhere like /home/pi/fresh_install.sh - deliberately NOT inside
#      ~/bin, since STEP 10 below moves/replaces that directory - and run:
#        bash /home/pi/fresh_install.sh
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO
#   - It does not touch /mnt/HDD_backup's or /mnt/HDD_photos's *contents* -
#     those drives just need to be physically present and get mounted.
#   - It does not recreate Ollama - it was installed on this Pi at some
#     point (there's a leftover /mnt/HDD/ollama_models folder) but was
#     later removed and isn't part of the current working setup.
#   - It can't do anything that needs interactive browser login for you:
#     Tailscale auth, Claude Code login, and (if the HDD restore in STEP 9
#     doesn't find a working SSH key) a fresh GitHub SSH key. Each of those
#     points is called out clearly below when the script gets there.
#
set -e

echo "=================================================================="
echo " fresh_install.sh - rebuilding the HomePI4 setup"
echo "=================================================================="
echo ""

# ---------------------------------------------------------------------------
# STEP 1: Claude Code CLI - installed first and deliberately, so that if
# anything below this point goes wrong, you already have a Claude Code
# session available on this machine to help fix it. All you'd need to do
# is log in.
# ---------------------------------------------------------------------------
echo "--- STEP 1: Claude Code CLI ---"
if ! command -v claude >/dev/null 2>&1; then
	sudo apt-get update -qq
	sudo apt-get install -y nodejs npm
	sudo npm install -g @anthropic-ai/claude-code
	echo "Claude Code installed."
else
	echo "Claude Code already installed, skipping."
fi
echo ""
echo ">>> If you haven't already, log in now (needs a browser on any device):"
echo ">>>   claude login"
echo ">>> From this point on, if any step below fails, you can run 'claude'"
echo ">>> in this directory, paste the error, and ask it to help - it can"
echo ">>> read this whole script for context."
echo ""
read -r -p "Press Enter to continue once Claude Code is installed (login can wait)... " _dummy

# ---------------------------------------------------------------------------
# STEP 2: cache sudo credentials for this session, so the many sudo calls
# below don't each stop to prompt for a password.
# ---------------------------------------------------------------------------
echo "--- STEP 2: sudo ---"
sudo -v
echo ""

# ---------------------------------------------------------------------------
# STEP 3: apt packages. This is the full `apt-mark showmanual` list from the
# working Pi, captured 2026-09-02, roughly grouped for readability. If you
# flashed the "Raspberry Pi OS with desktop" image variant, a large chunk of
# this (the rpd-*/lightdm/wayvnc lines) will already be present and apt will
# just confirm them; if you flashed "Lite", this installs the full desktop
# + VNC on top, which works but takes a while on first boot's network.
# ---------------------------------------------------------------------------
echo "--- STEP 3: apt packages ---"
echo ">>> NOTE: a few of these package names are tied to a specific version"
echo ">>> (e.g. gcc-14-base, linux-image-rpi-2712) and could have moved on"
echo ">>> by the time you're reading this. If apt says 'Unable to locate"
echo ">>> package X', that's expected drift, not a real problem - drop that"
echo ">>> one name from the PACKAGES array below (or ask Claude Code to find"
echo ">>> its current equivalent) and re-run."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

PACKAGES=(
	# --- Media serving / file sharing (the actual point of this Pi) ---
	minidlna samba samba-common-bin cifs-utils

	# --- Mail alerting (home_backup's failure emails) ---
	msmtp msmtp-mta ca-certificates

	# --- Backup / sync / disk tools ---
	rsync udisks2 ntfs-3g dosfstools parted gparted fdisk e2fsprogs

	# --- Video/media processing (convert_video, films_backup etc.) ---
	mkvtoolnix p7zip-full

	# --- Networking ---
	tailscale network-manager nftables net-tools iproute2 iputils-ping
	ethtool wireless-tools wpasupplicant dhcpcd-base

	# --- RAM/log management ---
	log2ram rpi-swap logrotate

	# --- Dev / build tools (used for compiling things like ffmpeg, and by
	# home_automation's Python deps that need native compilation) ---
	build-essential gcc-14-base gdb make pkg-config llvm nodejs npm
	python3-pip python3-venv python-is-python3 libssl-dev libffi-dev
	libncurses-dev libreadline-dev libgdbm-dev libbz2-dev liblzma-dev
	libxml2-dev libxmlsec1-dev tcl-dev tk-dev zlib1g-dev libusb-dev
	libsqlite3-dev

	# --- Raspberry Pi hardware / GPIO (present even if not all actively
	# used - home_automation's own dependencies are in its requirements.txt,
	# these are the OS-level GPIO libraries it can call into) ---
	gpiod python3-gpiozero python3-libgpiod python3-rpi-lgpio
	python3-smbus2 python3-spidev v4l-utils rpicam-apps-lite

	# --- Misc utilities used by scripts in ~/bin or day-to-day admin ---
	curl wget htop ncdu file strace dmidecode usbutils pciutils
	unzip zip tar cpio sed grep gzip xz-utils vim-tiny nano less
	whiptail bash-completion locales tzdata rsync deluge

	# --- Desktop environment + remote GUI access (if using the "with
	# desktop" image variant these are likely already present) ---
	lightdm wayvnc bluez bluez-firmware

	# --- Bootloader/firmware/Pi-specific (raspi.sources repo, see below) ---
	raspi-config raspi-firmware raspi-utils rpi-eeprom raspberrypi-sys-mods
	raspberrypi-net-mods rpi-cloud-init-mods rpi-loop-utils rpi-usb-gadget

	# --- Base system (near-certainly already present on any Raspberry Pi
	# OS image, listed here only for completeness / faithfulness to the
	# original apt-mark showmanual capture) ---
	sudo cron cron-daemon-common systemd-timesyncd udev avahi-daemon
	avahi-utils console-setup keyboard-configuration
)

sudo apt-get install -y "${PACKAGES[@]}" || echo ">>> Some package(s) failed to install (see above) - likely the version drift warned about above. Fix the PACKAGES array and re-run, or continue on and revisit later."
echo "apt packages installed (or see any failure noted just above)."
echo ""
echo ">>> NOTE: the Plex Media Server apt repo (plexmediaserver.list) was"
echo ">>> present on the original Pi but its signing key had expired and"
echo ">>> 'apt update' was failing against it (SHA1 deprecated 2026-02-01)."
echo ">>> Deliberately NOT re-added here - if you actually use Plex, add"
echo ">>> https://downloads.plex.tv/repo/deb fresh from Plex's own current"
echo ">>> instructions rather than copying the stale repo config."
echo ""

# ---------------------------------------------------------------------------
# STEP 4: Tailscale. Install is scriptable; logging in is not (needs a
# browser). This Pi is reached remotely over Tailscale, not the LAN, so
# don't skip this - your other machines (e.g. the Claude Code session that
# might be helping you) likely only know how to reach this Pi at its
# Tailscale IP.
# ---------------------------------------------------------------------------
echo "--- STEP 4: Tailscale ---"
if ! command -v tailscale >/dev/null 2>&1; then
	curl -fsSL https://tailscale.com/install.sh | sh
else
	echo "Tailscale already installed, skipping."
fi
echo ""
echo ">>> Manual step needed: run 'sudo tailscale up', follow the login link"
echo ">>> it prints, and approve this device in your Tailscale admin console."
echo ">>> Once done, this Pi should be reachable at the same Tailscale IP"
echo ">>> as before (or update anywhere that hardcodes it, e.g. any saved"
echo ">>> Claude Code memory of 'ssh pi@100.102.156.19')."
echo ""
read -r -p "Press Enter once 'sudo tailscale up' is done (or to skip for now)... " _dummy

# ---------------------------------------------------------------------------
# STEP 5: users/groups. minidlna needs to be in group pi (not the other way
# round) so it can read /mnt/HDD/films by group membership rather than by
# accident (world-readable permissions) - see fix_media_permissions and the
# Samba [HDD] share config below for the other half of this.
# ---------------------------------------------------------------------------
echo "--- STEP 5: users/groups ---"
sudo usermod -aG pi minidlna
id minidlna
echo ""

# ---------------------------------------------------------------------------
# STEP 6: passwordless sudo for pi. Needed because several cron jobs run
# scripts with a leading `sudo` (backup_PI, home_backup, the weekly reboot)
# unattended, with no one there to type a password.
# ---------------------------------------------------------------------------
echo "--- STEP 6: passwordless sudo ---"
SUDOERS_FILE=/etc/sudoers.d/010_pi-nopasswd
if [ ! -f "$SUDOERS_FILE" ]; then
	# Write to a temp file and validate with visudo -c BEFORE installing it -
	# a broken sudoers file can lock you out of sudo entirely.
	TMP_SUDOERS=$(mktemp)
	echo "pi ALL=(ALL) NOPASSWD: ALL" > "$TMP_SUDOERS"
	sudo visudo -c -f "$TMP_SUDOERS"
	sudo install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
	rm -f "$TMP_SUDOERS"
	echo "Passwordless sudo configured for pi."
else
	echo "$SUDOERS_FILE already exists, skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 7: fstab entries for the external drives. These UUIDs are tied to the
# specific physical disks - if you're restoring onto the SAME drives (the
# normal case: it's the SD card / OS that died, not the USB drives), these
# lines will match. If you've replaced a drive, find its new UUID with
# `sudo blkid` and update the line below before running this step.
# ---------------------------------------------------------------------------
echo "--- STEP 7: fstab ---"
FSTAB_MARKER="# --- fresh_install.sh: HomePI4 external drives ---"
if ! grep -q "$FSTAB_MARKER" /etc/fstab; then
	sudo cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d)
	{
		echo ""
		echo "$FSTAB_MARKER"
		echo "UUID=dde50f0f-3aac-415b-bdb0-ab44e5cee725 /mnt/HDD ext4 defaults,nofail,x-systemd.device-timeout=30 0 0"
		echo "UUID=108877c8-994d-42b1-9be9-d93166281640 /mnt/HDD_backup ext4 noauto,nofail,x-systemd.device-timeout=30 0 0"
		echo "UUID=6829575a-6d8a-485e-9d28-0c3349037b18 /mnt/HDD_photos ext4 noauto,nofail,x-systemd.device-timeout=30 0 0"
		echo "UUID=e2e2bddc-afad-404b-864e-fa3308db154c /media/pi/Caravan ext4 noauto,nofail,x-systemd.device-timeout=30 0 0"
	} | sudo tee -a /etc/fstab > /dev/null
	sudo mkdir -p /mnt/HDD /mnt/HDD_backup /mnt/HDD_photos /media/pi/Caravan
	echo "fstab updated (backup saved as /etc/fstab.bak.$(date +%Y%m%d))."
else
	echo "fstab already has the HomePI4 drive entries, skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 8: mount /mnt/HDD now. HDD_backup/HDD_photos/Caravan stay unmounted
# (noauto, by design - see the fstab review this script came out of) and
# only get mounted transiently by home_backup/films_backup when they run.
# ---------------------------------------------------------------------------
echo "--- STEP 8: mount /mnt/HDD ---"
if ! mountpoint -q /mnt/HDD; then
	sudo mount /mnt/HDD || true
fi
if mountpoint -q /mnt/HDD; then
	echo "/mnt/HDD mounted."
else
	echo "ERROR: /mnt/HDD did not mount. Is the drive physically attached?"
	echo "Check 'sudo blkid' matches the UUID in /etc/fstab (STEP 7)."
	echo "STEP 9 below needs this drive to restore your SSH key - if it's"
	echo "genuinely gone, you'll need to set up a new GitHub SSH key by hand"
	echo "(ssh-keygen, then add the .pub to https://github.com/settings/keys)"
	echo "before STEP 12 (home_automation, a private repo) will work."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 9: restore ~/.ssh (and ~/.msmtprc if present) from the last
# home_backup run's copy on /mnt/HDD. This is the actual disaster-recovery
# mechanism for secrets on this Pi: home_backup mirrors /home/pi/ (dotfiles
# included) onto /mnt/HDD/files/usr/ every Monday, and that drive survives
# an SD-card/OS reinstall even though the OS itself doesn't. Restoring your
# SSH key this way is what lets STEP 12 clone the private home_automation
# repo over SSH without you generating and re-registering a new key.
# ---------------------------------------------------------------------------
echo "--- STEP 9: restore SSH key / msmtp credentials from HDD backup ---"
if [ -d /mnt/HDD/files/usr/.ssh ]; then
	rsync -a /mnt/HDD/files/usr/.ssh/ /home/pi/.ssh/
	chmod 700 /home/pi/.ssh
	# u=rwX (capital X): read/write for owner, plus execute only on entries
	# that already had some execute bit (i.e. subdirectories) - a plain
	# `chmod 600 *` would strip the execute bit off any subdirectory under
	# .ssh and break traversal into it.
	chmod -R u=rwX,go= /home/pi/.ssh
	echo "Restored ~/.ssh from backup."
	ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -T git@github.com 2>&1 || true
else
	echo "No ~/.ssh found in the HDD backup (/mnt/HDD/files/usr/.ssh)."
	echo "You'll need to create a new SSH key and register it with GitHub:"
	echo "  ssh-keygen -t ed25519 -C \"pi@HomePI4\""
	echo "  cat ~/.ssh/id_ed25519.pub   # add this at https://github.com/settings/keys"
fi

if [ -f /mnt/HDD/files/usr/.msmtprc ]; then
	cp /mnt/HDD/files/usr/.msmtprc /home/pi/.msmtprc
	chmod 600 /home/pi/.msmtprc
	echo "Restored ~/.msmtprc (mail alerting credentials) from backup."
else
	echo "No ~/.msmtprc found in the HDD backup - it's newer than the last"
	echo "backup run at time of writing. You'll need to recreate it: install"
	echo "msmtp (done in STEP 3), generate a fresh Gmail app password at"
	echo "https://myaccount.google.com/apppasswords, and write a file at"
	echo "~/.msmtprc like:"
	echo "  defaults"
	echo "  auth           on"
	echo "  tls            on"
	echo "  tls_trust_file /etc/ssl/certs/ca-certificates.crt"
	echo "  logfile        /home/pi/.msmtp.log"
	echo "  account        gmail"
	echo "  host           smtp.gmail.com"
	echo "  port           587"
	echo "  from           iain.bate@gmail.com"
	echo "  user           iain.bate@gmail.com"
	echo "  password       <the app password, no spaces>"
	echo "  account default : gmail"
	echo "then: chmod 600 ~/.msmtprc"
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 10: clone ~/bin from GitHub. Public repo, plain HTTPS, no auth
# needed. This brings back every script in this repo, including this one,
# home_backup, films_backup, fix_media_permissions, and this crontab.txt.
# ---------------------------------------------------------------------------
echo "--- STEP 10: clone ~/bin ---"
if [ ! -d /home/pi/bin/.git ]; then
	if [ -d /home/pi/bin ]; then
		mv /home/pi/bin /home/pi/bin.pre_fresh_install.$(date +%Y%m%d_%H%M%S)
		echo "Moved existing non-git ~/bin aside before cloning."
	fi
	git clone https://github.com/IainBate/Home-PI4-bin.git /home/pi/bin
	echo "~/bin cloned (git tracks each script's executable bit, so"
	echo "permissions come back correct without needing chmod here)."
else
	echo "~/bin is already a git checkout, pulling latest instead of cloning..."
	git -C /home/pi/bin pull --ff-only
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 11: crontab. Installed from the version-controlled copy in this repo
# (crontab.txt) rather than retyped here, so it can't drift from what's
# actually version-controlled.
# ---------------------------------------------------------------------------
echo "--- STEP 11: crontab ---"
crontab /home/pi/bin/crontab.txt
echo "crontab installed from ~/bin/crontab.txt:"
crontab -l
echo ""

# ---------------------------------------------------------------------------
# STEP 12: home_automation. This is its OWN git repo (private) with its own
# setup script that already does the right thing (venv, pip install,
# systemd services, restoring runtime-only files) - rather than duplicate
# that logic here, this just clones it and hands off to setup_pi.sh. It
# will ask an interactive y/N confirmation before doing anything.
#
# Python version note: home_automation's requirements.txt documents Python
# 3.11+ as the hard minimum (it uses `datetime.UTC` and `asyncio.timeout()`,
# both added in 3.11) and states production has only ever been validated
# against 3.13.5 specifically. That version isn't pinned by any apt package
# here - it just comes from whichever Debian/Raspberry Pi OS release you
# flashed (STEP 0's prerequisites say trixie, which is 3.13.x). The one
# dependency version that's genuinely safety-critical - pymodbus==3.11.4,
# exact-pinned because pymodbus's own API breaks across ITS minor releases -
# is handled correctly regardless of interpreter version, via `pip install
# -r requirements.txt` inside setup_pi.sh. This check just warns if the
# system Python looks like it could be a problem before that runs.
# ---------------------------------------------------------------------------
echo "--- STEP 12: home_automation ---"
PYVER=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
PYMAJOR=$(python3 -c 'import sys; print(sys.version_info[0])')
PYMINOR=$(python3 -c 'import sys; print(sys.version_info[1])')
echo "System python3 version: $PYVER"
if [ "$PYMAJOR" -lt 3 ] || { [ "$PYMAJOR" -eq 3 ] && [ "$PYMINOR" -lt 11 ]; }; then
	echo ">>> WARNING: home_automation requires Python 3.11+ and this system"
	echo ">>> has $PYVER. The venv setup just below will likely still create"
	echo ">>> fine, but the daemon will fail at runtime (datetime.UTC and"
	echo ">>> asyncio.timeout() aren't available before 3.11). You're"
	echo ">>> probably on an older/different OS image than intended - check"
	echo ">>> STEP 0's prerequisites (Raspberry Pi OS, Debian 13/trixie)."
elif [ "$PYVER" != "3.13.5" ]; then
	echo ">>> NOTE: home_automation was only ever validated in production"
	echo ">>> against Python 3.13.5 specifically; this system has $PYVER."
	echo ">>> 3.11+ should be fine - the version-sensitive dependency"
	echo ">>> (pymodbus==3.11.4) is pinned by pip, not by the interpreter -"
	echo ">>> but if anything behaves unexpectedly after setup, this is the"
	echo ">>> first thing worth comparing against."
fi
if [ ! -d /home/pi/home_automation/.git ]; then
	if git clone git@github.com:IainBate/home-automation.git /home/pi/home_automation; then
		echo ""
		echo ">>> Running home_automation's own setup_pi.sh now (it will ask for"
		echo ">>> confirmation and sets up its venv, dependencies, and systemd"
		echo ">>> services). This can take a while on a Pi - see its own note"
		echo ">>> about piwheels for prebuilt ARM wheels if it seems stuck."
		(cd /home/pi/home_automation && bash setup_pi.sh) || echo ">>> setup_pi.sh didn't complete (declined its prompt, or a real failure) - re-run 'bash ~/home_automation/setup_pi.sh' by hand once ready. Continuing with the rest of this script either way, since nothing below depends on home_automation."

		# secrets.yaml is gitignored (real credentials, never committed) - the
		# HDD backup is the only place a copy of it survives. --ignore-existing
		# means this only fills in files setup_pi.sh's own clone didn't provide
		# (secrets.yaml, and any other untracked runtime files), never
		# overwrites anything git just gave you.
		if [ -d /mnt/HDD/files/usr/home_automation ]; then
			rsync -a --ignore-existing /mnt/HDD/files/usr/home_automation/ /home/pi/home_automation/
			echo "Restored any gitignored files (e.g. secrets.yaml) from HDD backup."
		fi
		if [ ! -f /home/pi/home_automation/secrets.yaml ]; then
			echo ">>> secrets.yaml is still missing - copy secrets.yaml.example to"
			echo ">>> secrets.yaml and fill in real credentials by hand."
		fi
	else
		echo ">>> Cloning home_automation over SSH failed - most likely STEP 9"
		echo ">>> didn't find/restore a working GitHub SSH key. Set one up (see"
		echo ">>> STEP 9's instructions above) and re-run:"
		echo ">>>   git clone git@github.com:IainBate/home-automation.git /home/pi/home_automation"
		echo ">>> then 'cd ~/home_automation && bash setup_pi.sh' by hand."
		echo ">>> Continuing with the rest of this script either way, since"
		echo ">>> nothing below depends on home_automation."
	fi
else
	echo "home_automation already cloned, pulling latest instead..."
	(cd /home/pi/home_automation && git pull origin main)
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 13: heating_automation. A second, separate private repo (Fujitsu
# Airstage AC control) - unlike home_automation it has no setup_pi.sh of
# its own and no systemd service or cron entry: it's a manual CLI tool
# (venv/bin/python scripts/ac_control.py ...), not a background daemon, so
# this step just clones it, builds its venv, and restores its gitignored
# config.yaml (device credentials) the same way STEP 12 does for
# home_automation's secrets.
# ---------------------------------------------------------------------------
echo "--- STEP 13: heating_automation ---"
if [ ! -d /home/pi/heating_automation/.git ]; then
	if git clone git@github.com:IainBate/heating-automation.git /home/pi/heating_automation; then
		(
			cd /home/pi/heating_automation
			python3 -m venv venv
			venv/bin/pip install --upgrade pip
			venv/bin/pip install -r requirements.txt
		) || echo ">>> heating_automation venv/pip setup failed - re-run by hand: cd ~/heating_automation && python3 -m venv venv && venv/bin/pip install -r requirements.txt. Continuing with the rest of this script either way."

		if [ -d /mnt/HDD/files/usr/heating_automation ]; then
			rsync -a --ignore-existing /mnt/HDD/files/usr/heating_automation/ /home/pi/heating_automation/
			echo "Restored any gitignored files (e.g. config.yaml) from HDD backup."
		fi
		if [ ! -f /home/pi/heating_automation/config.yaml ]; then
			echo ">>> config.yaml is still missing - copy config.yaml.example to"
			echo ">>> config.yaml and fill in the AC units' real device credentials."
		fi
	else
		echo ">>> Cloning heating_automation over SSH failed - most likely STEP 9"
		echo ">>> didn't find/restore a working GitHub SSH key. Set one up (see"
		echo ">>> STEP 9's instructions above) and re-run:"
		echo ">>>   git clone git@github.com:IainBate/heating-automation.git /home/pi/heating_automation"
		echo ">>> Continuing with the rest of this script either way, since"
		echo ">>> nothing below depends on heating_automation."
	fi
else
	echo "heating_automation already cloned, pulling latest instead..."
	(cd /home/pi/heating_automation && git pull origin main)
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 14: minidlna config. media_dir points at /mnt/HDD/films only -
# deliberate, this Pi doesn't DLNA-serve photos/other media.
# ---------------------------------------------------------------------------
echo "--- STEP 14: minidlna.conf ---"
sudo tee /etc/minidlna.conf > /dev/null <<'EOF'
media_dir=V,/mnt/HDD/films
db_dir=/var/cache/minidlna
log_dir=/var/log/minidlna
port=8200
friendly_name=PI4MediaServer
inotify=yes
album_art_names=Cover.jpg/cover.jpg/AlbumArtSmall.jpg/albumartsmall.jpg
album_art_names=AlbumArt.jpg/albumart.jpg/Album.jpg/album.jpg
album_art_names=Folder.jpg/folder.jpg/Thumb.jpg/thumb.jpg
notify_interval=60
EOF
echo "minidlna.conf written."
echo ""

# ---------------------------------------------------------------------------
# STEP 15: Samba [HDD] share. create/directory masks are deliberately tight
# (0660/2770, setgid so new files/dirs inherit group pi) with force group =
# pi, so access to /mnt/HDD is governed by real group membership (pi, which
# minidlna was added to in STEP 5) rather than relying on files happening
# to stay world-readable. This replaced an original 0777/0777 setup that
# was both a security hole (world-writable over the network) and fragile
# (minidlna's access only worked by accident).
# ---------------------------------------------------------------------------
echo "--- STEP 15: Samba [HDD] share ---"
SMB_MARKER="\[HDD\]"
if ! sudo grep -q "$SMB_MARKER" /etc/samba/smb.conf; then
	{
		echo ""
		echo "[HDD]"
		echo "path = /mnt/HDD"
		echo "writeable = yes"
		echo "create mask = 0660"
		echo "directory mask = 2770"
		echo "force group = pi"
		echo "public = no"
	} | sudo tee -a /etc/samba/smb.conf > /dev/null
	sudo testparm -s > /dev/null
	echo "[HDD] share added to smb.conf."
else
	echo "[HDD] share already present in smb.conf, skipping (if it's still"
	echo "using the old 0777 masks, patch it by hand - see this script's"
	echo "git history / the Claude Code session that hardened it originally)."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 16: normalize ownership/permissions on the media library to match
# the group-based access model above. Safe to re-run any time.
# ---------------------------------------------------------------------------
echo "--- STEP 16: fix_media_permissions ---"
if mountpoint -q /mnt/HDD && [ -d /mnt/HDD/films ]; then
	/home/pi/bin/fix_media_permissions || echo ">>> fix_media_permissions reported failure(s) (see above) - re-run it by hand once fixed. Continuing with the rest of this script either way."
else
	echo "Skipping - /mnt/HDD/films not present yet (drive not mounted or"
	echo "no films transferred onto it yet). Run /home/pi/bin/fix_media_permissions"
	echo "by hand once it is."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 17: log2ram tuning. The package default is SIZE=128M / no
# LOG_DISK_SIZE tweak; this Pi runs SIZE=512M so logging bursts (e.g. a
# noisy rsync run) don't fill the RAM-backed /var/log.
# ---------------------------------------------------------------------------
echo "--- STEP 17: log2ram ---"
sudo sed -i 's/^SIZE=.*/SIZE=512M/' /etc/log2ram.conf
sudo sed -i 's/^LOG_DISK_SIZE=.*/LOG_DISK_SIZE=256M/' /etc/log2ram.conf
echo "log2ram.conf tuned (SIZE=512M)."
echo ""

# ---------------------------------------------------------------------------
# STEP 18: restart everything that got reconfigured above, so it's all live
# without needing a reboot.
# ---------------------------------------------------------------------------
echo "--- STEP 18: restart services ---"
sudo systemctl restart minidlna
sudo systemctl restart smbd
sudo systemctl restart log2ram || true
echo "Services restarted."
echo ""

# ---------------------------------------------------------------------------
# STEP 19: summary / what's left to do by hand
# ---------------------------------------------------------------------------
echo "=================================================================="
echo " fresh_install.sh: done. Manual follow-ups, if not already done:"
echo "=================================================================="
echo "  [ ] claude login                    (Claude Code, STEP 1)"
echo "  [ ] sudo tailscale up                (Tailscale, STEP 4)"
echo "  [ ] verify ~/.msmtprc has a real app password, not a placeholder"
echo "      (STEP 9 - only restores it if the HDD backup already had it)"
echo "  [ ] verify ~/home_automation/secrets.yaml has real credentials"
echo "      (STEP 12 - same caveat as above)"
echo "  [ ] verify ~/heating_automation/config.yaml has real device credentials"
echo "      (STEP 13 - same caveat as above; it's a manual CLI, nothing to"
echo "      systemctl-check for it - try 'venv/bin/python scripts/ac_control.py'"
echo "      once credentials are in place)"
echo "  [ ] healthchecks.io: no action needed, the ping URL is already"
echo "      baked into home_backup (came back with the ~/bin git clone)"
echo "  [ ] reattach/verify /mnt/HDD_backup, /mnt/HDD_photos, and the"
echo "      portable Caravan/Lucy drive for films_backup - none of those"
echo "      needed to be mounted for this script, only /mnt/HDD"
echo "  [ ] spot-check: systemctl status minidlna smbd home_automation"
echo "      home_automation_dashboard"
echo "=================================================================="

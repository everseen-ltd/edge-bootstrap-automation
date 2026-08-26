#!/usr/bin/env bash
#
# bootstrap-automation.sh
#
# Prepares an Ubuntu host for automation: creates the `evs-automation` account
# (key-only SSH + passwordless sudo) and installs Docker from snap.
#
# Intended use: a locally-running Ansible container SSHes into this host as
# `evs-automation` (key-only, no password) and configures it with passwordless
# sudo.
#
# Safe to run repeatedly. Every run rotates the SSH keypair (a fresh key is
# generated and the old one is revoked); all other steps are idempotent.
#
# Run with --cleanup to reverse it: remove the user, its home directory (SSH
# keys and logs), and the sudoers drop-in. Docker is left installed.

set -euo pipefail

readonly AUTOMATION_USER="evs-automation"
readonly AUTOMATION_HOME="/home/${AUTOMATION_USER}"
readonly SSH_DIR="${AUTOMATION_HOME}/.ssh"
readonly AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
readonly PRIVATE_KEY="${SSH_DIR}/id_ed25519"
readonly PUBLIC_KEY="${PRIVATE_KEY}.pub"
readonly SUDOERS_FILE="/etc/sudoers.d/${AUTOMATION_USER}"
# The Ansible container runs with --network host and targets 127.0.0.1, so the
# key only ever needs to work from loopback. sshd rejects it from anywhere else.
readonly SSH_ALLOWED_FROM="127.0.0.1,::1"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

usage() {
  cat <<EOF
Usage: $0 [--cleanup] [-h|--help]

  (no option)   Provision ${AUTOMATION_USER}: user, SSH key, sudo, and Docker.
  --cleanup     Remove ${AUTOMATION_USER}, its home directory (SSH keys and
                logs), and the sudoers drop-in. Docker is left installed.
  -h, --help    Show this help.
EOF
}

cleanup() {
  log "Removing ${AUTOMATION_USER} and all its credentials"

  if id -u "${AUTOMATION_USER}" >/dev/null 2>&1; then
    # deluser refuses while the account still has running processes.
    pkill -KILL -u "${AUTOMATION_USER}" 2>/dev/null || true
    if command -v deluser >/dev/null 2>&1; then
      deluser --remove-home "${AUTOMATION_USER}"
    else
      userdel -r "${AUTOMATION_USER}"
    fi
    log "Removed user, home directory, SSH keys, and logs"
  else
    log "User ${AUTOMATION_USER} does not exist; nothing to remove"
  fi

  # The sudoers drop-in lives outside the home dir, so it must go separately.
  rm -f "${SUDOERS_FILE}"
  log "Removed ${SUDOERS_FILE}"

  log "Cleanup complete. Docker snap and the docker group were left untouched."
}

mode="provision"
case "${1:-}" in
  "")            mode="provision" ;;
  --cleanup)     mode="cleanup" ;;
  -h|--help)     usage; exit 0 ;;
  *)             echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
esac

if [[ ${EUID} -ne 0 ]]; then
  echo "This script must be run as root (try: sudo $0)" >&2
  exit 1
fi

if [[ "${mode}" == "cleanup" ]]; then
  cleanup
  exit 0
fi

# --- 1. create the automation user (key-only, no password login) -----------
if id -u "${AUTOMATION_USER}" >/dev/null 2>&1; then
  log "User ${AUTOMATION_USER} already exists; leaving it as-is"
else
  log "Creating user ${AUTOMATION_USER}"
  # --disabled-password leaves the account usable via SSH key + sudo, but with
  # no password that could ever be used to log in.
  adduser --disabled-password --gecos "" "${AUTOMATION_USER}"
fi

# --- 2. passwordless sudo --------------------------------------------------
# Ansible runs privileged host tasks (become: true); the account has no
# password, so sudo must never prompt for one.
log "Configuring passwordless sudo"
sudoers_tmp="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${AUTOMATION_USER}" > "${sudoers_tmp}"
# Validate before installing so a typo can never break sudo for the whole host.
visudo -cf "${sudoers_tmp}"
install -m 0440 -o root -g root "${sudoers_tmp}" "${SUDOERS_FILE}"
rm -f "${sudoers_tmp}"

# --- 3. SSH key-based access -----------------------------------------------
# The private key is kept on the host so it can be bind-mounted into the local
# Ansible container, which uses it to SSH back into this host as evs-automation.
# A fresh keypair is generated on EVERY run (key rotation); the old key is
# discarded and authorized_keys is reset so only the new key can ever log in.
install -d -m 0700 -o "${AUTOMATION_USER}" -g "${AUTOMATION_USER}" "${SSH_DIR}"

log "Generating a fresh ed25519 keypair for ${AUTOMATION_USER}"
# Remove the old key first so ssh-keygen never blocks on an overwrite prompt.
rm -f "${PRIVATE_KEY}" "${PUBLIC_KEY}"
ssh-keygen -t ed25519 -a 64 -N "" -C "${AUTOMATION_USER}" \
  -f "${PRIVATE_KEY}" >/dev/null

# Authorize ONLY the new public key, restricted to loopback so a leaked key is
# useless from any other host. Overwrite so any previous key stops working.
printf 'from="%s" %s\n' "${SSH_ALLOWED_FROM}" "$(cat "${PUBLIC_KEY}")" \
  > "${AUTHORIZED_KEYS}"

# Lock down ownership and permissions on everything under .ssh.
chmod 0600 "${PRIVATE_KEY}" "${AUTHORIZED_KEYS}"
chmod 0644 "${PUBLIC_KEY}"
chown -R "${AUTOMATION_USER}:${AUTOMATION_USER}" "${SSH_DIR}"

log "Private key to mount into the container: ${PRIVATE_KEY}"

# --- 4. logs directory -----------------------------------------------------
log "Ensuring logs directory"
install -d -m 0755 -o "${AUTOMATION_USER}" -g "${AUTOMATION_USER}" \
  "${AUTOMATION_HOME}/logs"

# --- 5. install openssh-server ---------------------------------------------
if dpkg -s openssh-server >/dev/null 2>&1; then
  log "openssh-server already installed"
else
  log "Installing openssh-server"
  apt-get update
  apt-get install -y openssh-server
fi

# --- 6. install Docker from snap -------------------------------------------
if ! command -v snap >/dev/null 2>&1; then
  log "Installing snapd"
  apt-get update
  apt-get install -y snapd
fi

docker_changed=false
if snap list docker >/dev/null 2>&1; then
  log "Docker snap already installed"
else
  log "Installing Docker from snap"
  snap install docker
  docker_changed=true
fi

# --- 7. docker group + membership (AFTER snap install) ---------------------
# Order matters: the docker snap owns /var/run/docker.sock and only assigns it
# to the `docker` group when that group already exists when the daemon starts.
# So create the group and add the user only after the snap is present.
if getent group docker >/dev/null; then
  log "Group docker already exists"
else
  log "Creating docker group"
  groupadd --system docker
fi

if id -nG "${AUTOMATION_USER}" | tr ' ' '\n' | grep -qx docker; then
  log "${AUTOMATION_USER} already in docker group"
else
  log "Adding ${AUTOMATION_USER} to docker group"
  usermod -aG docker "${AUTOMATION_USER}"
  docker_changed=true
fi

# --- 8. restart the snap so it applies the docker group to the socket ------
if [[ "${docker_changed}" == true ]]; then
  log "Restarting Docker snap to apply group membership"
  snap disable docker
  snap enable docker
fi

log "Done. ${AUTOMATION_USER} is ready: key-based SSH, passwordless sudo, Docker via snap."
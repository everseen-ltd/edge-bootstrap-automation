#!/usr/bin/env bash
#
# bootstrap-automation.sh
#
# Prepares a host for automation: creates the `evs-automation` account
# (key-only SSH + passwordless sudo) and installs a container runtime.
#
# Supported distributions (auto-detected from /etc/os-release):
#   - Ubuntu / Debian          -> Docker from snap
#   - RHEL 8/9 (+ Rocky/Alma)  -> Podman (dnf)
#   - openSUSE Leap 16         -> Podman (zypper)
#
# Safe to run repeatedly. Every run rotates the SSH keypair (a fresh key is
# generated and the old one is revoked); all other steps are idempotent.
#
# Run with --cleanup to reverse it: remove the user, its home directory (SSH
# keys and logs), and the sudoers drop-in. The container runtime is left
# installed.

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

OS_FAMILY=""

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

usage() {
  cat <<EOF
Usage: $0 [--cleanup] [-h|--help]

  (no option)   Provision ${AUTOMATION_USER}: user, SSH key, sudo, and a
                container runtime (Docker on Ubuntu, Podman on RHEL/openSUSE).
  --cleanup     Remove ${AUTOMATION_USER}, its home directory (SSH keys and
                logs), and the sudoers drop-in. The container runtime is left
                installed.
  -h, --help    Show this help.
EOF
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    echo "Cannot read /etc/os-release; unsupported system" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release

  # ID_LIKE is the fallback for distros not matched by ID (e.g. RHEL rebuilds).
  case "${ID:-}" in
    ubuntu|debian)                             OS_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|fedora)        OS_FAMILY="rhel" ;;
    opensuse-leap|opensuse-tumbleweed|sles)    OS_FAMILY="suse" ;;
    *)
      case " ${ID_LIKE:-} " in
        *debian*)                  OS_FAMILY="debian" ;;
        *rhel*|*fedora*|*centos*)  OS_FAMILY="rhel" ;;
        *suse*)                    OS_FAMILY="suse" ;;
        *)
          echo "Unsupported distribution: ${ID:-unknown}" >&2
          exit 1
          ;;
      esac
      ;;
  esac
  log "Detected OS family: ${OS_FAMILY} (${PRETTY_NAME:-${ID:-unknown}})"
}

create_user() {
  if id -u "${AUTOMATION_USER}" >/dev/null 2>&1; then
    log "User ${AUTOMATION_USER} already exists; leaving it as-is"
    return
  fi

  log "Creating user ${AUTOMATION_USER}"
  case "${OS_FAMILY}" in
    debian)
      adduser --disabled-password --gecos "" "${AUTOMATION_USER}"
      ;;
    rhel|suse)
      useradd --create-home --shell /bin/bash "${AUTOMATION_USER}"
      # Key-only account; sudo is granted by name in configure_sudo, so the
      # password stays locked and no wheel membership is added.
      passwd -l "${AUTOMATION_USER}"
      ;;
  esac
}

configure_sudo() {
  log "Configuring passwordless sudo"
  local sudoers_tmp
  sudoers_tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${AUTOMATION_USER}" > "${sudoers_tmp}"
  # Validate before installing so a typo can never break sudo for the whole host.
  visudo -cf "${sudoers_tmp}"
  install -m 0440 -o root -g root "${sudoers_tmp}" "${SUDOERS_FILE}"
  rm -f "${sudoers_tmp}"
}

# The private key is bind-mounted into the Ansible container, which SSHes back in
# as evs-automation. A fresh keypair is generated on every run and
# authorized_keys is overwritten, revoking the previous key (rotation).
configure_ssh_keys() {
  install -d -m 0700 -o "${AUTOMATION_USER}" -g "${AUTOMATION_USER}" "${SSH_DIR}"

  log "Generating a fresh ed25519 keypair for ${AUTOMATION_USER}"
  # Remove the old key so ssh-keygen doesn't prompt to overwrite.
  rm -f "${PRIVATE_KEY}" "${PUBLIC_KEY}"
  ssh-keygen -t ed25519 -N "" -C "${AUTOMATION_USER}" \
    -f "${PRIVATE_KEY}" >/dev/null

  printf 'from="%s" %s\n' "${SSH_ALLOWED_FROM}" "$(cat "${PUBLIC_KEY}")" \
    > "${AUTHORIZED_KEYS}"

  chmod 0600 "${PRIVATE_KEY}" "${AUTHORIZED_KEYS}"
  chmod 0644 "${PUBLIC_KEY}"
  chown -R "${AUTOMATION_USER}:${AUTOMATION_USER}" "${SSH_DIR}"

  log "Private key to mount into the container: ${PRIVATE_KEY}"
}

ensure_logs_dir() {
  log "Ensuring logs directory"
  install -d -m 0755 -o "${AUTOMATION_USER}" -g "${AUTOMATION_USER}" \
    "${AUTOMATION_HOME}/logs"
}

# Debian enables sshd on install; RHEL and openSUSE need it enabled explicitly.
install_ssh_server() {
  case "${OS_FAMILY}" in
    debian)
      if dpkg -s openssh-server >/dev/null 2>&1; then
        log "openssh-server already installed"
      else
        log "Installing openssh-server"
        apt-get update
        apt-get install -y openssh-server
      fi
      ;;
    rhel)
      if rpm -q openssh-server >/dev/null 2>&1; then
        log "openssh-server already installed"
      else
        log "Installing openssh-server"
        dnf install -y openssh-server
      fi
      log "Enabling sshd"
      systemctl enable --now sshd
      ;;
    suse)
      if rpm -q openssh-server >/dev/null 2>&1; then
        log "openssh-server already installed"
      else
        log "Installing openssh-server"
        zypper --non-interactive refresh
        zypper --non-interactive install openssh-server
      fi
      log "Enabling sshd"
      systemctl enable --now sshd
      ;;
  esac
}

install_docker_snap() {
  if ! command -v snap >/dev/null 2>&1; then
    log "Installing snapd"
    apt-get update
    apt-get install -y snapd
  fi

  local docker_changed=false
  if snap list docker >/dev/null 2>&1; then
    log "Docker snap already installed"
  else
    log "Installing Docker from snap"
    snap install docker
    docker_changed=true
  fi

  # The snap assigns the socket to the `docker` group only if that group exists
  # when the daemon starts, so create it and add the user after the snap is in.
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

  # Restart so the daemon applies the group ownership to the socket.
  if [[ "${docker_changed}" == true ]]; then
    log "Restarting Docker snap to apply group membership"
    snap disable docker
    snap enable docker
  fi
}

install_podman() {
  if command -v podman >/dev/null 2>&1; then
    log "Podman already installed"
    return
  fi
  log "Installing Podman"
  case "${OS_FAMILY}" in
    rhel) dnf install -y podman ;;
    suse)
      zypper --non-interactive refresh
      zypper --non-interactive install podman
      ;;
  esac
}

install_container_runtime() {
  case "${OS_FAMILY}" in
    debian)    install_docker_snap ;;
    rhel|suse) install_podman ;;
  esac
}

cleanup() {
  log "Removing ${AUTOMATION_USER} and all its credentials"

  # Remove the sudoers drop-in first: if the account deletion below fails partway
  # (userdel can exit nonzero, e.g. 12), a later same-name user must never
  # inherit its NOPASSWD sudo.
  rm -f "${SUDOERS_FILE}"
  log "Removed ${SUDOERS_FILE}"

  if id -u "${AUTOMATION_USER}" >/dev/null 2>&1; then
    # The kill is async and userdel can exit nonzero, so guard the deletion
    # against `set -e`.
    pkill -KILL -u "${AUTOMATION_USER}" 2>/dev/null || true
    if command -v deluser >/dev/null 2>&1; then
      deluser --remove-home "${AUTOMATION_USER}" || true
    else
      userdel -r "${AUTOMATION_USER}" || userdel "${AUTOMATION_USER}" || true
    fi
    log "Removed user, home directory, SSH keys, and logs"
  else
    log "User ${AUTOMATION_USER} does not exist; nothing to remove"
  fi

  log "Cleanup complete. The container runtime was left installed."
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

detect_os
create_user
configure_sudo
configure_ssh_keys
ensure_logs_dir
install_ssh_server
install_container_runtime

case "${OS_FAMILY}" in
  debian) runtime="Docker" ;;
  *)      runtime="Podman" ;;
esac
log "Done — host is ready:
      ✓  ${AUTOMATION_USER} installed
      ✓  ${runtime} installed"
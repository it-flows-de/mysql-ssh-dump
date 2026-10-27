#!/usr/bin/env bash
#===============================================================================
# Name:         mysql-ssh-dump.sh
# Author:       flo.alt@it-flows.de
# Date:         2026-10-26
# Purpose:      Create compressed dumps of one or more MySQL/MariaDB databases
#               that are only reachable from a remote host (e.g. shared hosting).
#               mysqldump runs on the remote host via SSH, the output is streamed
#               back and stored locally. Database passwords are passed through
#               the SSH connection and are never stored on the remote host.
# Usage:        mysql-ssh-dump.sh [--dry-run] [--help]
#                 --dry-run  Check config, secrets, SSH login and database
#                            connections. Writes no dump and no marker file.
#                 --help     Show this help.
# Requires:     bash, ssh, gzip, zcat, flock, stat; sshpass for password login.
#               Runs as root (the secrets are read from a root-only directory).
# Exit codes:   0 ok | 1 error | 2 usage | 3 config/secrets | 4 already running
#               5 missing dependency | 6 SSH or database check failed (dry-run)
#               7 one or more dumps failed | 8 filesystem error
#===============================================================================

set -euo pipefail

VERSION="1.0.0"
REQUIRED_CONFIG_VERSION="1"

# The only paths derived in the script: its own directory and, by convention,
# the config next to it. Every other path comes from the config.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.config"

# --- Exit codes ---
EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_CONFIG=3
EXIT_LOCKED=4
EXIT_DEP=5
EXIT_CHECK=6
EXIT_DUMP=7
EXIT_FS=8

DRY_RUN=0

# ---------------------------------------------------------------
# Functions
# ---------------------------------------------------------------

# Write one log line with timestamp and level.
# Before the config is loaded there is no LOG_FILE yet, so fall back to stderr.
# When started from a terminal the line is also printed to stdout.
log() {
    local line
    line="$(printf '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2")"
    # If the log file cannot be written (e.g. missing directory), fall back to
    # stderr so that the real error and exit code are not lost.
    if [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "${line}" 2> /dev/null >> "${LOG_FILE}"; then
        if [[ -t 1 ]]; then
            printf '%s\n' "${line}"
        fi
    else
        printf '%s\n' "${line}" >&2
    fi
}

# Log an error and terminate with the given exit code
die() {
    log "ERROR" "$2"
    exit "$1"
}

# Always log the end of the run together with the exit code
on_exit() {
    local rc=$?
    log "INFO" "END (exit ${rc})"
}

# Print the usage text
usage() {
    cat <<EOF
${SCRIPT_NAME} ${VERSION}

Usage: ${SCRIPT_NAME}.sh [--dry-run] [--help]

  --dry-run  Check config, secrets, SSH login and database connections.
             Writes no dump and no marker file.
  --help     Show this help.

Config: ${CONFIG_FILE}
EOF
}

# Abort unless file exists and has the expected octal permissions.
# With a third argument "root" the file must also be owned by root:root
# (used for the secrets file; the config only gets the permission check).
check_file() {
    local file="$1" expected="$2" need_owner="${3:-}" actual owner
    [[ -f "${file}" ]] || die "${EXIT_CONFIG}" "Missing file: ${file}"
    if [[ "${need_owner}" == "root" ]]; then
        owner="$(stat -c '%U:%G' "${file}")"
        [[ "${owner}" == "root:root" ]] \
            || die "${EXIT_CONFIG}" "Wrong owner on ${file}: ${owner} (expected root:root)"
    fi
    actual="$(stat -c '%a' "${file}")"
    [[ "${actual}" == "${expected}" ]] \
        || die "${EXIT_CONFIG}" "Wrong permissions on ${file}: ${actual} (expected ${expected})"
}

# Run a command on the remote host via SSH. Argument: the remote command.
# Stdin is passed through to the remote command.
run_ssh() {
    local -a opts=(
        -T -p "${SSH_PORT}"
        -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}"
        -o GlobalKnownHostsFile=/dev/null
        -o StrictHostKeyChecking=yes
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
        -o ServerAliveInterval="${SSH_ALIVE_INTERVAL}"
        -o ServerAliveCountMax=3
        -o LogLevel=ERROR
    )
    if [[ -n "${SSH_KEY:-}" ]]; then
        ssh "${opts[@]}" -i "${SSH_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes \
            "${SSH_USER}@${SSH_HOST}" "$1"
    else
        SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${opts[@]}" \
            -o PubkeyAuthentication=no \
            "${SSH_USER}@${SSH_HOST}" "$1"
    fi
}

# Print a mysqldump option file for one database to stdout.
# Arguments: host user password. Backslash and double quote are escaped.
build_cnf() {
    local pw="$3"
    pw="${pw//\\/\\\\}"
    pw="${pw//\"/\\\"}"
    printf '[client]\nhost=%s\nuser=%s\npassword="%s"\n' "$1" "$2" "${pw}"
}

# Dry-run check for one database: connect and dump the structure to /dev/null.
check_one() {
    local label="$1" dbhost="$2" dbname="$3" dbuser="$4" remote_cmd
    # shellcheck disable=SC2086
    remote_cmd="mysqldump --defaults-extra-file=/dev/stdin ${MYSQLDUMP_OPTIONS} --no-data ${dbname} > /dev/null"
    if build_cnf "${dbhost}" "${dbuser}" "${DB_PASSWORDS[${label}]}" \
        | run_ssh "${remote_cmd}" 2>> "${LOG_FILE}"; then
        log "INFO" "[dry-run] ${label}: database connection OK"
        return 0
    fi
    log "ERROR" "[dry-run] ${label}: database connection failed"
    return 1
}

# Keep only the newest RETENTION_COUNT dumps of one label.
# Runs only after a successful dump, so failed runs never delete old dumps.
rotate_dumps() {
    local label="$1" old
    local -a files
    shopt -s nullglob
    files=("${DUMP_DIR}/${label}"_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].sql.gz)
    shopt -u nullglob
    if [[ "${#files[@]}" -le "${RETENTION_COUNT}" ]]; then
        return 0
    fi
    # File names contain the timestamp, so sorting by name sorts by age
    while IFS= read -r old; do
        if rm -f -- "${old}"; then
            log "INFO" "${label}: removed old dump $(basename "${old}")"
        fi
    done < <(printf '%s\n' "${files[@]}" | sort -r | tail -n +"$((RETENTION_COUNT + 1))")
}

# Dump one database, verify the result, rotate old dumps.
# The dump only gets its final name if it is complete and valid.
# Returns 1 on any failure (always called in an "||" list by the caller).
dump_one() {
    local label="$1" dbhost="$2" dbname="$3" dbuser="$4"
    local ts tmp final remote_cmd last old_umask
    local -a rcs=(0 0 0)
    ts="$(date +%F_%H%M%S)"
    tmp="${DUMP_DIR}/.${label}_${ts}.sql.gz.part"
    final="${DUMP_DIR}/${label}_${ts}.sql.gz"
    # shellcheck disable=SC2086
    remote_cmd="mysqldump --defaults-extra-file=/dev/stdin ${MYSQLDUMP_OPTIONS} ${dbname}"

    log "INFO" "${label}: starting dump"
    # Dumps may contain user data: readable for root only
    old_umask="$(umask)"
    umask 077
    # PIPESTATUS: 0 = option file, 1 = ssh/mysqldump, 2 = gzip
    build_cnf "${dbhost}" "${dbuser}" "${DB_PASSWORDS[${label}]}" \
        | run_ssh "${remote_cmd}" 2>> "${LOG_FILE}" \
        | gzip > "${tmp}" || rcs=("${PIPESTATUS[@]}")
    umask "${old_umask}"

    if [[ "${rcs[1]}" -ne 0 || "${rcs[2]}" -ne 0 ]]; then
        log "ERROR" "${label}: dump failed (ssh rc=${rcs[1]}, gzip rc=${rcs[2]})"
        rm -f -- "${tmp}"
        return 1
    fi

    # Verify: valid gzip and mysqldump's completion marker as last line
    if ! gzip -t "${tmp}" 2>> "${LOG_FILE}"; then
        log "ERROR" "${label}: dump is not a valid gzip file"
        rm -f -- "${tmp}"
        return 1
    fi
    last="$(zcat "${tmp}" | tail -n 1)" || last=""
    if [[ "${last}" != "-- Dump completed"* ]]; then
        log "ERROR" "${label}: dump incomplete (completion line missing)"
        rm -f -- "${tmp}"
        return 1
    fi

    if ! mv -- "${tmp}" "${final}"; then
        log "ERROR" "${label}: cannot move dump to ${final}"
        rm -f -- "${tmp}"
        return 1
    fi
    log "INFO" "${label}: OK -> $(basename "${final}") ($(stat -c %s "${final}") bytes)"

    rotate_dumps "${label}"
    return 0
}

# ---------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage; exit "${EXIT_OK}" ;;
        *) usage >&2; exit "${EXIT_USAGE}" ;;
    esac
done

# ---------------------------------------------------------------
# Startup
# ---------------------------------------------------------------

trap on_exit EXIT

[[ "${EUID}" -eq 0 ]] || die "${EXIT_ERROR}" "Must be run as root"

# Load config (SCRIPT_DIR and SCRIPT_NAME are available inside it)
check_file "${CONFIG_FILE}" 660
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Config must match the version this script expects
[[ "${CONFIG_VERSION:-}" == "${REQUIRED_CONFIG_VERSION}" ]] \
    || die "${EXIT_CONFIG}" "CONFIG_VERSION '${CONFIG_VERSION:-unset}' does not match required '${REQUIRED_CONFIG_VERSION}'"

# All values except the optional SSH_KEY must be set in the config
for var in SSH_HOST SSH_PORT SSH_USER DUMP_DIR RETENTION_COUNT MYSQLDUMP_OPTIONS \
           SSH_CONNECT_TIMEOUT SSH_ALIVE_INTERVAL SECRETS_FILE KNOWN_HOSTS_FILE \
           LOG_FILE MARKER_FILE LOCK_FILE; do
    [[ -n "${!var:-}" ]] || die "${EXIT_CONFIG}" "Required config value missing: ${var}"
done
[[ "$(declare -p DB_LIST 2>/dev/null)" == "declare -a"* && "${#DB_LIST[@]}" -gt 0 ]] \
    || die "${EXIT_CONFIG}" "DB_LIST is missing, empty or not an array"
[[ "${RETENTION_COUNT}" =~ ^[1-9][0-9]*$ ]] \
    || die "${EXIT_CONFIG}" "RETENTION_COUNT must be a positive integer"

# The log directory is created by the deployment, not by the script
if [[ ! -d "$(dirname "${LOG_FILE}")" || ! -w "$(dirname "${LOG_FILE}")" ]]; then
    printf 'ERROR: log directory missing or not writable: %s\n' "$(dirname "${LOG_FILE}")" >&2
    exit "${EXIT_FS}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "INFO" "START (version ${VERSION}, dry-run)"
else
    log "INFO" "START (version ${VERSION})"
fi

# Prevent parallel runs (LOCK_FILE comes from the config)
exec 9>"${LOCK_FILE}" || die "${EXIT_FS}" "Cannot open lock file: ${LOCK_FILE}"
flock -n 9 || die "${EXIT_LOCKED}" "Another instance is already running"

# Load secrets (SECRETS_FILE comes from the config)
check_file "${SECRETS_FILE}" 600 root
secrets_dir="$(dirname "${SECRETS_FILE}")"
[[ "$(stat -c '%a %U:%G' "${secrets_dir}")" == "700 root:root" ]] \
    || die "${EXIT_CONFIG}" "Secrets directory must be 700 root:root: ${secrets_dir}"
declare -A DB_PASSWORDS=()
SSH_PASSWORD=""
# shellcheck source=/dev/null
source "${SECRETS_FILE}"

# ---------------------------------------------------------------
# Validate authentication, dependencies and DB_LIST
# ---------------------------------------------------------------

if [[ -n "${SSH_KEY:-}" ]]; then
    [[ -r "${SSH_KEY}" ]] || die "${EXIT_CONFIG}" "SSH_KEY not readable: ${SSH_KEY}"
else
    [[ -n "${SSH_PASSWORD}" ]] \
        || die "${EXIT_CONFIG}" "SSH_KEY is not set and SSH_PASSWORD is empty in the secrets file"
fi

needed=(ssh gzip zcat flock stat)
if [[ -z "${SSH_KEY:-}" ]]; then
    needed+=(sshpass)
fi
for cmd in "${needed[@]}"; do
    command -v "${cmd}" > /dev/null 2>&1 || die "${EXIT_DEP}" "Missing dependency: ${cmd}"
done

[[ -r "${KNOWN_HOSTS_FILE}" ]] \
    || die "${EXIT_CONFIG}" "known_hosts file not found: ${KNOWN_HOSTS_FILE} (see INSTALL.md)"

# Labels and DB names end up in file names and in the remote command: restrict them
declare -A SEEN_LABELS=()
for entry in "${DB_LIST[@]}"; do
    extra=""
    IFS='|' read -r label dbhost dbname dbuser extra <<< "${entry}"
    [[ -z "${extra}" && -n "${label:-}" && -n "${dbhost:-}" && -n "${dbname:-}" && -n "${dbuser:-}" ]] \
        || die "${EXIT_CONFIG}" "Invalid DB_LIST entry (expected label|host|name|user): ${entry}"
    [[ "${label}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] \
        || die "${EXIT_CONFIG}" "Invalid label '${label}' (allowed: letters, digits, hyphen; no underscore)"
    [[ "${dbname}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
        || die "${EXIT_CONFIG}" "Invalid database name: ${dbname}"
    [[ -z "${SEEN_LABELS[${label}]:-}" ]] \
        || die "${EXIT_CONFIG}" "Duplicate label in DB_LIST: ${label}"
    SEEN_LABELS[${label}]=1
    [[ -n "${DB_PASSWORDS[${label}]:-}" ]] \
        || die "${EXIT_CONFIG}" "No password in the secrets file for label: ${label}"
done

# The dump directory is created by the deployment (an unmounted disk must not
# silently fill the system disk)
[[ -d "${DUMP_DIR}" && -w "${DUMP_DIR}" ]] \
    || die "${EXIT_FS}" "Dump directory missing or not writable: ${DUMP_DIR}"

# ---------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "INFO" "[dry-run] config, secrets and dump directory OK"
    run_ssh 'echo ok' > /dev/null 2>> "${LOG_FILE}" \
        || die "${EXIT_CHECK}" "[dry-run] SSH login failed"
    log "INFO" "[dry-run] SSH login OK"
    failed=0
    for entry in "${DB_LIST[@]}"; do
        IFS='|' read -r label dbhost dbname dbuser <<< "${entry}"
        check_one "${label}" "${dbhost}" "${dbname}" "${dbuser}" || failed=$((failed + 1))
    done
    [[ "${failed}" -eq 0 ]] || die "${EXIT_CHECK}" "[dry-run] ${failed} database check(s) failed"
    log "INFO" "[dry-run] all checks passed"
    exit "${EXIT_OK}"
fi

# ---------------------------------------------------------------
# Dump all databases
# ---------------------------------------------------------------

failed=0
for entry in "${DB_LIST[@]}"; do
    IFS='|' read -r label dbhost dbname dbuser <<< "${entry}"
    dump_one "${label}" "${dbhost}" "${dbname}" "${dbuser}" || failed=$((failed + 1))
done

if [[ "${failed}" -gt 0 ]]; then
    die "${EXIT_DUMP}" "${failed} of ${#DB_LIST[@]} dump(s) failed, marker file not updated"
fi

# --- Success: write marker as the very last step (MARKER_FILE from config) ---
date '+%Y-%m-%d %H:%M:%S' > "${MARKER_FILE}" \
    || die "${EXIT_FS}" "Cannot write marker file: ${MARKER_FILE}"
log "INFO" "Finished successfully (${#DB_LIST[@]} database(s))"
exit "${EXIT_OK}"

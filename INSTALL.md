# Installation: mysql-ssh-dump

Step-by-step deployment on Debian. Work as a normal user with `sudo`; every block can be copy-pasted in order in the same terminal session. The variables set in steps 0 and 3 are only valid in the current session.

## 0. Variables

```bash
SCRIPT_HOME=/usr/local/scripts
SCRIPT_NAME=mysql-ssh-dump
SCRIPT_DIR="${SCRIPT_HOME}/${SCRIPT_NAME}"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.config"
TAG=v1.0.0
```

`SCRIPT_HOME` is only used by this guide, change it only if the base path differs. `TAG` is the release to install (example value).

## 1. Prerequisites

```bash
sudo apt update
sudo apt install -y git openssh-client gzip util-linux sshpass
```

`sshpass` is only needed for password login and can be skipped if you use `SSH_KEY`. For the signed release tag (step 2) the `allowed_signers` file must be set up as described in `script-release-setup.md`.

## 2. Script directory and files

`SCRIPT_HOME` belongs to your normal user, so no `sudo` is needed below it. Note that this script runs as root: a script directory that other users can write to is a risk, so keep access to this user restricted.

```bash
sudo mkdir -p "${SCRIPT_HOME}"
sudo chown "$USER": "${SCRIPT_HOME}"
```

**Release way:** clone the repository and check out the signed tag. The checkout only runs if the signature is valid.

```bash
git clone "https://github.com/it-flows-de/${SCRIPT_NAME}.git" "${SCRIPT_DIR}"
cd "${SCRIPT_DIR}"
git -c gpg.ssh.allowedSignersFile=/etc/get-scriptupdate/allowed_signers verify-tag "${TAG}" && git checkout "${TAG}"
```

**Development way (only before the first release):** create the files by hand and paste the contents.

```bash
mkdir -p "${SCRIPT_DIR}"
cd "${SCRIPT_DIR}"
touch "${SCRIPT_NAME}.sh" "${SCRIPT_NAME}.config.example" "${SCRIPT_NAME}.secrets.example"
chmod 755 "${SCRIPT_NAME}.sh"
```

## 3. Configuration

```bash
cd "${SCRIPT_DIR}"
cp "${SCRIPT_NAME}.config.example" "${SCRIPT_NAME}.config"
vi "${CONFIG_FILE}"
chmod 660 "${CONFIG_FILE}"
source "${CONFIG_FILE}"
echo "${SSH_USER}@${SSH_HOST}:${SSH_PORT} -> ${DUMP_DIR}"
```

The config is sourced by bash, so only edit values. Check that the printed values are correct before you continue.

## 4. Directories

The script does not create the dump or log directory. Check first that the dump directory is on the intended disk:

```bash
findmnt -T "${DUMP_DIR%/*}"
```

```bash
sudo mkdir -p "${DUMP_DIR}" "$(dirname "${LOG_FILE}")" "$(dirname "${SECRETS_FILE}")"
sudo chmod 700 "${DUMP_DIR}" "$(dirname "${SECRETS_FILE}")"
```

## 5. Secrets

```bash
sudo cp "${SCRIPT_DIR}/${SCRIPT_NAME}.secrets.example" "${SECRETS_FILE}"
sudo vi "${SECRETS_FILE}"
sudo chown root:root "${SECRETS_FILE}"
sudo chmod 600 "${SECRETS_FILE}"
```

Use single quotes for all values (see the comment in the file). Every label used in `DB_LIST` needs an entry in `DB_PASSWORDS`; `SSH_PASSWORD` is required unless `SSH_KEY` is set in the config.

## 6. SSH host key

The script only trusts the host key stored in `KNOWN_HOSTS_FILE` and never accepts unknown keys automatically.

```bash
ssh-keyscan -p "${SSH_PORT}" "${SSH_HOST}" > "${KNOWN_HOSTS_FILE}"
ssh-keygen -lf "${KNOWN_HOSTS_FILE}"
```

Compare the printed fingerprint with the one from your provider or a previous trusted login. Only continue if it matches.

## 7. Log rotation

The script appends to one log file, `logrotate` rotates it (example: daily, 30 files; adjust to your needs).

```bash
sudo tee "/etc/logrotate.d/${SCRIPT_NAME}" > /dev/null <<LOGROTATE
${LOG_FILE} {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 660 root adm
}
LOGROTATE
sudo chown root:root "/etc/logrotate.d/${SCRIPT_NAME}"
sudo chmod 644 "/etc/logrotate.d/${SCRIPT_NAME}"
sudo logrotate -d "/etc/logrotate.d/${SCRIPT_NAME}"
```

The last command is a dry run and must not print errors.

## 8. Test

```bash
bash -n "${SCRIPT_DIR}/${SCRIPT_NAME}.sh"
"${SCRIPT_DIR}/${SCRIPT_NAME}.sh" --help
```

Dry run: checks config, secrets, SSH login and every database connection. It writes no dump and no marker file.

```bash
sudo "${SCRIPT_DIR}/${SCRIPT_NAME}.sh" --dry-run; echo "exit code: $?"
sudo tail -n 30 "${LOG_FILE}"
```

Expected: exit code `0`. Then one real run:

```bash
sudo "${SCRIPT_DIR}/${SCRIPT_NAME}.sh"; echo "exit code: $?"
sudo ls -lh "${DUMP_DIR}"
cat "${MARKER_FILE}"
sudo tail -n 30 "${LOG_FILE}"
```

Expected: one `.sql.gz` file per database and a marker file with the current date. Check that the newest dump ends with the completion line:

```bash
sudo bash -c 'zcat "$(ls -t "$1"/*.sql.gz | head -n 1)" | tail -n 1' _ "${DUMP_DIR}"
```

Expected: `-- Dump completed on ...`

Error case (invalid option, must end with exit code `2` and leave the marker file unchanged):

```bash
sudo "${SCRIPT_DIR}/${SCRIPT_NAME}.sh" --invalid; echo "exit code: $?"
```

Finally, restore one dump into a separate test database at least once. A dump that was never restored is not a proven backup.

## 9. Schedule with cron

Run it as root, not around midnight (logrotate runs then). The redirect also catches errors that occur before the config is loaded, so there is no log file yet.

```bash
( sudo crontab -l 2>/dev/null; echo "0 2 * * * ${SCRIPT_DIR}/${SCRIPT_NAME}.sh >> ${LOG_FILE} 2>&1" ) | sudo crontab -
sudo crontab -l
```

## 10. Monitoring

Point your monitoring (for example n-sight RMM) at the file age of the marker file and alarm if it gets too old:

```bash
echo "${MARKER_FILE}"
```

The file is only updated when all databases were dumped successfully, never on `--dry-run`. For a daily run, an alarm threshold of about 36 hours is reasonable.

## Troubleshooting: exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | error (for example not run as root) |
| 2 | invalid option |
| 3 | config or secrets error (missing file, wrong permissions, wrong `CONFIG_VERSION`, invalid `DB_LIST`) |
| 4 | another instance is already running |
| 5 | missing dependency |
| 6 | SSH login or database connection failed (dry-run) |
| 7 | one or more dumps failed |
| 8 | filesystem error (dump directory, log directory, lock file, marker file) |

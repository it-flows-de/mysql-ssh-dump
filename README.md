# mysql-ssh-dump

Bash script that creates compressed dumps of one or more MySQL/MariaDB databases which are not directly reachable from the backup server, for example databases on shared hosting. `mysqldump` runs on a remote host over SSH, and the output is streamed back and stored locally.

Typical use case: a web hosting package with SSH access to the web space, but no direct access to the database server. The database server is reachable from the web space, so the web space is used as a jump host.

## How it works

For every database in the config, the script opens an SSH connection, passes the database credentials as an option file through that connection (stdin), runs `mysqldump` on the remote host and stores the compressed output locally. A dump is only kept if it is a valid gzip file and ends with `-- Dump completed`. Nothing is stored on the remote host and no password appears in a process list.

## Requirements

- Debian (or compatible) with Bash, `ssh`, `gzip`, `flock`
- `sshpass` if password login is used
- Remote host with `mysqldump` and network access to the database server
- Runs as root (the secrets are read from a root-only directory)

## Installation

See [INSTALL.md](INSTALL.md).

## Configuration

Copy `mysql-ssh-dump.config.example` to `mysql-ssh-dump.config` and adjust it. The example file documents every parameter. The secrets (SSH password, database passwords) go into a separate file, see `mysql-ssh-dump.secrets.example`. Both real files are excluded from Git.

| Parameter                                   | Meaning                                                                    |
|---------------------------------------------|----------------------------------------------------------------------------|
| `SSH_HOST`, `SSH_PORT`, `SSH_USER`          | SSH target that can reach the database server                              |
| `DUMP_DIR`                                  | Local directory for the dumps (must exist)                                 |
| `DB_LIST`                                   | Databases to dump, one entry per line: `label\\|db_host\|db_name\|db_user` |
| `SSH_KEY`                                   | Optional. Private key for key login. Not set = password login              |
| `RETENTION_COUNT`                           | Number of dumps to keep per database                                       |
| `MYSQLDUMP_OPTIONS`                         | Options passed to `mysqldump`                                              |
| `SSH_CONNECT_TIMEOUT`, `SSH_ALIVE_INTERVAL` | SSH timeouts in seconds                                                    |

Labels in `DB_LIST` link an entry to its password in the secrets file. Allowed characters are letters, digits and hyphen. Dump files are named `<label>_<YYYY-MM-DD>_<HHMMSS>.sql.gz`.

**Path defaults** (set in the config, change only if needed):

| What             | Default                                      |
|------------------|----------------------------------------------|
| Script directory | `/usr/local/scripts/mysql-ssh-dump`          |
| Log file         | `/var/log/mysql-ssh-dump/mysql-ssh-dump.log` |
| Marker file      | `<script directory>/last-successful`         |
| Lock file        | `/run/lock/mysql-ssh-dump.lock`              |
| Known hosts      | `<script directory>/known_hosts`             |
| Secrets file     | `/root/.secrets/mysql-ssh-dump.secrets`      |

## Usage

```
mysql-ssh-dump.sh [--dry-run] [--help]
```

| Option      | Description                                                                                   |
|-------------|-----------------------------------------------------------------------------------------------|
| `--dry-run` | Check config, secrets, SSH login and database connections. Writes no dump and no marker file. |
| `--help`    | Show the usage text.                                                                          |

The script is meant to run unattended from cron.

## Exit codes

| Code | Meaning                                           |
|------|---------------------------------------------------|
| 0    | success                                           |
| 1    | error (for example not run as root)               |
| 2    | invalid option                                    |
| 3    | config or secrets error                           |
| 4    | another instance is already running               |
| 5    | missing dependency                                |
| 6    | SSH login or database connection failed (dry-run) |
| 7    | one or more dumps failed                          |
| 8    | filesystem error                                  |

## Monitoring

The marker file `last-successful` is only updated after a run in which all databases were dumped successfully. Check its file age with your monitoring tool (for example n-sight RMM) and alarm if it is older than the expected interval plus a margin. For a daily run, about 36 hours is a reasonable threshold.

## Restoring a dump

```bash
zcat <label>_<date>.sql.gz | mysql -h <host> -u <user> -p <database>
```

Test a restore on a separate database at least once.

## Security notes

- The dumps contain all database content, including user data and password hashes. The dump directory is created with `chmod 700` and the dump files are only readable by root.
- The script checks owner and permissions of the secrets file and its directory and refuses to run if they are wrong.
- The SSH host key is verified against a `known_hosts` file in the script directory. Unknown keys are never accepted automatically.
- Dumps are not encrypted at rest and not copied off the server. Add an offsite copy as a separate step if you need one.

## Limitations

- One SSH connection per database
- The remote host must provide `mysqldump`
- Only SSH password and key login are supported (no agent, no jump hosts)
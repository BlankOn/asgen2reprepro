# asgen2reprepro

Tools for integrating appstream-generator (asgen) DEP-11 metadata into reprepro Debian repositories, enabling GNOME Software and other AppStream-aware software centers to discover and display applications.

## Project Structure

```
integrate.sh          Main script: injects DEP-11 metadata into reprepro Release file, signs it
check.sh              Validation tool: checks remote repos for DEP-11 compatibility over HTTP
Dockerfile.html       Nginx container for serving asgen HTML reports
Dockerfile.media      Nginx container for serving asgen media/icons
asgen-config.json     Example appstream-generator configuration (BlankOn Linux)
conf/                 Reprepro configuration (distributions, options, updates)
pool/                 Debian package pool
db/                   Reprepro database (generated)
dists/                Repository metadata with Release files and dep11/ dirs (generated)
export/               Appstream-generator output: data/, hints/, html/, media/ (generated)
```

## Scripts

### integrate.sh

Copies DEP-11 files from asgen export into reprepro dist directories, computes checksums (MD5, SHA1, SHA256), updates the Release file, and signs it with GPG. Handles `.gz` and `.xz` compressed files, decompressing them for APT compatibility. Optionally builds Docker images for media/HTML serving.

```bash
./integrate.sh --basedir /path/to/asgen --distributions conf/distributions --dist dists/sid --gpg-key KEYID [--no-docker]
```

### check.sh

Validates a remote Debian repository's DEP-11 metadata over HTTP. Two modes:
- **Full mode**: 7 check sections (Release file, directory structure, metadata files, YAML validation, Release entries, checksum integrity, signatures) plus APT integration test
- **Essential mode** (`--essential`): 5 checks focused on what GNOME Software needs (Components YAML, icon tarballs, YAML header, signatures)

APT Integration Test (section 8 in full mode): checks APT source config, runs `sudo apt update`, verifies DEP-11 files in `/var/lib/apt/lists/`, validates appstreamcli cache and end-to-end component lookup.

```bash
./check.sh --url http://arsip-dev.blankonlinux.id/dev --dist verbeek --arch amd64
./check.sh --url http://arsip-dev.blankonlinux.id/dev --essential
```

## Key Concepts

- **DEP-11**: Debian's YAML-based AppStream metadata format. Files live in `<component>/dep11/` under each suite's dist directory.
- **Required files for GNOME Software**: `Components-<arch>.yml.gz`, `icons-48x48.tar.gz`, `icons-64x64.tar.gz`, all listed in Release with valid checksums, Release signed with GPG.
- **APT IndexTargets**: APT discovers DEP-11 via `/etc/apt/apt.conf.d/50appstream` (`deb::DEP-11`) and `/etc/apt/apt.conf.d/60icons` (`deb::DEP-11-icons-small`, `deb::DEP-11-icons`).
- **reprepro** does not natively manage DEP-11 metadata — that's the gap this project fills.

## Development Notes

- Scripts are bash with `set -uo pipefail`. check.sh intentionally omits `set -e` to continue through failures.
- check.sh uses streaming (`zcat | head`, `zcat | grep -c`) instead of storing large decompressed files in bash variables — critical for components with 18MB+ YAML files.
- check.sh uses `sudo -n` (non-interactive) for apt operations to avoid hanging on password prompts.
- The APT integration test gracefully degrades: if `sudo` fails, DEP-11 file checks report cached state with WARN instead of FAIL.
- Target repository: BlankOn Linux (arsip-dev.blankonlinux.id), suites include verbeek with components main, restricted, extras, restricted-firmware.

#!/bin/bash
set -euo pipefail

# integrate-dep11.sh
# Integrates appstream-generator DEP-11 metadata into a reprepro repository's
# Release file and signs it. Works for all components in the repository.

BASEDIR=""
GPG_KEY=""
DISTFILE=""
DIST_DIR=""

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  --basedir DIR           Repository root (default: current directory)"
    echo "  --distributions FILE    Path to distributions file (default: <basedir>/conf/distributions)"
    echo "  --dist DIR              Path to dist directory containing Release (default: <basedir>/dists/<codename>)"
    echo "  --gpg-key KEYID         GPG key ID to sign with (default: GPG default key)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --basedir)
            BASEDIR="$2"
            shift 2
            ;;
        --distributions)
            DISTFILE="$2"
            shift 2
            ;;
        --dist)
            DIST_DIR="$2"
            shift 2
            ;;
        --gpg-key)
            GPG_KEY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

BASEDIR="${BASEDIR:-.}"
BASEDIR="$(cd "$BASEDIR" && pwd)"

DISTFILE="${DISTFILE:-$BASEDIR/conf/distributions}"
if [[ ! -f "$DISTFILE" ]]; then
    echo "Error: $DISTFILE not found. Is this a reprepro repository?"
    exit 1
fi

# Parse codename and components from conf/distributions
CODENAME="$(grep -i '^Codename:' "$DISTFILE" | head -1 | sed 's/^[Cc]odename:[[:space:]]*//')"
COMPONENTS="$(grep -i '^Components:' "$DISTFILE" | head -1 | sed 's/^[Cc]omponents:[[:space:]]*//')"

if [[ -z "$CODENAME" ]]; then
    echo "Error: No Codename found in $DISTFILE"
    exit 1
fi
if [[ -z "$COMPONENTS" ]]; then
    echo "Error: No Components found in $DISTFILE"
    exit 1
fi

SUITE_DIR="${DIST_DIR:-$BASEDIR/dists/$CODENAME}"
if [[ -n "$DIST_DIR" ]]; then
    SUITE_DIR="$(cd "$SUITE_DIR" && pwd)"
fi
RELEASE_FILE="$SUITE_DIR/Release"

if [[ ! -f "$RELEASE_FILE" ]]; then
    echo "Error: $RELEASE_FILE not found. Run 'reprepro export' first."
    exit 1
fi

echo "Distributions: $DISTFILE"
echo "Dist dir:      $SUITE_DIR"
echo "Codename:      $CODENAME"
echo "Components:    $COMPONENTS"
echo ""

# Collect dep11 files across all components
declare -a DEP11_RELPATHS=()

for component in $COMPONENTS; do
    dep11dir="$SUITE_DIR/$component/dep11"
    if [[ ! -d "$dep11dir" ]]; then
        echo "Skipping component '$component': no dep11 directory"
        continue
    fi

    files="$(find "$dep11dir" -maxdepth 1 -type f | sort)"
    if [[ -z "$files" ]]; then
        echo "Skipping component '$component': dep11 directory is empty"
        continue
    fi

    echo "Found dep11 data for component '$component':"
    while IFS= read -r filepath; do
        filename="$(basename "$filepath")"
        relpath="$component/dep11/$filename"
        DEP11_RELPATHS+=("$relpath")
        echo "  $relpath"
    done <<< "$files"
done

echo ""

if [[ ${#DEP11_RELPATHS[@]} -eq 0 ]]; then
    echo "Error: No dep11 files found for any component."
    echo "Run 'appstream-generator' first to generate DEP-11 metadata."
    exit 1
fi

# Compute checksums for dep11 files
declare -A FILE_MD5 FILE_SHA1 FILE_SHA256 FILE_SIZE

for relpath in "${DEP11_RELPATHS[@]}"; do
    filepath="$SUITE_DIR/$relpath"
    FILE_SIZE[$relpath]="$(stat --format='%s' "$filepath")"
    FILE_MD5[$relpath]="$(md5sum "$filepath" | awk '{print $1}')"
    FILE_SHA1[$relpath]="$(sha1sum "$filepath" | awk '{print $1}')"
    FILE_SHA256[$relpath]="$(sha256sum "$filepath" | awk '{print $1}')"
done

# Reconstruct the Release file with dep11 entries injected.
# Extract each section from the original, strip any old dep11 lines (idempotency),
# then append fresh dep11 entries.

OUTPUT="$(mktemp)"
trap 'rm -f "$OUTPUT"' EXIT

# Header: everything before MD5Sum:
sed '/^MD5Sum:/,$d' "$RELEASE_FILE" > "$OUTPUT"

# MD5Sum section
echo "MD5Sum:" >> "$OUTPUT"
sed -n '/^MD5Sum:/,/^SHA1:/{/^MD5Sum:/d;/^SHA1:/d;/dep11/d;p}' "$RELEASE_FILE" >> "$OUTPUT"
for relpath in "${DEP11_RELPATHS[@]}"; do
    echo " ${FILE_MD5[$relpath]} ${FILE_SIZE[$relpath]} $relpath" >> "$OUTPUT"
done

# SHA1 section
echo "SHA1:" >> "$OUTPUT"
sed -n '/^SHA1:/,/^SHA256:/{/^SHA1:/d;/^SHA256:/d;/dep11/d;p}' "$RELEASE_FILE" >> "$OUTPUT"
for relpath in "${DEP11_RELPATHS[@]}"; do
    echo " ${FILE_SHA1[$relpath]} ${FILE_SIZE[$relpath]} $relpath" >> "$OUTPUT"
done

# SHA256 section
echo "SHA256:" >> "$OUTPUT"
sed -n '/^SHA256:/,${/^SHA256:/d;/dep11/d;p}' "$RELEASE_FILE" >> "$OUTPUT"
for relpath in "${DEP11_RELPATHS[@]}"; do
    echo " ${FILE_SHA256[$relpath]} ${FILE_SIZE[$relpath]} $relpath" >> "$OUTPUT"
done

cp "$OUTPUT" "$RELEASE_FILE"
echo "Updated $RELEASE_FILE with dep11 entries."

# Sign the Release file
GPG_OPTS=()
if [[ -n "$GPG_KEY" ]]; then
    GPG_OPTS+=(-u "$GPG_KEY")
fi

# Detached signature: Release.gpg
rm -f "$SUITE_DIR/Release.gpg"
gpg "${GPG_OPTS[@]}" --armor --detach-sign --output "$SUITE_DIR/Release.gpg" "$RELEASE_FILE"
echo "Created $SUITE_DIR/Release.gpg"

# Cleartext signature: InRelease
rm -f "$SUITE_DIR/InRelease"
gpg "${GPG_OPTS[@]}" --armor --clearsign --output "$SUITE_DIR/InRelease" "$RELEASE_FILE"
echo "Created $SUITE_DIR/InRelease"

echo ""
echo "Done. DEP-11 metadata integrated and Release signed."

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
    echo "Usage: $0 --basedir DIR --distributions FILE --dist DIR --gpg-key KEYID"
    echo ""
    echo "  --basedir DIR           Appstream-generator working directory with cache/db/export"
    echo "  --distributions FILE    Path to reprepro distributions file"
    echo "  --dist DIR              Path to dist directory containing Release"
    echo "  --gpg-key KEYID         GPG key ID to sign with"
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

if [[ -z "$BASEDIR" ]]; then
    echo "Error: --basedir is required."
    usage
fi
if [[ -z "$DISTFILE" ]]; then
    echo "Error: --distributions is required."
    usage
fi
if [[ -z "$DIST_DIR" ]]; then
    echo "Error: --dist is required."
    usage
fi
if [[ -z "$GPG_KEY" ]]; then
    echo "Error: --gpg-key is required."
    usage
fi

BASEDIR="$(cd "$BASEDIR" && pwd)"

if [[ ! -f "$DISTFILE" ]]; then
    echo "Error: $DISTFILE not found."
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

SUITE_DIR="$(cd "$DIST_DIR" && pwd)"
RELEASE_FILE="$SUITE_DIR/Release"

if [[ ! -f "$RELEASE_FILE" ]]; then
    echo "Error: $RELEASE_FILE not found."
    echo "Provide --dist to point to the directory containing Release."
    exit 1
fi

echo "Basedir:       $BASEDIR"
echo "Distributions: $DISTFILE"
echo "Dist dir:      $SUITE_DIR"
echo "Codename:      $CODENAME"
echo "Components:    $COMPONENTS"
echo ""

# Source dep11 files from asgen export/data/<codename>/<component>/
ASGEN_DATA="$BASEDIR/export/data/$CODENAME"

# Collect and copy dep11 files from asgen basedir to reprepro dist dir
declare -a DEP11_RELPATHS=()

for component in $COMPONENTS; do
    src_dep11="$ASGEN_DATA/$component"
    if [[ ! -d "$src_dep11" ]]; then
        echo "Skipping component '$component': no data in asgen export"
        continue
    fi

    files="$(find "$src_dep11" -maxdepth 1 -type f | sort)"
    if [[ -z "$files" ]]; then
        echo "Skipping component '$component': no files in asgen export"
        continue
    fi

    # Copy dep11 files to reprepro dist dir
    dst_dep11="$SUITE_DIR/$component/dep11"
    mkdir -p "$dst_dep11"
    echo "Copying dep11 data for component '$component':"
    echo "  from: $src_dep11"
    echo "  to:   $dst_dep11"

    while IFS= read -r filepath; do
        filename="$(basename "$filepath")"
        cp "$filepath" "$dst_dep11/$filename"
        relpath="$component/dep11/$filename"
        DEP11_RELPATHS+=("$relpath")
        echo "  $relpath"

        # APT requires uncompressed base entries in the Release file.
        # Decompress .gz files to produce the base version (e.g. .yml, .tar).
        if [[ "$filename" == *.gz ]]; then
            base_filename="${filename%.gz}"
            gunzip -k -f "$dst_dep11/$filename"
            base_relpath="$component/dep11/$base_filename"
            DEP11_RELPATHS+=("$base_relpath")
            echo "  $base_relpath (decompressed)"
        fi
    done <<< "$files"
done

echo ""

if [[ ${#DEP11_RELPATHS[@]} -eq 0 ]]; then
    echo "Error: No dep11 files found for any component in $ASGEN_DATA."
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
# Detached signature: Release.gpg
rm -f "$SUITE_DIR/Release.gpg"
gpg -u "$GPG_KEY" --armor --detach-sign --output "$SUITE_DIR/Release.gpg" "$RELEASE_FILE"
echo "Created $SUITE_DIR/Release.gpg"

# Cleartext signature: InRelease
rm -f "$SUITE_DIR/InRelease"
gpg -u "$GPG_KEY" --armor --clearsign --output "$SUITE_DIR/InRelease" "$RELEASE_FILE"
echo "Created $SUITE_DIR/InRelease"

echo ""
echo "Done. DEP-11 metadata integrated and Release signed."

# Build Docker images for serving media and HTML via nginx
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "Building Docker images..."

# Build media Docker image
echo "Building asgen-media Docker image..."
docker build -f "$SCRIPT_DIR/Dockerfile.media" \
    --build-arg MEDIA_DIR="$BASEDIR/export/media" \
    -t asgen-media \
    "$BASEDIR/export/media"
echo "Built asgen-media image."

# Build HTML Docker image
echo "Building asgen-html Docker image..."
docker build -f "$SCRIPT_DIR/Dockerfile.html" \
    --build-arg HTML_DIR="$BASEDIR/export/html" \
    -t asgen-html \
    "$BASEDIR/export/html"
echo "Built asgen-html image."

echo ""
echo "Docker images built successfully."
echo "  Run media server: docker run -d -p 8081:80 asgen-media"
echo "  Run HTML server:  docker run -d -p 8082:80 asgen-html"

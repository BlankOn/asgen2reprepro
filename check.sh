#!/bin/bash
set -uo pipefail

# check-dep11.sh
# Checks if a remote Debian repository is compatible with DEP-11 appstream metadata.
# Fetches everything over HTTP and outputs a table of checklist items.
#
# Usage:
#   ./check-dep11.sh --url URL                                        # Full check, all suites
#   ./check-dep11.sh --url URL --essential                            # Only GNOME Software checks
#   ./check-dep11.sh --url URL --dist verbeek                        # Only check 'verbeek' suite
#   ./check-dep11.sh --url URL --dist verbeek --arch amd64           # Only check amd64
#   ./check-dep11.sh --url URL --dist verbeek --arch amd64 --essential # Combined

REPO_URL=""
ESSENTIAL=false
FILTER_DIST=""
FILTER_ARCH=""

usage() {
    echo "Usage: $0 --url URL [--dist SUITE] [--arch ARCH] [--essential]"
    echo ""
    echo "  --url URL       Base URL of the Debian repository"
    echo "                  e.g. http://arsip-dev.blankonlinux.id/dev"
    echo "  --dist SUITE    Only check a specific distribution/suite (e.g. verbeek)"
    echo "  --arch ARCH     Only check a specific architecture (e.g. amd64)"
    echo "  --essential     Only check what GNOME Software needs to load appstream metadata"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            REPO_URL="${2%/}"
            shift 2
            ;;
        --dist)
            FILTER_DIST="$2"
            shift 2
            ;;
        --arch)
            FILTER_ARCH="$2"
            shift 2
            ;;
        --essential)
            ESSENTIAL=true
            shift
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

if [[ -z "$REPO_URL" ]]; then
    echo "Error: --url is required."
    usage
fi

# --- Temp dir for downloaded files ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# --- State ---
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

check() {
    local status="$1"
    local description="$2"
    local details="${3:-}"
    TOTAL=$((TOTAL + 1))

    case "$status" in
        PASS)
            PASS_COUNT=$((PASS_COUNT + 1))
            printf "  ${GREEN}%-8s${NC} %-60s %s\n" "[PASS]" "$description" "$details"
            ;;
        FAIL)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            printf "  ${RED}%-8s${NC} %-60s %s\n" "[FAIL]" "$description" "$details"
            ;;
        WARN)
            WARN_COUNT=$((WARN_COUNT + 1))
            printf "  ${YELLOW}%-8s${NC} %-60s %s\n" "[WARN]" "$description" "$details"
            ;;
    esac
}

print_section() {
    echo ""
    echo -e "  ${BOLD}$1${NC}"
}

# Fetch a URL. Returns 0 if HTTP 200, 1 otherwise.
# Content is saved to the path given in $2 (optional).
fetch() {
    local url="$1"
    local dest="${2:-/dev/null}"
    local http_code
    http_code=$(curl -sL -o "$dest" -w '%{http_code}' "$url" 2>/dev/null)
    [[ "$http_code" == "200" ]]
}

# Fetch a URL and return just the HTTP status code.
fetch_status() {
    curl -sL -o /dev/null -w '%{http_code}' "$1" 2>/dev/null
}

# Get Content-Length of a URL via HEAD request.
fetch_size() {
    curl -sI -L "$1" 2>/dev/null | grep -i '^Content-Length:' | tail -1 | awk '{print $2}' | tr -d '\r'
}

# ============================================================================
# Discover suites
# ============================================================================

echo ""
if $ESSENTIAL; then
    echo -e "${BOLD}DEP-11 Essential Check (GNOME Software)${NC}"
    echo -e "${BOLD}========================================${NC}"
else
    echo -e "${BOLD}DEP-11 AppStream Metadata Compatibility Check${NC}"
    echo -e "${BOLD}===============================================${NC}"
fi
echo ""
echo -e "  Repository: $REPO_URL"
if [[ -n "$FILTER_DIST" ]]; then
    echo -e "  Distribution: $FILTER_DIST"
fi
if [[ -n "$FILTER_ARCH" ]]; then
    echo -e "  Architecture: $FILTER_ARCH"
fi
if $ESSENTIAL; then
    echo -e "  Mode:       ${YELLOW}essential${NC} (GNOME Software requirements only)"
fi

if [[ -n "$FILTER_DIST" ]]; then
    # Use the specified suite directly without fetching directory listing
    SUITES="$FILTER_DIST"
    echo -e "  Suite:      $FILTER_DIST"
else
    # List suites from dists/ directory listing
    DISTS_HTML="$TMPDIR/dists.html"
    if ! fetch "$REPO_URL/dists/" "$DISTS_HTML"; then
        echo ""
        echo -e "  ${RED}Error: Cannot fetch $REPO_URL/dists/${NC}"
        exit 1
    fi

    SUITES=$(grep -oP 'href="\K[^"]+(?=/")' "$DISTS_HTML" | sort)
    if [[ -z "$SUITES" ]]; then
        echo -e "  ${RED}Error: No suites found under $REPO_URL/dists/${NC}"
        exit 1
    fi

    echo -e "  Suites found: $(echo $SUITES | tr '\n' ' ')"
fi

# ============================================================================
# Check each suite
# ============================================================================

# Collect suite metadata for APT integration test later
declare -a CHECKED_SUITES=()
declare -A SUITE_COMPONENTS=()
declare -A SUITE_ARCHITECTURES=()

for suite in $SUITES; do
    SUITE_URL="$REPO_URL/dists/$suite"

    echo ""
    echo -e "${BOLD}Suite: $suite${NC}"
    echo -e "${BOLD}$(printf '%0.s=' $(seq 1 $((${#suite} + 7))))${NC}"
    printf "\n  %-8s %-60s %s\n" "STATUS" "CHECK" "DETAILS"
    printf "  %-8s %-60s %s\n" "------" "-----" "-------"

    # ---- 1. Release file ----
    print_section "1. Release File"

    RELEASE_FILE="$TMPDIR/${suite}_Release"
    if fetch "$SUITE_URL/Release" "$RELEASE_FILE"; then
        check PASS "Release file exists" "$SUITE_URL/Release"
    else
        check FAIL "Release file exists" "Not found"
        continue
    fi

    CODENAME="$(grep -i '^Codename:' "$RELEASE_FILE" | head -1 | sed 's/^[Cc]odename:[[:space:]]*//' | tr -d '\r')"
    COMPONENTS="$(grep -i '^Components:' "$RELEASE_FILE" | head -1 | sed 's/^[Cc]omponents:[[:space:]]*//' | tr -d '\r')"
    ARCHITECTURES="$(grep -i '^Architectures:' "$RELEASE_FILE" | head -1 | sed 's/^[Aa]rchitectures:[[:space:]]*//' | tr -d '\r')"

    # Filter out 'source' from architectures
    ARCHITECTURES="$(echo "$ARCHITECTURES" | sed 's/\bsource\b//g' | xargs)"

    # Apply --arch filter
    if [[ -n "$FILTER_ARCH" ]]; then
        if echo " $ARCHITECTURES " | grep -q " $FILTER_ARCH "; then
            ARCHITECTURES="$FILTER_ARCH"
        else
            check WARN "Architecture '$FILTER_ARCH' not in Release" "Available: $ARCHITECTURES"
            ARCHITECTURES="$FILTER_ARCH"
        fi
    fi

    if [[ -n "$CODENAME" ]]; then
        check PASS "Codename is defined" "$CODENAME"
    else
        check FAIL "Codename is defined" "Missing"
    fi

    if [[ -n "$COMPONENTS" ]]; then
        check PASS "Components are defined" "$COMPONENTS"
    else
        check FAIL "Components are defined" "Missing"
        continue
    fi

    if [[ -n "$ARCHITECTURES" ]]; then
        check PASS "Architectures are defined" "$ARCHITECTURES"
    else
        check FAIL "Architectures are defined" "Missing"
        continue
    fi

    # Save for APT integration test
    CHECKED_SUITES+=("$suite")
    SUITE_COMPONENTS[$suite]="$COMPONENTS"
    SUITE_ARCHITECTURES[$suite]="$ARCHITECTURES"

    if $ESSENTIAL; then
        # ==================================================================
        # ESSENTIAL MODE
        # Checks only what APT + GNOME Software need:
        #   - Components-<arch>.yml.gz listed in Release + fetchable
        #   - icons-48x48.tar.gz and icons-64x64.tar.gz listed + fetchable
        #   - Release signature (Release.gpg or InRelease)
        #   - Valid DEP-11 YAML header
        #
        # Reference: /etc/apt/apt.conf.d/50appstream (deb::DEP-11)
        #            /etc/apt/apt.conf.d/60icons (deb::DEP-11-icons-small,
        #                                         deb::DEP-11-icons)
        # ==================================================================

        # ---- 2. Components YAML in Release file ----
        print_section "2. Components YAML Metadata (APT deb::DEP-11 target)"

        for component in $COMPONENTS; do
            dep11_url="$SUITE_URL/$component/dep11"
            for arch in $ARCHITECTURES; do
                metakey="$component/dep11/Components-${arch}.yml"

                # Check if listed in Release (APT looks up the MetaKey)
                if grep -q "$metakey" "$RELEASE_FILE"; then
                    check PASS "Listed in Release: $metakey" ""
                else
                    check FAIL "Listed in Release: $metakey" "APT cannot discover this file"
                fi

                # Check .gz is fetchable (APT downloads compressed)
                f_url="$dep11_url/Components-${arch}.yml.gz"
                status=$(fetch_status "$f_url")
                if [[ "$status" == "200" ]]; then
                    size=$(fetch_size "$f_url")
                    check PASS "Fetchable: Components-${arch}.yml.gz ($component)" "${size} bytes"
                else
                    check FAIL "Fetchable: Components-${arch}.yml.gz ($component)" "HTTP $status $f_url"
                fi
            done
        done

        # ---- 3. Icon tarballs in Release file ----
        # 60icons enables icons-48x48 and icons-64x64 for GNOME Software.
        # "Applications without an icon will not be displayed at all."
        print_section "3. Icon Tarballs (required by GNOME Software)"

        for component in $COMPONENTS; do
            dep11_url="$SUITE_URL/$component/dep11"
            for icon_name in "icons-48x48" "icons-64x64"; do
                metakey="$component/dep11/${icon_name}.tar"

                # Listed in Release
                if grep -q "$metakey" "$RELEASE_FILE"; then
                    check PASS "Listed in Release: $metakey" ""
                else
                    check FAIL "Listed in Release: $metakey" "GNOME Software needs this"
                fi

                # Fetchable (.tar.gz — APT downloads compressed)
                f_url="$dep11_url/${icon_name}.tar.gz"
                status=$(fetch_status "$f_url")
                if [[ "$status" == "200" ]]; then
                    check PASS "Fetchable: ${icon_name}.tar.gz ($component)" ""
                else
                    check FAIL "Fetchable: ${icon_name}.tar.gz ($component)" "HTTP $status $f_url"
                fi
            done
        done

        # ---- 4. DEP-11 YAML header validation ----
        print_section "4. DEP-11 YAML Header"

        for component in $COMPONENTS; do
            dep11_url="$SUITE_URL/$component/dep11"
            for arch in $ARCHITECTURES; do
                yml_gz="$TMPDIR/${suite}_${component}_${arch}.yml.gz"
                if ! fetch "$dep11_url/Components-${arch}.yml.gz" "$yml_gz"; then
                    check FAIL "YAML content ($component/$arch)" "Cannot fetch $dep11_url/Components-${arch}.yml.gz"
                    continue
                fi

                yaml_head="$(zcat "$yml_gz" 2>/dev/null | head -20 || true)"
                if [[ -z "$yaml_head" ]]; then
                    check FAIL "YAML content is non-empty ($component/$arch)" "Empty or corrupt"
                    continue
                fi

                if echo "$yaml_head" | grep -q '^File: DEP-11'; then
                    check PASS "Header 'File: DEP-11' ($component/$arch)" ""
                else
                    check FAIL "Header 'File: DEP-11' ($component/$arch)" "Missing"
                fi

                if echo "$yaml_head" | grep -q "^Origin:"; then
                    check PASS "Header 'Origin' ($component/$arch)" ""
                else
                    check FAIL "Header 'Origin' ($component/$arch)" "Missing"
                fi

                if echo "$yaml_head" | grep -q "^MediaBaseUrl:"; then
                    check PASS "Header 'MediaBaseUrl' ($component/$arch)" ""
                else
                    check WARN "Header 'MediaBaseUrl' ($component/$arch)" "Missing (remote icons may not load)"
                fi
            done
        done

        # ---- 5. Release signature ----
        print_section "5. Release Signature"

        gpg_status=$(fetch_status "$SUITE_URL/Release.gpg")
        if [[ "$gpg_status" == "200" ]]; then
            check PASS "Release.gpg exists" ""
        else
            check FAIL "Release.gpg exists" "HTTP $gpg_status $SUITE_URL/Release.gpg"
        fi

        inrelease_status=$(fetch_status "$SUITE_URL/InRelease")
        if [[ "$inrelease_status" == "200" ]]; then
            check PASS "InRelease exists" ""
        else
            check FAIL "InRelease exists" "HTTP $inrelease_status $SUITE_URL/InRelease"
        fi

    else
        # ==================================================================
        # FULL MODE — all checks
        # ==================================================================

        # ---- 2. DEP-11 directory structure ----
        print_section "2. DEP-11 Directory Structure"

        for component in $COMPONENTS; do
            dep11_url="$SUITE_URL/$component/dep11/"
            status=$(fetch_status "$dep11_url")
            if [[ "$status" == "200" ]]; then
                check PASS "dep11/ directory exists for '$component'" ""
            else
                check FAIL "dep11/ directory exists for '$component'" "HTTP $status $dep11_url"
            fi
        done

        # ---- 3. Required DEP-11 files ----
        print_section "3. DEP-11 Metadata Files"

        for component in $COMPONENTS; do
            dep11_url="$SUITE_URL/$component/dep11"
            for arch in $ARCHITECTURES; do

                # Components YAML (compressed gz)
                f_url="$dep11_url/Components-${arch}.yml.gz"
                f_size=$(fetch_size "$f_url")
                status=$(fetch_status "$f_url")
                if [[ "$status" == "200" ]]; then
                    check PASS "Components-${arch}.yml.gz ($component)" "${f_size} bytes"
                else
                    check FAIL "Components-${arch}.yml.gz ($component)" "HTTP $status $f_url"
                fi

                # Components YAML (compressed xz)
                f_url="$dep11_url/Components-${arch}.yml.xz"
                status=$(fetch_status "$f_url")
                if [[ "$status" == "200" ]]; then
                    check PASS "Components-${arch}.yml.xz ($component)" ""
                else
                    check WARN "Components-${arch}.yml.xz ($component)" "HTTP $status $f_url (optional)"
                fi

                # Components YAML (uncompressed)
                f_url="$dep11_url/Components-${arch}.yml"
                status=$(fetch_status "$f_url")
                if [[ "$status" == "200" ]]; then
                    check PASS "Components-${arch}.yml uncompressed ($component)" ""
                else
                    check WARN "Components-${arch}.yml uncompressed ($component)" "HTTP $status $f_url (APT may need this)"
                fi

                # CID-Index
                f_url="$dep11_url/CID-Index-${arch}.json.gz"
                status=$(fetch_status "$f_url")
                if [[ "$status" == "200" ]]; then
                    check PASS "CID-Index-${arch}.json.gz ($component)" ""
                else
                    check WARN "CID-Index-${arch}.json.gz ($component)" "HTTP $status $f_url (optional)"
                fi

                # Icon tarballs
                dep11_listing="$TMPDIR/${suite}_${component}_dep11.html"
                icon_count=0
                if fetch "$dep11_url/" "$dep11_listing"; then
                    icon_count=$(grep -coP 'icons-[^"]*\.tar\.gz' "$dep11_listing" || true)
                fi
                if [[ $icon_count -gt 0 ]]; then
                    check PASS "Icon tarballs ($component)" "$icon_count file(s)"
                else
                    check WARN "Icon tarballs ($component)" "None found"
                fi
            done
        done

        # ---- 4. DEP-11 YAML content validation ----
        print_section "4. DEP-11 YAML Content Validation"

        for component in $COMPONENTS; do
            dep11_url="$SUITE_URL/$component/dep11"
            for arch in $ARCHITECTURES; do
                yml_gz="$TMPDIR/${suite}_${component}_${arch}.yml.gz"
                if ! fetch "$dep11_url/Components-${arch}.yml.gz" "$yml_gz"; then
                    check FAIL "YAML content ($component/$arch)" "Cannot fetch $dep11_url/Components-${arch}.yml.gz"
                    continue
                fi

                # Use streaming (zcat | head/grep) instead of storing
                # entire decompressed content in a bash variable, which
                # fails for large files (18MB+).
                yaml_size=$(zcat "$yml_gz" 2>/dev/null | wc -c || true)
                if [[ "$yaml_size" -eq 0 ]]; then
                    check FAIL "YAML content is non-empty ($component/$arch)" "Empty or corrupt"
                    continue
                fi
                check PASS "YAML content is non-empty ($component/$arch)" ""

                # Read only the header (first 20 lines) for field checks
                yaml_head="$(zcat "$yml_gz" 2>/dev/null | head -20)"

                # Header: File field
                if echo "$yaml_head" | grep -q '^File: DEP-11'; then
                    check PASS "YAML header 'File: DEP-11' ($component/$arch)" ""
                else
                    check FAIL "YAML header 'File: DEP-11' ($component/$arch)" "Missing"
                fi

                # Header: Version field
                if echo "$yaml_head" | grep -q "^Version:"; then
                    check PASS "YAML header 'Version' ($component/$arch)" ""
                else
                    check FAIL "YAML header 'Version' ($component/$arch)" "Missing"
                fi

                # Header: Origin field
                if echo "$yaml_head" | grep -q "^Origin:"; then
                    check PASS "YAML header 'Origin' ($component/$arch)" ""
                else
                    check FAIL "YAML header 'Origin' ($component/$arch)" "Missing"
                fi

                # Header: MediaBaseUrl field
                if echo "$yaml_head" | grep -q "^MediaBaseUrl:"; then
                    check PASS "YAML header 'MediaBaseUrl' ($component/$arch)" ""
                else
                    check WARN "YAML header 'MediaBaseUrl' ($component/$arch)" "Missing (needed for icons)"
                fi

                # Count components (stream directly from file)
                comp_count=$(zcat "$yml_gz" 2>/dev/null | grep -c '^Type:' || true)
                if [[ $comp_count -gt 0 ]]; then
                    check PASS "Component entries found ($component/$arch)" "$comp_count component(s)"
                else
                    check WARN "Component entries found ($component/$arch)" "None"
                fi

                # Required fields per component (stream directly from file)
                if [[ $comp_count -gt 0 ]]; then
                    has_id=$(zcat "$yml_gz" 2>/dev/null | grep -c '^ID:' || true)
                    has_pkg=$(zcat "$yml_gz" 2>/dev/null | grep -c '^Package:' || true)
                    has_name=$(zcat "$yml_gz" 2>/dev/null | grep -c '^Name:' || true)
                    has_summary=$(zcat "$yml_gz" 2>/dev/null | grep -c '^Summary:' || true)

                    if [[ $has_id -ge $comp_count ]]; then
                        check PASS "All components have 'ID' ($component/$arch)" ""
                    else
                        check FAIL "All components have 'ID' ($component/$arch)" "$has_id/$comp_count"
                    fi

                    if [[ $has_pkg -ge $comp_count ]]; then
                        check PASS "All components have 'Package' ($component/$arch)" ""
                    else
                        check FAIL "All components have 'Package' ($component/$arch)" "$has_pkg/$comp_count"
                    fi

                    if [[ $has_name -ge $comp_count ]]; then
                        check PASS "All components have 'Name' ($component/$arch)" ""
                    else
                        check FAIL "All components have 'Name' ($component/$arch)" "$has_name/$comp_count"
                    fi

                    if [[ $has_summary -ge $comp_count ]]; then
                        check PASS "All components have 'Summary' ($component/$arch)" ""
                    else
                        check WARN "All components have 'Summary' ($component/$arch)" "$has_summary/$comp_count"
                    fi
                fi
            done
        done

        # ---- 5. Release file DEP-11 entries ----
        print_section "5. Release File DEP-11 Entries"

        for section in MD5Sum SHA1 SHA256; do
            dep11_lines=$(sed -n "/^${section}:/,/^[A-Z]/{/dep11/p}" "$RELEASE_FILE" | wc -l)
            if [[ $dep11_lines -gt 0 ]]; then
                check PASS "DEP-11 entries in $section section" "$dep11_lines entry(ies)"
            else
                check FAIL "DEP-11 entries in $section section" "None found"
            fi
        done

        # ---- 6. Checksum integrity ----
        print_section "6. Checksum Integrity (SHA256)"

        mismatch=0
        checked=0

        while IFS= read -r line; do
            expected_hash=$(echo "$line" | awk '{print $1}')
            expected_size=$(echo "$line" | awk '{print $2}')
            relpath=$(echo "$line" | awk '{print $3}')

            file_url="$SUITE_URL/$relpath"
            dest="$TMPDIR/${suite}_$(echo "$relpath" | tr '/' '_')"

            if ! fetch "$file_url" "$dest"; then
                check FAIL "Fetch: $relpath" "HTTP error $file_url"
                mismatch=$((mismatch + 1))
                checked=$((checked + 1))
                continue
            fi

            actual_size=$(stat --format='%s' "$dest")
            actual_hash=$(sha256sum "$dest" | awk '{print $1}')

            if [[ "$expected_hash" != "$actual_hash" ]]; then
                check FAIL "SHA256: $relpath" "Mismatch"
                mismatch=$((mismatch + 1))
            elif [[ "$expected_size" != "$actual_size" ]]; then
                check FAIL "Size: $relpath" "Expected $expected_size, got $actual_size"
                mismatch=$((mismatch + 1))
            else
                check PASS "Verified: $relpath" "${actual_size} bytes"
            fi
            checked=$((checked + 1))

        done < <(sed -n '/^SHA256:/,/^[A-Z]/{/dep11/p}' "$RELEASE_FILE")

        if [[ $checked -eq 0 ]]; then
            check WARN "Checksum verification" "No dep11 entries in SHA256 section"
        elif [[ $mismatch -eq 0 ]]; then
            check PASS "All DEP-11 checksums verified" "$checked file(s)"
        fi

        # ---- 7. Release file signatures ----
        print_section "7. Release File Signatures"

        RELEASE_GPG="$TMPDIR/${suite}_Release.gpg"
        status=$(fetch_status "$SUITE_URL/Release.gpg")
        if [[ "$status" == "200" ]]; then
            check PASS "Detached signature (Release.gpg) exists" ""
            if fetch "$SUITE_URL/Release.gpg" "$RELEASE_GPG" && command -v gpg &>/dev/null; then
                if gpg --verify "$RELEASE_GPG" "$RELEASE_FILE" 2>/dev/null; then
                    check PASS "Release.gpg signature is valid" ""
                else
                    check WARN "Release.gpg signature is valid" "Key not in keyring"
                fi
            fi
        else
            check FAIL "Detached signature (Release.gpg) exists" "HTTP $status $SUITE_URL/Release.gpg"
        fi

        INRELEASE="$TMPDIR/${suite}_InRelease"
        status=$(fetch_status "$SUITE_URL/InRelease")
        if [[ "$status" == "200" ]]; then
            check PASS "Clearsigned Release (InRelease) exists" ""
            if fetch "$SUITE_URL/InRelease" "$INRELEASE" && command -v gpg &>/dev/null; then
                if gpg --verify "$INRELEASE" 2>/dev/null; then
                    check PASS "InRelease signature is valid" ""
                else
                    check WARN "InRelease signature is valid" "Key not in keyring"
                fi
            fi
        else
            check FAIL "Clearsigned Release (InRelease) exists" "HTTP $status $SUITE_URL/InRelease"
        fi
    fi

done

# ============================================================================
# APT Integration Test
# ============================================================================

if [[ ${#CHECKED_SUITES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}APT Integration Test${NC}"
    echo -e "${BOLD}====================${NC}"
    printf "\n  %-8s %-60s %s\n" "STATUS" "CHECK" "DETAILS"
    printf "  %-8s %-60s %s\n" "------" "-----" "-------"

    # Convert repo URL to APT list file prefix
    # http://arsip-dev.blankonlinux.id/dev → arsip-dev.blankonlinux.id_dev
    APT_PREFIX="$(echo "$REPO_URL" | sed 's|^https\?://||' | sed 's|/|_|g' | sed 's|_$||')"
    APT_LISTS="/var/lib/apt/lists"

    # ---- Check if repo is in APT sources ----
    print_section "1. APT Source Configuration"

    REPO_HOST="$(echo "$REPO_URL" | sed 's|^https\?://||' | cut -d/ -f1)"
    sources_found=false
    for src in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        if [[ -f "$src" ]] && grep -q "$REPO_HOST" "$src" 2>/dev/null; then
            sources_found=true
            check PASS "Repository found in APT sources" "$src"
            break
        fi
    done
    if ! $sources_found; then
        check FAIL "Repository found in APT sources" "Add it to /etc/apt/sources.list"
    fi

    # ---- Run sudo apt update ----
    print_section "2. APT Update"

    apt_update_ok=false
    if $sources_found; then
        echo -e "  Running ${BOLD}sudo apt update${NC}..."
        apt_output="$TMPDIR/apt_update.log"
        if sudo -n apt update > "$apt_output" 2>&1; then
            check PASS "sudo apt update succeeded" ""
            apt_update_ok=true

            # Show DEP-11 related lines from apt update output
            dep11_fetched=$(grep -ciE "dep11|Components-|icons-.*\.tar" "$apt_output" || true)
            if [[ $dep11_fetched -gt 0 ]]; then
                check PASS "APT fetched DEP-11 metadata" "$dep11_fetched item(s)"
            else
                check WARN "APT fetched DEP-11 metadata" "No DEP-11 lines in apt update output"
            fi
        else
            apt_rc=$?
            apt_err="$(tail -2 "$apt_output" 2>/dev/null | tr '\n' ' ')"
            if [[ $apt_rc -eq 1 ]] && grep -q "password is required" "$apt_output" 2>/dev/null; then
                check WARN "sudo apt update" "Requires password (run manually: sudo apt update)"
            else
                check FAIL "sudo apt update succeeded" "Exit code $apt_rc — $apt_err"
            fi
        fi
    else
        check WARN "sudo apt update" "Skipped (repo not in APT sources)"
    fi

    # ---- Check DEP-11 files in /var/lib/apt/lists/ ----
    if $apt_update_ok; then
        print_section "3. DEP-11 Files in APT Lists ($APT_LISTS)"
    else
        print_section "3. DEP-11 Files in APT Lists ($APT_LISTS) [cached state]"
    fi

    for suite in "${CHECKED_SUITES[@]}"; do
        components="${SUITE_COMPONENTS[$suite]}"
        architectures="${SUITE_ARCHITECTURES[$suite]}"

        for component in $components; do
            for arch in $architectures; do
                # Components YAML — the essential DEP-11 file
                # APT KeepCompressedAs "gz", so expect .yml.gz or .yml
                list_file_base="${APT_PREFIX}_dists_${suite}_${component}_dep11_Components-${arch}.yml"
                found_yml=false
                for ext in "" ".gz" ".xz" ".lz4"; do
                    if [[ -f "$APT_LISTS/${list_file_base}${ext}" ]]; then
                        found_yml=true
                        fsize=$(stat --format='%s' "$APT_LISTS/${list_file_base}${ext}")
                        check PASS "Components-${arch}.yml ($suite/$component)" "${list_file_base}${ext} (${fsize} bytes)"
                        break
                    fi
                done
                if ! $found_yml; then
                    if $apt_update_ok; then
                        check FAIL "Components-${arch}.yml ($suite/$component)" "Not in $APT_LISTS/${list_file_base}*"
                    else
                        check WARN "Components-${arch}.yml ($suite/$component)" "Not in $APT_LISTS/ (run: sudo apt update)"
                    fi
                fi
            done

            # Icon tarballs (48x48 and 64x64 — enabled by 60icons for GNOME Software)
            for icon_name in "icons-48x48" "icons-64x64"; do
                list_file_base="${APT_PREFIX}_dists_${suite}_${component}_dep11_${icon_name}.tar"
                found_icon=false
                for ext in "" ".gz" ".xz" ".lz4"; do
                    if [[ -f "$APT_LISTS/${list_file_base}${ext}" ]]; then
                        found_icon=true
                        fsize=$(stat --format='%s' "$APT_LISTS/${list_file_base}${ext}")
                        check PASS "${icon_name}.tar ($suite/$component)" "${list_file_base}${ext} (${fsize} bytes)"
                        break
                    fi
                done
                if ! $found_icon; then
                    check WARN "${icon_name}.tar ($suite/$component)" "Not in $APT_LISTS/${list_file_base}*"
                fi
            done
        done
    done

    # ---- Check appstreamcli / swcatalog ----
    print_section "4. AppStream Cache (GNOME Software readiness)"

    if command -v appstreamcli &>/dev/null; then
        check PASS "appstreamcli is installed" "$(appstreamcli --version 2>&1 | head -1)"

        # Refresh the appstream cache
        if $apt_update_ok; then
            echo -e "  Running ${BOLD}sudo appstreamcli refresh --force${NC}..."
            if sudo -n appstreamcli refresh --force > /dev/null 2>&1; then
                check PASS "appstreamcli refresh succeeded" ""
            else
                check WARN "appstreamcli refresh succeeded" "Exit code $? (run: sudo appstreamcli refresh --force)"
            fi
        else
            check WARN "appstreamcli refresh" "Skipped (apt update not run)"
        fi

        # Check swcatalog cache files
        SWCATALOG="/var/cache/swcatalog/cache"
        if [[ -d "$SWCATALOG" ]]; then
            catalog_count=$(find "$SWCATALOG" -name "*-os-catalog.xb" 2>/dev/null | wc -l)
            if [[ $catalog_count -gt 0 ]]; then
                check PASS "AppStream catalog cache exists" "$catalog_count file(s) in $SWCATALOG"
            else
                check FAIL "AppStream catalog cache exists" "No os-catalog.xb files in $SWCATALOG"
            fi
        else
            check FAIL "AppStream catalog cache directory" "$SWCATALOG not found"
        fi

        # Check icon directories from this repo's origins
        SWICONS="/var/lib/swcatalog/icons"
        if [[ -d "$SWICONS" ]]; then
            for suite in "${CHECKED_SUITES[@]}"; do
                components="${SUITE_COMPONENTS[$suite]}"
                for component in $components; do
                    # appstreamcli uses Origin from YAML header as icon dir name
                    # Try common naming patterns
                    icon_dir_found=false
                    for pattern in "$SWICONS"/*-${suite}-${component}; do
                        if [[ -d "$pattern" ]]; then
                            icon_count=$(find "$pattern" -type f 2>/dev/null | wc -l)
                            check PASS "Icon cache ($suite/$component)" "$(basename "$pattern")/ ($icon_count file(s))"
                            icon_dir_found=true
                            break
                        fi
                    done
                    if ! $icon_dir_found; then
                        check WARN "Icon cache ($suite/$component)" "No icon dir matching *-${suite}-${component} in $SWICONS"
                    fi
                done
            done
        else
            check WARN "Icon cache directory" "$SWICONS not found"
        fi

        # Try searching for a component to verify end-to-end
        # Pick the first component ID from the first suite's main YAML
        first_suite="${CHECKED_SUITES[0]}"
        first_arch="${SUITE_ARCHITECTURES[$first_suite]%% *}"
        yml_gz="$TMPDIR/${first_suite}_main_${first_arch}.yml.gz"
        if [[ -f "$yml_gz" ]]; then
            sample_id=$(zcat "$yml_gz" 2>/dev/null | grep '^ID:' | head -1 | sed 's/^ID:[[:space:]]*//')
            if [[ -n "$sample_id" ]]; then
                search_result=$(appstreamcli get "$sample_id" 2>/dev/null | head -1)
                if [[ -n "$search_result" ]]; then
                    check PASS "appstreamcli can find components" "$sample_id"
                elif $apt_update_ok; then
                    check FAIL "appstreamcli can find components" "'appstreamcli get $sample_id' returned nothing"
                else
                    check WARN "appstreamcli can find components" "Cache may be stale (run: sudo apt update && sudo appstreamcli refresh --force)"
                fi
            fi
        fi
    else
        check FAIL "appstreamcli is installed" "Install the 'appstream' package"
    fi
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo -e "${BOLD}Summary${NC}"
echo -e "${BOLD}=======${NC}"
echo -e "  Total checks: $TOTAL"
echo -e "  ${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "  ${RED}Failed: $FAIL_COUNT${NC}"
echo -e "  ${YELLOW}Warnings: $WARN_COUNT${NC}"
echo ""
if [[ $FAIL_COUNT -eq 0 ]]; then
    if $ESSENTIAL; then
        echo -e "  ${GREEN}${BOLD}GNOME Software can load appstream metadata from this repository.${NC}"
    else
        echo -e "  ${GREEN}${BOLD}Repository is compatible with DEP-11 appstream metadata.${NC}"
    fi
else
    if $ESSENTIAL; then
        echo -e "  ${RED}${BOLD}GNOME Software cannot fully load appstream metadata ($FAIL_COUNT issue(s)).${NC}"
    else
        echo -e "  ${RED}${BOLD}Repository has $FAIL_COUNT issue(s) that must be fixed for DEP-11 compatibility.${NC}"
    fi
fi
echo ""

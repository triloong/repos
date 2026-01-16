#!/bin/bash

set -u
set -e
set -o pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <outlog>"
    exit 1
fi

outlog=$1
db_dir="$REPREPRO_BASE_DIR/db"

error() {
    echo "$*"
    exit 1
}

# Close stdin to prevent commands from waiting for input
exec </dev/null

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

sqlite3 "$tmpfile" <<EOF
CREATE TABLE existing_files (
    codename TEXT,
    hash_file_name TEXT,
    removed_at INTEGER,
    CONSTRAINT unique_hash_file_name UNIQUE (codename, hash_file_name) ON CONFLICT REPLACE
);
CREATE TABLE distributions (
    codename TEXT
);
EOF

exec 4<>"$db_dir/by-hash-files.sql.lock"
flock --verbose 4

if [ -e "$db_dir/by-hash-files.sql" ]; then
    sqlite3 "$tmpfile" < "$db_dir/by-hash-files.sql"
fi

dists=()

hash_types=("SHA256" "SHA1" "MD5Sum")

while IFS= read -r line; do
    dists+=("$line")
    printf "%s\036" "$line" | \
        sqlite3 "$tmpfile" '.import --ascii /dev/stdin distributions'
done < <(grep "^BEGIN-DISTRIBUTION" "$outlog" | awk '{print $2}')

sqlite3 "$tmpfile" 'UPDATE existing_files SET removed_at = 0 WHERE removed_at = -1 and codename IN (SELECT codename FROM distributions);'

sym_link_sources=()
sym_link_dests=()

echo "Creating by-hash hard links..." >&2

for dist in "${dists[@]}"; do
    if ! [ -e "$REPREPRO_DIST_DIR/$dist/Release" ]; then
        error "Cannot find Release file for distribution '$dist' in '$REPREPRO_DIST_DIR/$dist/Release'"
    fi
    for hash_type in "${hash_types[@]}"; do
        while IFS=" " read -r hash_value file_name; do
            case "$file_name" in
		*Components-*.yml | *icons-*.tar ) continue ;;
                *Translation-* | *Contents-* | *Index* | *Packages* | *Sources* | *Components* | *icons-* | *Release ) ;;
                *) continue ;;
            esac
            this_file="$REPREPRO_DIST_DIR/$dist/$file_name"
            if [ ! -e "$this_file" ]; then
                continue
            fi
            if [ ! -f "$this_file" ]; then
                error "'$this_file' is not a regular file"
            fi
            if [ -L "$this_file" ]; then
                error "'$this_file' is a symbolic link"
            fi
            target_file="$(dirname -- "$file_name")/by-hash/$hash_type/$hash_value"
            mkdir -p "$REPREPRO_OUT_DIR/dists/$dist/$(dirname -- "$target_file")"
            ln -T -v -f "$this_file" "$REPREPRO_OUT_DIR/dists/$dist/$target_file"
            printf "%s\037%s\037-1\036" "$dist" "$target_file" | \
                sqlite3 "$tmpfile" '.import --ascii /dev/stdin existing_files'
            if [ "$hash_type" = "${hash_types[0]}" ]; then
                target_dist_file="$REPREPRO_OUT_DIR/dists/$dist/$file_name"
                mkdir -p "$(dirname -- "$target_dist_file")"
                sym_link_sources+=("by-hash/$hash_type/$hash_value")
                sym_link_dests+=("$target_dist_file")
            fi
        done < <(   grep-dctrl -F "" "" -s "$hash_type" -n "$REPREPRO_DIST_DIR/$dist/Release" | \
                    cut -d' ' -f 2,4 | \
                    grep -v "^$" )
    done
done

link_if_changed() {
    local src=$1
    local dest=$2
    if [ -L "$dest" ]; then
        local current_src
        current_src=$(readlink "$dest")
        if [ "$current_src" = "$src" ]; then
            echo "Link unchanged: $dest -> $src" >&2
            return
        fi
    fi
    ln -s -v -T -f "$src" "$dest"
}

gpg_opts=(
    --no-options --no-tty --batch --armor --personal-digest-preferences SHA256
    --homedir "$GNUPGHOME"
)

mv_files=()

for dist in "${dists[@]}"; do
    mkdir -p "$REPREPRO_OUT_DIR/zzz-dists/$dist"
    cp -a "$REPREPRO_DIST_DIR/$dist/Release" "$REPREPRO_OUT_DIR/zzz-dists/$dist/Release.new"
    echo "Acquire-By-Hash: yes" >> "$REPREPRO_OUT_DIR/zzz-dists/$dist/Release.new"
    if ! signwith=$(grep-dctrl -X -F "Codename" "$dist" -s "SignWith" -n "$REPREPRO_CONFIG_DIR/distributions"); then
        error "Cannot find distribution '$dist' in '$REPREPRO_CONFIG_DIR/distributions' to get SignWith"
    fi
    mv_files+=("$REPREPRO_OUT_DIR/zzz-dists/$dist/Release")
    sym_link_sources+=("../../zzz-dists/$dist/Release")
    sym_link_dests+=("$REPREPRO_OUT_DIR/dists/$dist/Release")
    if [ -n "$signwith" ]; then
        (
            for keyid in $signwith; do
                gpg_opts+=(--local-user "$keyid")
            done
            echo "Signing Release file for distribution '$dist' with key(s): $signwith" >&2
            gpg "${gpg_opts[@]}" --clearsign < "$REPREPRO_OUT_DIR/zzz-dists/$dist/Release.new" > "$REPREPRO_OUT_DIR/zzz-dists/$dist/InRelease.new"
            gpg "${gpg_opts[@]}" --detach-sign < "$REPREPRO_OUT_DIR/zzz-dists/$dist/Release.new" > "$REPREPRO_OUT_DIR/zzz-dists/$dist/Release.gpg.new"
        )
        mv_files+=("$REPREPRO_OUT_DIR/zzz-dists/$dist/InRelease")
        mv_files+=("$REPREPRO_OUT_DIR/zzz-dists/$dist/Release.gpg")
        sym_link_sources+=("../../zzz-dists/$dist/InRelease")
        sym_link_dests+=("$REPREPRO_OUT_DIR/dists/$dist/InRelease")
        sym_link_sources+=("../../zzz-dists/$dist/Release.gpg")
        sym_link_dests+=("$REPREPRO_OUT_DIR/dists/$dist/Release.gpg")
    fi
done

echo 'Creating symbolic links for non-hash paths...' >&2

for i in "${!sym_link_sources[@]}"; do
    link_if_changed "${sym_link_sources[$i]}" "${sym_link_dests[$i]}"
done

echo 'Moving new Release and signature files into place...' >&2

for file in "${mv_files[@]}"; do
    mv -v "$file.new" "$file"
done

sqlite3 --ascii "$tmpfile" 'select codename, hash_file_name from existing_files where removed_at >= 0 and codename IN (SELECT codename FROM distributions);' | \
    while IFS=$'\037' read -d $'\036' codename hash_file_name; do
        target_file="$REPREPRO_OUT_DIR/dists/$codename/$hash_file_name"
        echo "Obsolete: $target_file" >&2
    done

sqlite3 "$tmpfile" 'update existing_files set removed_at = unixepoch() where removed_at = 0;'
sqlite3 --ascii "$tmpfile" 'delete from existing_files where removed_at < unixepoch() - 86400 and removed_at >= 0 and codename IN (SELECT codename FROM distributions) returning codename, hash_file_name;' | \
    while IFS=$'\037' read -d $'\036' codename hash_file_name; do
        target_file="$REPREPRO_OUT_DIR/dists/$codename/$hash_file_name"
        echo "Removing: $target_file" >&2
        rm -f "$target_file"
    done

sqlite3 "$tmpfile" '.dump --data-only existing_files' > "$db_dir/by-hash-files.sql.tmp"
mv "$db_dir/by-hash-files.sql.tmp" "$db_dir/by-hash-files.sql"

flock -u 4
rm -f "$outlog"

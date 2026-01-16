#!/bin/bash

set -e
set -o pipefail
set -u

shopt -s extglob

reprepro_cmd() {
    reprepro --export=silent-never --keepunreferencedfiles "$@"
}

check_source() {
    local codename="$1"
    local source_pkg="$2"
    local source_ver="$3"

    local matching=$(reprepro_cmd listfilter "$codename" "\$source(==$source_pkg), \$sourceversion(==$source_ver)" | wc -l)
    if [[ "$matching" -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

reprepro_move_source() {
    local to_codename="$1"
    local from_codename="$2"
    local source_pkg="$3"
    local source_ver="$4"
    reprepro_cmd copysrc "$to_codename" "$from_codename" "$source_pkg" "$source_ver" || return $?
    reprepro_cmd removesrc "$from_codename" "$source_pkg" "$source_ver"
}

handle_update() {
    local suite="$1"
    shift
    local arch="$1"
    local source_pkg="$2"
    local source_ver_old="$3"
    local source_ver_new="$4"

    local from_codename="${suite}-proposed-updates"
    local to_codename="$suite"

    if ! check_source "$from_codename" "$source_pkg" "$source_ver_new"; then
        echo "Source package $source_pkg version $source_ver_old not found in $from_codename" >&2
        return 1
    fi
    if ! check_source "$to_codename" "$source_pkg" "$source_ver_old"; then
        echo "Source package $source_pkg version $source_ver_old not found in $to_codename" >&2
        return 1
    fi
    reprepro_move_source "$to_codename" "$from_codename" "$source_pkg" "$source_ver_new"
}

handle_delete() {
    local suite="$1"
    shift
    local arch="$1"
    local source_pkg="$2"
    local source_ver="$3"

    if ! check_source "$suite" "$source_pkg" "$source_ver"; then
        echo "Source package $source_pkg version $source_ver not found in $suite" >&2
        return 1
    fi
    reprepro_cmd removesrc "$suite" "$source_pkg" "$source_ver"
}

handle_new() {
    local suite="$1"
    shift
    local arch="$1"
    local source_pkg="$2"
    local source_ver="$3"

    local from_codename="${suite}-proposed-updates"
    local to_codename="$suite"

    if ! check_source "$from_codename" "$source_pkg" "$source_ver"; then
        echo "Source package $source_pkg version $source_ver not found in $from_codename" >&2
        return 1
    fi
    reprepro_move_source "$to_codename" "$from_codename" "$source_pkg" "$source_ver"
}

declare -A binNMU_handled=()
handle_binNMU() {
    local suite="$1"
    shift
    local arch="$1"
    local source_pkg="$2"
    local source_ver="$3"
    local old_binNMU="$4"
    local new_binNMU="$5"

    local from_codename="${suite}-proposed-updates"
    local to_codename="$suite"

    if [[ "${binNMU_handled[${source_pkg}]:-}" = "${source_ver}" ]]; then
        return 0
    elif [[ -n "${binNMU_handled[${source_pkg}]:-}" ]]; then
        echo "BinNMU for source package $source_pkg version ${source_ver} already handled" >&2
        return 1
    fi

    if ! check_source "$from_codename" "$source_pkg" "$source_ver"; then
        echo "Source package $source_pkg version $source_ver not found in $from_codename" >&2
        return 1
    fi
    if ! check_source "$to_codename" "$source_pkg" "$source_ver"; then
        echo "Source package $source_pkg version $source_ver not found in $to_codename" >&2
        return 1
    fi
    reprepro_move_source "$to_codename" "$from_codename" "$source_pkg" "$source_ver" || return $?
    binNMU_handled[$source_pkg]="${source_ver}"
}

failed_cmds=()
handle_inst() {
    local suite="$1"
    shift
    local cmd="$1"
    shift
    local handler=""
    case "$cmd" in
        update)
            handler="handle_update"
            ;;
        delete)
            handler="handle_delete"
            ;;
        new)
            handler="handle_new"
            ;;
        binNMU)
            handler="handle_binNMU"
            ;;
        *)
            handler="false"
            ;;
    esac
    if ! "$handler" "$suite" "$@"; then
        failed_cmds+=("$cmd $*")
    fi
}

suite="$1"

line=()

#exec 4<>repo.lock
#flock --verbose 4

while read -r -a line; do
    handle_inst "$suite" "${line[@]}"
done

#flock -u 4

if [ "${#failed_cmds[@]}" -gt 0 ]; then
    echo "The following commands failed:" >&2
    for cmd in "${failed_cmds[@]}"; do
        echo "$cmd" >&2
    done
    exit 1
fi

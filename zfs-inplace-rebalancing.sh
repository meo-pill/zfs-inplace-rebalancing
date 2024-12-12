#!/usr/bin/env bash

# exit script on error
set -e
# exit on undeclared variable
set -u

# processed files database runtime variables
rebalance_db_file_name="rebalance.db"

# keeps changes before these are persisted to the database
rebalance_db_cache=''           #database filename
rebalance_db_save_interval=60   # how often changes are persisted to the database in seconds
rebalance_db_last_save=$SECONDS # when the database was last persisted

# index used for progress
current_index=0

# temporary file extension
tmp_extension=".balance"

# temporary files used for checksum comparison
file_hash_original="" # original file hash
file_hash_copy=""     # copy file hash

## Color Constants

# Reset
Color_Off='\033[0m' # Text Reset

# Regular Colors
Red='\033[0;31m'    # Red
Green='\033[0;32m'  # Green
Yellow='\033[0;33m' # Yellow
Cyan='\033[0;36m'   # Cyan

# loop boolean
loop=true

## Signal Handling

# handler for SIGINT
function sigint_handler() {
    echo "Caught SIGINT, exiting..."
    loop=false
}

# register SIGINT handler
trap sigint_handler SIGINT

## Functions

# print a help message
function print_usage() {
    echo "Usage: zfs-inplace-rebalancing --checksum true --skip-hardlinks false --passes 1 /my/pool"
}

# print a given text entirely in a given color
function color_echo() {
    color=$1
    text=$2
    echo -e "${color}${text}${Color_Off}"
}

# Loads existing rebalance database, or creates a new one. Requires no parameters.
function init_database() {
    if [[ "${passes_flag}" -le 0 ]]; then
        echo "skipped (--passes <= 0 requested)"
        return
    fi

    if [[ ! -r "${rebalance_db_file_name}" ]]; then # database unreadable => either no db or no permissions
        # try to create a new db - if this is a permission problem this will crash [as intended]
        sqlite3 "${rebalance_db_file_name}" "CREATE TABLE balancing (file string primary key, passes integer)"
        echo "initialized in ${rebalance_db_file_name}"
    else # db is readable - do a simple sanity check to make sure it isn't broken/locked
        local balanced
        balanced=$(sqlite3 "${rebalance_db_file_name}" "SELECT COUNT(*) FROM balancing")
        echo "found ${balanced} records in ${rebalance_db_file_name}"
    fi
}

# Strips single quotes, apostrophes and escapes slashes in a given string
# Use: stripp "string"
# Output: a string with single quotes and apostrophes removed and slashes escaped
function stripp() {
    return=${1//\'/}        # remove single quotes
    return=${return//’/}    # remove aphostrophes
    echo "${return//\//\\}" # escape slashes
}

# Provides number of already completed balancing passes for a given file
# Use: get_rebalance_count "/path/to/file"
# Output: a non-negative integer
function get_rebalance_count() {
    escaped_file_path=$(stripp "$1")
    local count
    count=$(sqlite3 "${rebalance_db_file_name}" "SELECT passes FROM balancing WHERE file = '${escaped_file_path}'")
    echo "${count:-0}"
}

function persist_database() {
    color_echo "${Cyan}" "Flushing database changes..."
    sqlite3 "${rebalance_db_file_name}" <<<"BEGIN TRANSACTION;${rebalance_db_cache};COMMIT;"
    rebalance_db_cache=''
    rebalance_db_last_save=$SECONDS
}

# Sets number of completed balancing passes for a given file
# Use: set_rebalance_count "/path/to/file" 123
function set_rebalance_count() {
    escaped_file_path=$(stripp "$1")
    rebalance_db_cache="${rebalance_db_cache};INSERT OR REPLACE INTO balancing VALUES('${escaped_file_path}', $2);"
    color_echo "${Green}" "File $1 completed $2 rebalance cycles"

    # this is slightly "clever", as there's no way to access monotonic time in shell.
    # $SECONDS contains a wall clock time since shell starting, but it's affected
    #  by timezones and system time changes. "time_since_last" will calculate absolute
    #  difference since last DB save. It may not be correct, but unless the time
    #  changes constantly, it will save *at least* every $rebalance_db_save_time
    local time_now=$SECONDS
    local time_since_last=$(($time_now >= $rebalance_db_last_save ? $time_now - $rebalance_db_last_save : $rebalance_db_last_save - $time_now))
    if [[ $time_since_last -gt $rebalance_db_save_interval ]]; then
        persist_database
    fi
}

# Rebalance a specific file
# Use: rebalance "/path/to/file"
# Output: log lines
function rebalance() {
    local file_path
    file_path=$1

    # check if file has >=2 links in the case of --skip-hardlinks
    # this shouldn't be needed in the typical case of `find` only finding files with links == 1
    # but this can run for a long time, so it's good to double check if something changed
    if [[ "${skip_hardlinks_flag,,}" == "true"* ]]; then
        hardlink_count=$(stat -c "%h" "${file_path}")

        if [ "${hardlink_count}" -ge 2 ]; then
            echo "Skipping hard-linked file: ${file_path}"
            return
        fi
    fi

    current_index="$((current_index + 1))"
    progress_percent=$(printf '%0.2f' "$((current_index*10000/file_count))e-2")
    color_echo "${Cyan}" "Progress -- Files: ${current_index}/${file_count} (${progress_percent}%)"

    if [[ ! -f "${file_path}" ]]; then
        color_echo "${Yellow}" "File is missing, skipping: ${file_path}"
    fi

    if [[ "${passes_flag}" -ge 1 ]]; then
        # this count is reused later to update database
        local rebalance_count
        rebalance_count=$(get_rebalance_count "${file_path}")

        # check if target rebalance count is reached
        if [[ "${rebalance_count}" -ge "${passes_flag}" ]]; then
            color_echo "${Yellow}" "Rebalance count of ${passes_flag} reached (${rebalance_count}), skipping: ${file_path}"
            return
        fi
    fi

    tmp_file_path="${file_path}${tmp_extension}"

    echo "Copying '${file_path}' to '${tmp_file_path}'..."
    case "${OSTYPE,,}" in
    "linux-gnu"*)
        # Linux

        # -a -- keep attributes
        # -d -- keep symlinks (dont copy target)
        # -x -- stay on one system
        # -p -- preserve ACLs too
        cp -adxp "${file_path}" "${tmp_file_path}"
        ;;
    "darwin"* | "freebsd"*)
        # Mac OS
        # FreeBSD

        # -a -- Archive mode.  Same as -RpP.
        # -x -- File system mount points are not traversed.
        # -p -- Cause cp to preserve the following attributes of each source file
        #       in the copy: modification time, access time, file flags, file mode,
        #       ACL, user ID, and group ID, as allowed by permissions.
        cp -axp "${file_path}" "${tmp_file_path}"
        ;;
    *)
        echo "Unsupported OS type: $OSTYPE"
        exit 1
        ;;
    esac

    # compare copy against original to make sure nothing went wrong
    if [[ "${checksum_flag,,}" == "true"* ]]; then
        echo "Comparing copy against original..."
        # Use stat to get file attributes and metadata

        case "${OSTYPE,,}" in
        "linux-gnu"*)
            # Linux

            # save original and copy attributes
            # -c -- format
            # %A -- access rights in human readable form
            # %U -- user name of owner
            # %G -- group name of owner
            # %s -- size in bytes
            # %Y -- time of last data modification
            original_attrs=$(stat -c "%A %U %G %s %Y" "${file_path}")
            copy_attrs=$(stat -c "%A %U %G %s %Y" "${tmp_file_path}")

            # launch 2 md5sum processes in the background
            # one for the original file and one for the copy
            # the results are saved in temporary files (the file a save in the ram)
            # -b -- binary mode
            md5sum -b "${file_path}" >"${file_hash_original}" &
            pid1=$!
            md5sum -b "${tmp_file_path}" >"${file_hash_copy}" &
            pid2=$!
            ;;

        "freebsd"* | "darwin"*)
            # FreeBSD or Mac OS

            # save original and copy attributes
            # -f -- format
            # %Sp -- file type
            # %Su -- user name of owner
            # %Sg -- group name of owner
            # %z -- size in bytes
            # %m -- time of last data modification
            original_attrs=$(stat -f "%Sp %Su %Sg %z %m" "${file_path}")
            copy_attrs=$(stat -f "%Sp %Su %Sg %z %m" "${tmp_file_path}")

            # launch 2 md5 processes in the background
            # one for the original file and one for the copy
            # the results are saved in temporary files (the file is saved in the tmp folder with is normally in the ram)
            # -q -- quiet mode
            md5 -q "${file_path}" >"${file_hash_original}" &
            pid1=$!
            md5 -q "${tmp_file_path}" >"${file_hash_copy}" &
            pid2=$!
            ;;
        *)
            echo "Unsupported OS type: $OSTYPE"
            exit 1
            ;;
        esac

        # wait for both md5sum processes to finish
        wait $pid1
        wait $pid2

        # read the md5sum results from the temporary files
        # the use of read is preferred over cat for performance reasons and to avoid having to cut the output
        # (read only take to the first separator space/tab/newline)
        # -r -- raw input
        read -r original_hash <"${file_hash_original}"
        read -r copy_hash <"${file_hash_copy}"

        if [[ "${original_attrs}" == "${copy_attrs}" && "${original_hash}" == "${copy_hash}" ]]; then
            color_echo "${Green}" "MD5 OK"
        else
            color_echo "${Red}" "MD5 FAILED:"
            color_echo "${Red}" "  Original: ${original_attrs} ${original_hash}"
            color_echo "${Red}" "  Copy: ${copy_attrs} ${copy_hash}"
            exit 1
        fi
    fi

    echo "Removing original '${file_path}'..."
    rm "${file_path}"

    echo "Renaming temporary copy to original '${file_path}'..."
    mv "${tmp_file_path}" "${file_path}"

    if [ "${passes_flag}" -ge 1 ]; then
        set_rebalance_count "${file_path}" $((rebalance_count + 1))
    fi
}

checksum_flag='true'
skip_hardlinks_flag='false'
passes_flag='1'

if [[ "$#" -eq 0 ]]; then
    print_usage
    exit 0
fi

while true; do
    case "$1" in
    -h | --help)
        print_usage
        exit 0
        ;;
    -c | --checksum)
        if [[ "$2" == 1 || "$2" =~ (on|true|yes) ]]; then
            checksum_flag="true"
        else
            checksum_flag="false"
        fi
        shift 2
        ;;
    --skip-hardlinks)
        if [[ "$2" == 1 || "$2" =~ (on|true|yes) ]]; then
            skip_hardlinks_flag="true"
        else
            skip_hardlinks_flag="false"
        fi
        shift 2
        ;;
    -p | --passes)
        passes_flag=$2
        shift 2
        ;;
    *)
        break
        ;;
    esac
done

root_path=$1

# ensure we don't do something unexpected
if [[ -r "rebalance_db.txt" ]]; then
    color_echo "${Red}" 'Found legacy database file in "rebalance_db.txt". To avoid possible unintended operations the process will terminate. You can either convert the legacy database using "convert-legacy-db.sh" script, or simply delete/rename "rebalance_db.txt"'
    exit 2
fi

color_echo "$Cyan" "Start rebalancing:"
color_echo "$Cyan" "  Path: ${root_path}"
color_echo "$Cyan" "  Rebalancing Passes: ${passes_flag}"
color_echo "$Cyan" "  Rebalancing DB: $(init_database)"
color_echo "$Cyan" "  Use Checksum: ${checksum_flag}"
color_echo "$Cyan" "  Skip Hardlinks: ${skip_hardlinks_flag}"

# count files
if [[ "${skip_hardlinks_flag,,}" == "true"* ]]; then
    file_count=$(find "${root_path}" -type f -links 1 | wc -l)
else
    file_count=$(find "${root_path}" -type f | wc -l)
fi

color_echo "$Cyan" "  File count: ${file_count}"

case "${OSTYPE,,}" in
"linux-gnu"*)
    file_hash_original="/dev/shm/zfs-inplace-rebalancing.md5sum.original"
    file_hash_copy="/dev/shm/zfs-inplace-rebalancing.md5sum.copy"
    ;;
"freebsd"* | "darwin"*)
    file_hash_original="/tmp/zfs-inplace-rebalancing.md5sum.original"
    file_hash_copy="/tmp/zfs-inplace-rebalancing.md5sum.copy"
    ;;
*)
    echo "Unsupported OS type: $OSTYPE"
    exit 1
    ;;
esac

# recursively scan through files and execute "rebalance" procedure
# in the case of --skip-hardlinks, only find files with links == 1
# find command:
# -type f -- only files
# -links 1 -- only files with 1 link (no hardlinks)
# -print0 -- print with null terminator
# while loop:
# -r -- raw input
# -d -- delimiter
if [[ "${skip_hardlinks_flag,,}" == "true"* ]]; then
    find "$root_path" -type f -links 1 -print0 | while IFS= read -r -d '' file; do
        if [[ "${loop}" == false ]]; then # exit if loop is false
            break
        fi
        rebalance "$file"
    done
else
    find "$root_path" -type f -print0 | while IFS= read -r -d '' file; do
        if [[ "${loop}" == false ]]; then # exit if loop is false
            break
        fi
        rebalance "$file"
    done
fi

# There may be some pending changes as we will almost never hit the interval perfectly - flush it
persist_database

# cleanup
rm -f "${file_hash_original}" "${file_hash_copy}"

echo ""
echo ""
color_echo "$Green" "Done!"

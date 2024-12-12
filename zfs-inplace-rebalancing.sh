#!/usr/bin/env bash

# exit script on error
set -e
# exit on undeclared variable
set -u

# file used to track processed files
rebalance_db_file_name="rebalance_db.txt"

# index used for progress
current_index=0

# temporary file extension
tmp_extension=".balance"

# temporary files used for checksum comparison
file_hash_original="" # original file hash
file_hash_copy=""     # copy file hash

## Color Constants

# Reset
Color_Off='\033[0m'       # Text Reset

# Regular Colors
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Cyan='\033[0;36m'         # Cyan

## Functions

# print a help message
function print_usage() {
  echo "Usage: zfs-inplace-rebalancing --checksum true --skip-hardlinks false --passes 1 /my/pool"
}

# print a given text entirely in a given color
function color_echo () {
    color=$1
    text=$2
    echo -e "${color}${text}${Color_Off}"
}


function get_rebalance_count () {
    file_path=$1

    line_nr=$(grep -xF -n "${file_path}" "./${rebalance_db_file_name}" | head -n 1 | cut -d: -f1)
    if [ -z "${line_nr}" ]; then
        echo "0"
        return
    else
        rebalance_count_line_nr="$((line_nr + 1))"
        rebalance_count=$(awk "NR == ${rebalance_count_line_nr}" "./${rebalance_db_file_name}")
        echo "${rebalance_count}"
        return
    fi
}

# rebalance a specific file
function rebalance () {
    file_path=$1

    # check if file has >=2 links in the case of --skip-hardlinks
    # this shouldn't be needed in the typical case of `find` only finding files with links == 1
    # but this can run for a long time, so it's good to double check if something changed
    if [[ "${skip_hardlinks_flag,,}" == "true"* ]]; then
	if [[ "${OSTYPE,,}" == "linux-gnu"* ]]; then
	    # Linux
	    #
	    #  -c  --format=FORMAT
	    #      use the specified FORMAT instead of the default; output a
	    #      newline after each use of FORMAT
	    #  %h     number of hard links

	    hardlink_count=$(stat -c "%h" "${file_path}")
	elif [[ "${OSTYPE,,}" == "darwin"* ]] || [[ "${OSTYPE,,}" == "freebsd"* ]]; then
	    # Mac OS
	    # FreeBSD
	    #  -f format
	    #  Display information using the specified format
	    #   l       Number of hard links to file (st_nlink)

	    hardlink_count=$(stat -f %l "${file_path}")
	else
		echo "Unsupported OS type: $OSTYPE"
		exit 1
	fi

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

    if [ "${passes_flag}" -ge 1 ]; then
        # check if target rebalance count is reached
        rebalance_count=$(get_rebalance_count "${file_path}")
        if [ "${rebalance_count}" -ge "${passes_flag}" ]; then
        color_echo "${Yellow}" "Rebalance count (${passes_flag}) reached, skipping: ${file_path}"
        return
        fi
    fi
   
    tmp_file_path="${file_path}${tmp_extension}"

    echo "Copying '${file_path}' to '${tmp_file_path}'..."
    if [[ "${OSTYPE,,}" == "linux-gnu"* ]]; then
        # Linux

        # --reflink=never -- force standard copy (see ZFS Block Cloning)
        # -a -- keep attributes, includes -d -- keep symlinks (dont copy target) and 
        #       -p -- preserve ACLs to
        # -x -- stay on one system
        cp --reflink=never -ax "${file_path}" "${tmp_file_path}"
    elif [[ "${OSTYPE,,}" == "darwin"* ]] || [[ "${OSTYPE,,}" == "freebsd"* ]]; then
        # Mac OS
        # FreeBSD

        # -a -- Archive mode.  Same as -RpP. Includes preservation of modification 
        #       time, access time, file flags, file mode, ACL, user ID, and group 
        #       ID, as allowed by permissions.
        # -x -- File system mount points are not traversed.
        cp -ax "${file_path}" "${tmp_file_path}"
    else
        echo "Unsupported OS type: $OSTYPE"
        exit 1
    fi

    # compare copy against original to make sure nothing went wrong
    if [[ "${checksum_flag,,}" == "true"* ]]; then
        echo "Comparing copy against original..."
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
        # the use of read is preferred over cat for performance reasons
        # -r -- raw input
        read -r original_hash <"${file_hash_original}"
        read -r copy_hash <"${file_hash_copy}"

        # strip the md5sum results to only contain the hash
        original_hash=${original_hash%% *}
        copy_hash=${copy_hash%% *}

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
        # update rebalance "database"
        line_nr=$(grep -xF -n "${file_path}" "./${rebalance_db_file_name}" | head -n 1 | cut -d: -f1)
        if [ -z "${line_nr}" ]; then
        rebalance_count=1
        echo "${file_path}" >> "./${rebalance_db_file_name}"
        echo "${rebalance_count}" >> "./${rebalance_db_file_name}"
        else
        rebalance_count_line_nr="$((line_nr + 1))"
        rebalance_count="$((rebalance_count + 1))"
        sed -i '' "${rebalance_count_line_nr}s/.*/${rebalance_count}/" "./${rebalance_db_file_name}"
        fi
    fi
}

checksum_flag='true'
skip_hardlinks_flag='false'
passes_flag='1'

if [[ "$#" -eq 0 ]]; then
    print_usage
    exit 0
fi

while true ; do
    case "$1" in
        -h | --help )
            print_usage
            exit 0
        ;;
        -c | --checksum )
            if [[ "$2" == 1 || "$2" =~ (on|true|yes) ]]; then
                checksum_flag="true"
            else
                checksum_flag="false"
            fi
            shift 2
        ;;
        --skip-hardlinks )
            if [[ "$2" == 1 || "$2" =~ (on|true|yes) ]]; then
                skip_hardlinks_flag="true"
            else
                skip_hardlinks_flag="false"
            fi
            shift 2
        ;;
        -p | --passes )
            passes_flag=$2
            shift 2
        ;;
        *)
            break
        ;;
    esac 
done;

root_path=$1

color_echo "$Cyan" "Start rebalancing $(date):"
color_echo "$Cyan" "  Path: ${root_path}"
color_echo "$Cyan" "  Rebalancing Passes: ${passes_flag}"
color_echo "$Cyan" "  Use Checksum: ${checksum_flag}"
color_echo "$Cyan" "  Skip Hardlinks: ${skip_hardlinks_flag}"

# count files
if [[ "${skip_hardlinks_flag,,}" == "true"* ]]; then
    file_count=$(find "${root_path}" -type f -links 1 | wc -l)
else
    file_count=$(find "${root_path}" -type f | wc -l)
fi

color_echo "$Cyan" "  File count: ${file_count}"

# create db file
if [ "${passes_flag}" -ge 1 ]; then
    touch "./${rebalance_db_file_name}"
fi

# set temporary file paths based on OS
case "${OSTYPE,,}" in
"linux-gnu"*)
    # Linux

    # this folder is in the ram so the access time should be great
    file_hash_original="/dev/shm/zfs-inplace-rebalancing.md5sum.original"
    file_hash_copy="/dev/shm/zfs-inplace-rebalancing.md5sum.copy"
    ;;
"freebsd"* | "darwin"*)
    # Mac OS or FreeBSD

    # the tmp folder is generally in the ram so the same as for linux
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
if [[ "${skip_hardlinks_flag,,}" == "true"* ]]; then
    find "$root_path" -type f -links 1 -print0 | while IFS= read -r -d '' file; do rebalance "$file"; done
else
    find "$root_path" -type f -print0 | while IFS= read -r -d '' file; do rebalance "$file"; done
fi

# cleanup : remove the temporary files (not that bad if not done the next reboot will do it and they are only 1 line each)
rm -f "${file_hash_original}" "${file_hash_copy}"

echo ""
echo ""
color_echo "$Green" "Done!"

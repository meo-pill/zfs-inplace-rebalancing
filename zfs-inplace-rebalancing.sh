#!/usr/bin/env bash

# exit script on error
set -e
# exit on undeclared variable
set -u

## Variables

# file used to track processed files
rebalance_db_file_name="rebalance_db.txt"

# index used for progress
current_index=0

## Color Constants

# Reset
Color_Off='\033[0m' # Text Reset

# Regular Colors
Red='\033[0;31m'    # Red
Green='\033[0;32m'  # Green
Yellow='\033[0;33m' # Yellow
Cyan='\033[0;36m'   # Cyan

# Temporary file extension
tmp_extension=".balance"

# time of last rebalance "database" update
lastupdate=$SECONDS

# Array to store rebalance "database"
declare -a db_array

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

# function to load a rebalance "database" file into an array
function load_rebalance_db() {
    local file="$1"
    while IFS= read -r line; do
        db_array+=("$line")
    done < "$file"
}

# function to save a rebalance "database" array into a file
function save_rebalance_db() {
    local file="$1"
    printf "%s\n" "${db_array[@]}" > "$file"
}

# function to update the rebalance count for a file
function update_rebalance_count() {
    local file_path="$1"
    local line_nr=-1

    # find the file in the array
    for i in "${!db_array[@]}"; do
        if [[ "${db_array[$i]}" == "$file_path" ]]; then
            line_nr=$i
            break
        fi
    done

    if [[ $line_nr -eq -1 ]]; then
        # add the file to the array if it doesn't exist
        db_array+=("$file_path")
        db_array+=(1)
    else
        # update the rebalance count
        local rebalance_count_line_nr=$((line_nr + 1))
        db_array[$rebalance_count_line_nr]=$((db_array[$rebalance_count_line_nr] + 1))
    fi
}

# function to get the rebalance count for a file
function get_rebalance_count() {
    local file_path="$1"
    local line_nr=-1

    # find the file in the array
    for i in "${!db_array[@]}"; do
        if [[ "${db_array[$i]}" == "$file_path" ]]; then
            line_nr=$i
            break
        fi
    done

    # return 0 if the file is not found
    if [[ $line_nr -eq -1 ]]; then
        echo 0
    else
        # return the rebalance count
        local rebalance_count_line_nr=$((line_nr + 1))
        echo "${db_array[$rebalance_count_line_nr]}"
    fi    
}

# rebalance a specific file
function rebalance() {
    file_path=$1

    # check if file has >=2 links in the case of --skip-hardlinks
    # this shouldn't be needed in the typical case of `find` only finding files with links == 1
    # but this can run for a long time, so it's good to double check if something changed
    if [[ "${skip_hardlinks_flag}" == "true"* ]]; then
        if [[ "${OSName}" == "linux-gnu"* ]]; then
            # Linux
            #
            #  -c  --format=FORMAT
            #      use the specified FORMAT instead of the default; output a
            #      newline after each use of FORMAT
            #  %h     number of hard links

            hardlink_count=$(stat -c "%h" "${file_path}")
        elif [[ "${OSName}" == "darwin"* ]] || [[ "${OSName}" == "freebsd"* ]]; then
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
    progress_percent=$(printf '%0.2f' "$((current_index * 10000 / file_count))e-2")
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
    if [[ "${OSName}" == "linux-gnu"* ]]; then
        # Linux

        # --reflink=never -- force standard copy (see ZFS Block Cloning)
        # -a -- keep attributes, includes -d -- keep symlinks (dont copy target) and
        #       -p -- preserve ACLs to
        # -x -- stay on one system
        cp --reflink=never -ax "${file_path}" "${tmp_file_path}"
    elif [[ "${OSName}" == "darwin"* ]] || [[ "${OSName}" == "freebsd"* ]]; then
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
    if [[ "${checksum_flag}" == "true"* ]]; then
        echo "Comparing copy against original..."
        if [[ "${OSName}" == "linux-gnu"* ]]; then
            # Linux

            # file attributes
            original_checksum=$(lsattr "${file_path}")
            # remove anything after the last space
            original_checksum=${original_checksum% *}
            # file permissions, owner, group, size, modification time
            original_checksum="${original_checksum} $(stat -c "%A %U %G %s %Y" "${file_path}")"
            # file content
            original_checksum="${original_checksum} $(cksum "${file_path}")"


            # file attributes
            copy_checksum=$(lsattr "${tmp_file_path}")
            # remove anything after the last space
            copy_checksum=${copy_checksum% *}
            # file permissions, owner, group, size, modification time
            copy_checksum="${copy_checksum} $(stat -c "%A %U %G %s %Y" "${tmp_file_path}")"
            # file content
            copy_checksum="${copy_checksum} $(cksum "${tmp_file_path}")"
            # remove the temporary extension
            copy_checksum=${copy_checksum%"${tmp_extension}"}
        elif [[ "${OSName}" == "darwin"* ]] || [[ "${OSName}" == "freebsd"* ]]; then
            # Mac OS
            # FreeBSD

            # note: no lsattr on Mac OS or FreeBSD

            # file permissions, owner, group size, modification time
            original_checksum="$(stat -f "%Sp %Su %Sg %z %m" "${file_path}")"
            # file content
            original_checksum="${original_checksum} $(cksum "${file_path}")"

            # file permissions, owner, group size, modification time
            copy_checksum="$(stat -f "%Sp %Su %Sg %z %m" "${tmp_file_path}")"
            # file content
            copy_checksum="${copy_checksum} $(cksum "${file_path}")"
            # remove the temporary extension
            copy_checksum=${copy_checksum%"${tmp_extension}"}
        else
            echo "Unsupported OS type: $OSTYPE"
            exit 1
        fi

        if [[ "${original_checksum}" == "${copy_checksum}"* ]]; then
            color_echo "${Green}" "Checksum OK"
        else
            color_echo "${Red}" "Checksum FAILED: ${original_checksum} != ${copy_checksum}"
            exit 1
        fi
    fi

    echo "Removing original '${file_path}'..."
    rm "${file_path}"

    echo "Renaming temporary copy to original '${file_path}'..."
    mv "${tmp_file_path}" "${file_path}"

    if [ "${passes_flag}" -ge 1 ]; then
        # update rebalance "database"
        update_rebalance_count "${file_path}"
        timediff=$(($SECONDS - $lastupdate))
        if [ "${timediff}" -gt 60 ]; then
            save_rebalance_db "${rebalance_db_file_name}"
            lastupdate=$SECONDS
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

OSName=$(echo "$OSTYPE" | tr '[:upper:]' '[:lower:]')

color_echo "$Cyan" "Start rebalancing $(date):"
color_echo "$Cyan" "  Path: ${root_path}"
color_echo "$Cyan" "  Rebalancing Passes: ${passes_flag}"
color_echo "$Cyan" "  Use Checksum: ${checksum_flag}"
color_echo "$Cyan" "  Skip Hardlinks: ${skip_hardlinks_flag}"

# count files
if [[ "${skip_hardlinks_flag}" == "true"* ]]; then
    file_count=$(find "${root_path}" -type f -links 1 | wc -l)
else
    file_count=$(find "${root_path}" -type f | wc -l)
fi

color_echo "$Cyan" "  File count: ${file_count}"

# create db file
if [ "${passes_flag}" -ge 1 ]; then
    touch "./${rebalance_db_file_name}"
fi

# recursively scan through files and execute "rebalance" procedure
# in the case of --skip-hardlinks, only find files with links == 1
if [[ "${skip_hardlinks_flag}" == "true"* ]]; then
    find "$root_path" -type f -links 1 -print0 | while IFS= read -r -d '' file; do rebalance "$file"; done
else
    find "$root_path" -type f -print0 | while IFS= read -r -d '' file; do rebalance "$file"; done
fi

echo ""
echo ""
color_echo "$Green" "Done!"

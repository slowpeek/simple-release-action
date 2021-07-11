#!/usr/bin/env bash

set -eu
shopt -s extglob

PROJECT=${GITHUB_REPOSITORY##*/} # Last part of repo name like
                                 # 'project' in 'user/project'.

TAG=${GITHUB_REF##*/}           # Last part of ref.
NAME=${PROJECT}-${TAG}          # Full project name with version.

VERSION_MATCH='^(([A-Z]+_)+VERSION)=.+'

bye () {
    printf '%s\n' "$*"
    exit 1
}

# args: a
#
# Check if array ${!a} is empty.
empty () {
    [[ $1 == a ]] || local -n a=$1
    ((${#a[@]} == 0))
}

# Install pandoc on first call.
pandoc () {
    unset -f pandoc
    hash pandoc 2>/dev/null || sudo apt-get -y install pandoc </dev/null >&2
    pandoc "$@"
}

# args: s
#
# Trim whitespace in ${!s}
trim () {
    [[ $1 == s ]] || local -n s=$1

    s=${s#${s%%[![:space:]]*}}
    s=${s%${s##*[![:space:]]}}
}

# args: ext path
#
# Set ${!ext} to filename ext of $path.
fn_ext () {
    [[ $1 == ext ]] || local -n ext=$1
    local _fn=${2##*/}
    [[ $_fn == *.* ]] && ext=${_fn##*.} || ext=
}

# Parse $INPUT_FILES into $FILES and $FLAGGED_* global arrays.
parse_input_files () {
    declare -g FILES=()

    local -A _flags=([v]=t [doc]=t [toc]=t)
    local flag

    # Create global FLAGGED_* arrays.
    for flag in "${!_flags[@]}"; do
        declare -g -A FLAGGED_"${flag^^}"='()'
    done

    local -A map
    local s file flags=()

    while read -r s; do
        trim s

        # Skip empty lines.
        [[ -n $s ]] || continue

        # Remove spaces around '+'.
        s=${s//*([[:space:]])+*([[:space:]])/+}

        # Remove repeated '+'.
        s=${s//++(+)/+}

        file=${s%%+*}

        [[ -n $file ]] || continue

        [[ ! -v map[$file] ]] || bye "${file@Q} is listed more than once."
        map[$file]=t

        [[ -f $file ]] || bye "File not found: ${file@Q}"

        s=${s:${#file}+1}
        IFS=+ read -r -a flags <<< "${s,,}"

        for flag in "${flags[@]}"; do
            [[ -v _flags[$flag] ]] || bye "Unknown flag: ${flag@Q}"

            local -n flagged=FLAGGED_${flag^^}
            # shellcheck disable=SC2034
            flagged[$file]=t
        done
    done <<< "$INPUT_FILES"

    FILES=("${!map[@]}")
}

# Check input data consistency.
check_input () {
    local file ext key
    local -A map

    # Check ext for 'doc' flagged files.
    for file in "${!FLAGGED_DOC[@]}"; do
        fn_ext ext "$file"

        [[ $ext == @(org|md) ]] ||
            bye "${file@Q}: 'doc' flag only applies to 'org' and 'md' files."

        key=${file%.*}

        [[ ! -v map[$key] ]] ||
            bye "${file@Q}, ${map[$key]@Q}: cant apply 'doc' flag to both."

        map[$key]=$file
    done

    # Check if html and plaintext versions of 'doc' flagged files
    # override any other file.
    for file in "${FILES[@]}"; do
        fn_ext ext "$file"

        [[ -z $ext || $ext == html ]] || continue

        key=${file%.*}

        if [[ -v map[$key] ]]; then
            local type=html
            [[ $ext == html ]] || type=plaintext

            bye "${map[$key]@Q} has 'doc' flag." \
                "Its generated $type version would overwrite ${file@Q}"
        fi
    done

    # shellcheck disable=SC2153
    for file in "${!FLAGGED_TOC[@]}"; do
        [[ -v FLAGGED_DOC[$file] ]] ||
            bye "${file@Q}: 'toc' flag requires 'doc' flag."
    done

    # Check if 'v' flagged files match $VERSION_MATCH.
    for file in "${!FLAGGED_V[@]}"; do
        test_version "$file" ||
            bye "${file@Q} has 'v' flag but its content" \
                "doesnt match ${VERSION_MATCH}"
    done

    # Check 'bump-version' value.
    if empty FLAGGED_V; then
        # It is useless if there are no 'v' flagged files.
        INPUT_BUMP_VERSION=
    else
        trim INPUT_BUMP_VERSION
        [[ ! $INPUT_BUMP_VERSION == *[[:space:]]* ]] ||
            bye "'bump-version' value contains whitespace."
    fi
}

# args: path
test_version () {
    grep -qPm1 "$VERSION_MATCH" "$1"
}

# args: tag
set_version () {
    sed -Ei "0,/$VERSION_MATCH/s//\\1=$1/" "${!FLAGGED_V[@]}"
}

# Copy 'doc' flagged files into dist/ as html and plaintext.
docs_to_dist () {
    local file doc ext format opts

    for file in "${!FLAGGED_DOC[@]}"; do
        fn_ext ext "$file"
        [[ $ext == org ]] && format=org || format=gfm

        doc=${file%.*}

        # Plaintext version.
        pandoc -f "$format" -t plain "$file" |
            install -D /dev/stdin dist/"$doc"

        # Html version.
        opts=(-f "$format" -t html -s --metadata "pagetitle=$NAME :: $doc")

        # Optionally enable table of contents.
        [[ ! -v FLAGGED_TOC[$file] ]] || opts+=(--toc)

        pandoc "${opts[@]}" "$file" |
            install -D /dev/stdin dist/"$doc".html
    done
}

# Copy $FILES to dist/ but 'doc' flagged ones.
files_to_dist () {
    local path

    for path in "${FILES[@]}"; do
        [[ -v FLAGGED_DOC[$path] ]] || install -D "$path" dist/"$path"
    done
}

# Extract release notes from either CHANGELOG.org or CHANGELOG.md.
release_notes () {
    set -- org '*' md '#'
    local ext marker doc match range

    while (($# > 0)); do
        ext=$1
        marker=$2
        shift 2

        doc=CHANGELOG.$ext
        [[ -f $doc ]] || continue

        # Take two topmost headings.
        readarray -t match < <(grep -m2 -n "^$marker " "$doc")

        # Check if the first heading contains the tag.
        [[ -v match && ${match[0]} == *"$TAG"* ]] || continue

        range=$((${match[0]%%:*} + 1)),

        if [[ -v match[1] ]]; then
            # Fetch till the next heading.
            range+=$((${match[1]%%:*} - 1))
        else
            # It was the only heading. Fetch till the end.
            range+='$'
        fi

        if [[ $ext == org ]]; then
            sed -n "${range}p" "$doc" |
                pandoc -f org -t gfm # Convert to github markdown.
        else
            # shellcheck disable=SC2005
            sed -n "${range}p" "$doc" |
                awk 'NF{b=1}b'  # Remove leading empty lines.
        fi

        break
    done
}

# Set version='${TAG}${INPUT_BUMP_VERSION}' for 'v' flagged files and
# commit.
bump_dev_version () {
    set_version "${TAG}${INPUT_BUMP_VERSION}"
    readarray -t changed < <(git diff --name-only "${!FLAGGED_V[@]}")

    if [[ -v changed ]]; then
        git config --local user.name "github-actions[bot]"
        git config --local user.email \
            "41898282+github-actions[bot]@users.noreply.github.com"

        git add "${changed[@]}"
        git commit -m "Post-release dev version bump"
        git push
    fi
}

parse_input_files

[[ -v FILES ]] || bye 'Files list is empty.'

check_input

mkdir dist
files_to_dist

if ! empty FLAGGED_V; then
    cd dist
    set_version "$TAG"
    cd ..
fi

docs_to_dist

mv dist "$NAME"
tar czf "$NAME".tar.gz "$NAME"

gh release create "$TAG" --notes "$(release_notes)" "$NAME".tar.gz

[[ -z $INPUT_BUMP_VERSION ]] || bump_dev_version

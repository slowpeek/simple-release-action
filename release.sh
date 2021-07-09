#!/usr/bin/env bash

set -eu

PROJECT=${GITHUB_REPOSITORY##*/} # Last part of repo name like
                                 # 'project' in 'user/project'.

TAG=${GITHUB_REF##*/}           # Last part of ref.
NAME=${PROJECT}-${TAG}          # Full project name with version.

DIST_DEFAULT=(LICENSE)          # Files to include in release by
                                # default. Not existing ones are
                                # skipped.

DOCS=(README CHANGELOG)         # File names without ext to process
                                # with docs_to_dist() and include in
                                # release. The function checks for
                                # 'org' and 'md' ext itself. Not
                                # existing ones are skipped.

bye () {
    printf '%s\n' "$1"
    exit 1
}

# args: result
#
# Trim and store not empty uniq lines from stdin into array
# @result. The order of lines is not preserved.
readarray_filtered () {
    local -n result=$1

    # shellcheck disable=SC2034
    readarray -t result < <(
        sed -E 's/^[[:space:]]+|[[:space:]]+$//;/./!d' |
            sort -u
    )
}

install_reqs () {
    hash pandoc 2>/dev/null || sudo apt-get -y install pandoc
}

# args: tag
set_version () {
    [[ ! -v VERSIONED ]] ||
        sed -Ei "0,/^(([A-Z]+_)+VERSION)=.+/s//\\1=$1/" "${VERSIONED[@]}"
}

# args: format html_title
doc2html () {
    pandoc -f "$1" -t html -s --toc --metadata pagetitle="$2"
}

# args: format
doc2text () {
    pandoc -f "$1" -t plain
}

# Copy $DOCS into dist/ with format conversion:
# org -> html, text
# md -> html, text
docs_to_dist () {
    local doc ext format

    for doc in "${DOCS[@]}"; do
        if [[ -f $doc.org ]]; then
            ext=org
            format=org
        elif [[ -f $doc.md ]]; then
            ext=md
            format=gfm
        else
            continue
        fi

        doc2html "$format" "$NAME :: $doc" <"$doc.$ext" >dist/"$doc".html
        doc2text "$format" <"$doc.$ext" >dist/"$doc"
    done
}

# Merge $DIST_DEFAULT, $VERSIONED into $DIST. Check file existence on
# the go.
check_files () {
    local -A map=()
    local path

    # Extract existing pathes from $DIST_DEFAULT into $map.
    for path in "${DIST_DEFAULT[@]}"; do
        ! [[ -f $path ]] || map[$path]=t
    done

    # Merge $DIST, $VERSIONED into $map.
    for path in "${DIST[@]}" "${VERSIONED[@]}"; do
        if [[ ! -v map[$path] ]]; then
            [[ -f $path ]] || bye "No such file: ${path@Q}"

            map[$path]=t
        fi
    done

    DIST=("${!map[@]}")         # No matter the order.
}

# Copy $DIST files to dist/.
files_to_dist () {
    local path

    for path in "${DIST[@]}"; do
        install -D "$path" dist/"$path"
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

# Set version='${TAG}+dev' for $VERSIONED files and commit.
bump_dev_version () {
    set_version "${TAG}+dev"
    readarray -t changed < <(git diff --name-only "${VERSIONED[@]}")

    if [[ -v changed ]]; then
        git config --local user.name "github-actions[bot]"
        git config --local user.email \
            "41898282+github-actions[bot]@users.noreply.github.com"

        git add "${changed[@]}"
        git commit -m "Post-release dev version bump"
        git push
    fi
}

install_reqs

[[ ${INPUT_DO_DIST_DEFAULT,} == y* ]] || DIST_DEFAULT=()
[[ ${INPUT_DO_DOCS,} == y* ]] || DOCS=()

readarray_filtered DIST <<< "$INPUT_DIST"

if [[ ${INPUT_DO_VERSIONED,} == y* ]]; then
    readarray_filtered VERSIONED <<< "$INPUT_VERSIONED"
else
    VERSIONED=()
fi

check_files

mkdir dist
files_to_dist

cd dist
set_version "$TAG"
cd ..

docs_to_dist

mv dist "$NAME"
tar czf "$NAME".tar.gz "$NAME"

gh release create "$TAG" --notes "$(release_notes)" "$NAME".tar.gz

[[ ${INPUT_DO_VERSIONED_BUMP,} == n* ]] || bump_dev_version

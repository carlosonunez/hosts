#!/usr/bin/env bash
#vi: set ft=bash:
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
FILES_DIR="${FILES_DIR:-$SCRIPT_DIR}"
SOURCES_FILE="$SCRIPT_DIR/sources.yaml"
SOURCES_FILE_RENDERED="$SCRIPT_DIR/sources.yaml.rendered"
GNU_SED_CONFIRMED=0
FIREBOG_URL="https://v.firebog.net/hosts/csv.txt"
export LC_ALL=C

_csvtojson()
{
    function _do_it ()
    {
        python -c 'import csv, json, sys; print(json.dumps([dict(r) for r in csv.DictReader(sys.stdin)]))'
    };
    if ! test -z "$1"; then
        if test -e "$1"; then
            _do_it < "$1";
        else
            echo -e "$1" | _do_it;
        fi;
    else
        _do_it < /dev/stdin;
    fi
}

fail() {
  >&2 echo "ERROR: $1"
  exit 1
}

gnu_sort() {
  if ! grep -q 'GNU coreutils' <<< $("$(which sort)" --version)
  then gsort "$@"
  else $(which sort) "$@"
  fi
}


yq() {
  $(which yq) -o=json "$SOURCES_FILE_RENDERED" | $(which jq) "$@"
}

render_sources_file() {
  _render_firebog() {
    local src="$1"
    local dst="$2"
    local start_line='"type","status","page","name","url"'
    local domains=$(curl -L "$FIREBOG_URL")
    if test -z "$domains"
    then
      fail "Failed to retrieve list of domains from Firebog"
      return 1
    fi
    local csv="$(echo -ne "${start_line}\n${domains}")"
    local list=$(_csvtojson <<< "$csv" |
      $(which yq) -P '[.[] | select((.status != "cross") and (.type != "suspicious") and (.name | downcase | contains("adult") | not) and (.url | downcase | contains("porn") | not)) | { "name": "[" + .type + "] " + .name , "url": .url }]' |
      sed "s/'/\"/g; s/\"\"/'/g; s/^/  /g; s/"'\&'"/{AMP}/g")
    if test -z "$list"
    then
      fail "Failed to retrieve lists from Firebog"
      return 1
    fi
    lines=$(wc -l <<< "$list")
    lines_single=$(awk '{printf "%s\\n", $0}' <<< "$list")
    >&2 echo "[pre] Rendering $lines domains from Firebog"
    gnu_sed "s#{{ firebog }}#$lines_single#" "$src" |
      gnu_sed 's/{AMP}/\&/g' |
      grep -Ev "^$" > "$dst"
  }
  _finish_rendering() {
    local src="$1"
    local dst="$2"
    >&2 echo "[pre] Wrapping up rendering the sources file"
    mv "$src" "$dst"
  }
  starting_file="$SOURCES_FILE"
  step_1="${starting_file}.1"
  ending_file="$SOURCES_FILE_RENDERED"
  _render_firebog "$starting_file" "$step_1" || return 1
  _finish_rendering "$step_1" "$ending_file" || return 1
}

gnu_sed() {
  # if sed errors when running --version then it's probably the BSD variant.
  if ! &>/dev/null sed --version
  then
    if test GNU_SED_CONFIRMED=0 && ! which gsed &>/dev/null
    then
      fail "this script requires GNU sed, or gsed, on MacOS. Install it with 'brew install coreutils'"
    fi
    GNU_SED_CONFIRMED=1
    gsed "$@"
  else
    sed "$@"
  fi
}

confirm_yq_or_exit() {
  ( 2>&1 $(which yq) --version | grep -q 'mikefarah' ) || fail "[core] yq not installed"
}

confirm_jq_or_exit() {
  &>/dev/null which jq || fail "[core] yq not installed"
}

hosts_file_path() {
  echo "${FILES_DIR}/hosts/${1}.txt"
}

create_host_files_and_dirs() {
  for file in $1
  do
    fp=$(hosts_file_path "$file")
    dir=$(dirname "$fp")
    if test -f "$fp"
    then
      >&2 echo "[core] Removing $file"
      rm -f "$fp"
    fi
    (mkdir -p "$dir" && touch "$fp") || fail "[$fp] Couldn't create ths file; see logs"
  done
}

gather_sources() {
  yq -r '.sources[] | .name'
}

write_hosts_files() {
  src="$1"
  files="$2"
  data=$(yq --arg source "$src" -r \
    '.sources[] | select(.name == $source) | .name + "%" + .url + "%" +
      (if .exclude_files != null then (.exclude_files | join(",")) else "none" end)')
  if test -z "$data" || grep 'null' <<< "$data"
  then
    fail "[$src] Unable to find one or more fields"
  fi
  name="$(cut -f1 -d '%' <<< "$data")"
  url="$(cut -f2 -d '%' <<< "$data")"
  files_to_skip=$(cut -f3 -d '%' <<< "$data" | tr ',' '\n')
  >&2 echo "[$name] Downloading domains from '$url'..."
  domains=$(curl -sL "$url")
  test -z "$domains" && fail "[$name] This source contained no domains."
  count=$(wc -l <<< "$domains" | cut -f1 -d ' ')
  >&2 echo "[$name] Writing $count domains to files:"
  for file in $files
  do
    if ! grep -Eq "^$file$" <<< "$files_to_skip"
    then
      fp=$(hosts_file_path "$file")
      >&2 echo "[$name] --> $fp"
      cat >>"$fp" <<< "$domains"
    fi
  done
}

sort_and_remove_duplicates() {
  _do_and_print_diff() {
    fp="$1"
    prefix="$2"
    orig_count=$(wc -l "$fp" | cut -f1 -d ' ')
    "${@:3}"
    final_count=$(wc -l "$fp" | cut -f1 -d ' ')
    diff=$(echo "${orig_count}-${final_count}" | bc)
    >&2 echo "[$file] $diff $prefix removed (orig: $orig_count, final: $final_count)"
  }
  for file in $files
  do
    fp=$(hosts_file_path "$file")
    >&2 echo "[$file] Sorting and removing dupes..."
    _do_and_print_diff "$fp" "duplicate domains" gnu_sort -uio "$fp" "$fp"
    >&2 echo "[$file] Removing comments..."
    _do_and_print_diff "$fp" "comments" gnu_sed -E -i '/^([ \t]+)?#/d' "$fp"
  done
}

process_whitelists() {
  files="$1"
  for file in $files
  do
    regexps=""
    whitelists="$(yq -r --arg file "$file" \
      '.files[] | select(.name == $file) | .whitelists[]')"
    for whitelist in $whitelists
    do
      patterns=$(yq -r --arg whitelist "$whitelist" \
        '.whitelists[] | select(.name == $whitelist) | .patterns | join("%")')
      pattern_count=$(tr '%' '\n' <<< "$patterns" | wc -l)
      >&2 echo "[$file] Adding $pattern_count patterns from whitelist: $whitelist"
      regexps="$regexps%$patterns"
    done
    match_re="0.0.0.0 ($(sed 's/^%//; s#%#\|#g; s/.$//g' <<< "$regexps"))$"
    while read -r pattern
    do
      >&2 echo "[$file] Removing from this file: $pattern"
      gnu_sed -i "/$pattern/d" "$(hosts_file_path "$file")"
    done < <(grep -E "$match_re" "$(hosts_file_path "$file")")
  done
}

gather_files() {
  yq -r '.files[].name'
}

confirm_yq_or_exit
confirm_jq_or_exit
if ! render_sources_file
then
  fail "Failed to generate source file; see logs for more details."
  exit 1
fi
files=$(gather_files)
create_host_files_and_dirs "$files"
orig_ifs="$IFS"
IFS=$'\n'
for source in $(gather_sources)
do write_hosts_files "$source" "$files" || exit 1
done
IFS="$orig_ifs"
sort_and_remove_duplicates "$files" || exit 1
process_whitelists "$files" || exit 1
>&2 echo "[core] Script complete"

#!/usr/bin/env bash
#vi: set ft=bash:
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
FILES_DIR="${FILES_DIR:-$SCRIPT_DIR}"
SOURCES_FILE="$SCRIPT_DIR/sources.yaml"
GNU_SED_CONFIRMED=0

fail() {
  >&2 echo "ERROR: $1"
  exit 1
}

yq() {
  $(which yq) -o=json "$SOURCES_FILE" | $(which jq) "$@"
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

process_whitelist() {
  match_re="^0.0.0.0 ($(grep -Ev '^#' "$EXCLUSIONS_FILE" | tr '\n' '%' | sed 's#%#\|#g; s/.$//g'))$"
  for file in $(tr ',' '\n' <<< "$ALL_FILES")
  do
    while read -r pattern
    do
      >&2 echo "Removing from $file: $pattern"
      gnu_sed -Ei "/$pattern/d" "$file"
    done < <(grep -E "$match_re" "$file")
    gnu_sed -Ei "/^$/d; /^#/d; /^[ ]+#/d" "$file"
    sort -ruo "$file" "$file"
  done
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
  files_to_skip=$(cut -f3 -d '%' <<< "$data")
  >&2 echo "[$name] Downloading domains from '$url'..."
  curl -sLo /tmp/domains "$url"
  test -s /tmp/domains || fail "[$name] Failed to download, or source has no content"
  count=$(wc -l /tmp/domains | cut -f1 -d ' ')
  for file in $files
  do
    if ! grep -q "$file" <<< "$files_to_skip"
    then
      fp=$(hosts_file_path "$file")
      cat /tmp/domains >> "$fp"
      count=$(wc -l "$fp" | cut -f1 -d ' ')
      >&2 echo "[$name] Wrote $count domains to $fp"
    fi
  done
  rm /tmp/domains
}

sort_and_remove_duplicates() {
  for file in $files
  do
    fp=$(hosts_file_path "$file")
    orig_count=$(wc -l "$fp" | cut -f1 -d ' ')
    >&2 echo "[$file] Sorting and removing dupes..."
    sort -ruo "$fp" "$fp"
    final_count=$(wc -l "$fp" | cut -f1 -d ' ')
    diff=$(echo "${final_count}-${orig_count}" | bc)
    >&2 echo "[$file] $diff duplicate domains removed (orig: $orig_count, final: $final_count)"
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
    done < <(grep -E "$match_re" "$(hosts_file_path "$file")")
  done
}

gather_files() {
  yq -r '.files[].name'
}

confirm_yq_or_exit
confirm_jq_or_exit
files=$(gather_files)
create_host_files_and_dirs "$files"
gather_sources |
  while read -r src
  do write_hosts_files "$src" "$files"
  done
sort_and_remove_duplicates "$files"
process_whitelists "$files"
>&2 echo "[core] Script complete"

#!/usr/bin/env bash
#vi: set ft=bash:
DOCKER_IMAGE_NAME="briceburg/yq"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
HOSTS_WITH_FACEBOOK="$SCRIPT_DIR/hosts/with-fb.txt"
HOSTS_WITHOUT_FACEBOOK="$SCRIPT_DIR/hosts/without-fb.txt"
SOURCES_FILE="$SCRIPT_DIR/sources.yaml"
EXCLUSIONS_FILE="$SCRIPT_DIR/exclusions"
ALL_FILES="${HOSTS_WITH_FACEBOOK},${HOSTS_WITHOUT_FACEBOOK}"
GNU_SED_CONFIRMED=0

export DOCKER_DEFAULT_PLATFORM='linux/amd64'

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

fail() {
  >&2 echo "ERROR: $1"
  exit 1
}

create_host_dirs() {
  for file in $(tr ',' '\n' <<< "$ALL_FILES")
  do
    test -f "$file" && rm -f "$file"
    test -d "$(dirname "$file")" || mkdir -p "$(dirname "$file")"
    touch "$file"
  done
}

gather_sources() {
  docker run --rm -v "$SOURCES_FILE:/sources.yaml" "$DOCKER_IMAGE_NAME" \
    -r '.sources[] | .name + "%" + .url + "%" + (.blocks_fb|tostring)' '/sources.yaml' | \
    tr -d $'\r'
}

process_whitelist() {
  match_re="^0.0.0.0 ($(grep -Ev '^#' "$EXCLUSIONS_FILE" | tr '\n' '%' | sed 's#%#\|#g; s/.$//g'))$"
  for file in $(tr ',' '\n' <<< "$ALL_FILES")
  do
    while read -r pattern
    do
      >&2 echo "===> Removing from $file: $pattern"
      gnu_sed -Ei "/$pattern/d" "$file"
    done < <(grep -E "$match_re" "$file")
  done
}

clean_hosts_files() {
  for file in $(tr ',' '\n' <<< "$ALL_FILES")
  do
    sort -ro "$file" "$file" &&
      gnu_sed -i "/^#/d" "$file"
  done
}

create_host_dirs

while read -r source
do
  name=$(cut -f1 -d '%' <<< "$source")
  url=$(cut -f2 -d '%' <<< "$source")
  blocks_fb=$(cut -f3 -d '%' <<< "$source")
  target_file="$HOSTS_WITHOUT_FACEBOOK"
  if grep -Eiq '^true$' <<< "$blocks_fb"
  then
    target_file="${HOSTS_WITH_FACEBOOK}"
  fi
  >&2 echo "===> Fetching hosts from source: $name ==> $target_file"
  curl -sSL "$url" >> "$target_file"
done < <(gather_sources)
clean_hosts_files &&
  process_whitelist &&
  >&2 echo "===> Host files are ready"

#!/usr/bin/env bash
#vi: set ft=bash:

mkdir -p "./hosts/{with,without}-facebook"
touch "./hosts/{with,without}-facebook/hosts"
sources=$(docker run --rm -v "$PWD/sources.yaml:/sources.yaml" briceberg/yq -r \
  '.sources[] | .name + "," .source + "," + .blocks_fb' '/sources.yaml')
if test -z "$sources"
then
  >&2 echo "ERROR: Couldn't enumerate sources.yaml"
  exit 1
fi
for source in $sources
do

done

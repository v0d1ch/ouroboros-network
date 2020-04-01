#!/bin/bash
# Build haddock documentation and an index for all projects in
# `ouroboros-network` repository.

set -euo pipefail

OUTPUT_DIR=${1:-"./haddocks"}
GHC_VERSION=$(ghc --numeric-version)

if [ ${OUTPUT_DIR} == "/" ]; then
  echo "Oh no, you don't want to run 'rm -rf /*'"
  exit 1
fi
rm -rf ${OUTPUT_DIR}/*

# build documentation of all modules
cabal haddock \
  --haddock-internal \
  --haddock-html \
  --haddock-hyperlink-source \
  --haddock-quickjump \
  --haddock-hyperlinked-source \
  --haddock-options "--built-in-themes --use-unicode" \
  all

# copy the new docs
for dir in $(ls "dist-newstyle/build/x86_64-linux/ghc-${GHC_VERSION}"); do
  package=$(echo "${dir}" | sed 's/-[0-9]\+\(\.[0-9]\+\)*//')
  cp -r "dist-newstyle/build/x86_64-linux/ghc-${GHC_VERSION}/${dir}/noopt/doc/html/${package}" ${OUTPUT_DIR}
done

# --read-interface options
interface_options () {
  for package in $(ls "${OUTPUT_DIR}"); do
    echo "--read-interface=${package},${OUTPUT_DIR}/${package}/${package}.haddock"
  done
}

haddock -o ${OUTPUT_DIR} \
  --gen-index \
  --gen-contents \
  --quickjump \
  $(interface_options)

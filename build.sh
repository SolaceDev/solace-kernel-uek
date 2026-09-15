#!/bin/bash
set -eu

VERSION=$(make ARCH=x86_64 kernelversion)
[[ -z "$VERSION" ]] && { echo "Error: Couldn't determine kernel version"; exit 1; }

# Read the UEK version suffix from the most recent Oracle UEK merge commit
# in the git history (e.g. "Merge tag 'v6.12.0-200.74.27' into solace-uek-6.12") 
# so it can be embedded in # CONFIG_LOCALVERSION, producing a kernel version like
# 6.12.0-200.74.27.solos1.
read_uek_suffix() {
    local merge_subject uek_tag
    merge_subject=$(git log --merges --format="%s" --grep="Merge tag 'v${VERSION}-" | head -1)
    if [[ -z "$merge_subject" ]]; then
        echo "Warning: No UEK merge commit found for v${VERSION}, UEK suffix will be omitted"
        UEK_SUFFIX=""
        return
    fi
    uek_tag=$(echo "$merge_subject" | sed "s/Merge tag '\\(v${VERSION}-[^']*\\)'.*/\\1/")
    UEK_SUFFIX="${uek_tag#v${VERSION}-}"
    echo "Found UEK merge commit for tag ${uek_tag}, UEK suffix: ${UEK_SUFFIX}"
}
read_uek_suffix

VERSION_WITH_UEK="${VERSION}${UEK_SUFFIX:+-${UEK_SUFFIX}}"
VERSION_PATCH=${VERSION%.*}
LOAD_DIR="/home/public/RND/loads/linux/${VERSION_PATCH}"

# Find the latest build ID by checking existing directories
find_latest_build() {
    local last_id=0
    if [[ -d "${LOAD_DIR}" ]]; then
        # Use find to avoid ARG_MAX issues with large number of directories
        while IFS= read -r -d '' dir; do
            local id="${dir##*.solos}"
            [[ "$id" =~ ^[0-9]+$ ]] && ((id > last_id)) && last_id=$id
        done < <(find "${LOAD_DIR}" -maxdepth 1 -type d -name "${VERSION_WITH_UEK}.solos*" -print0)
    fi
    echo "$last_id"
}

# Update .config with new build version
update_config_version() {
    local build_id=$1
    local localversion="${UEK_SUFFIX:+-${UEK_SUFFIX}}.solos${build_id}"
    [[ -f .config ]] && mv -f .config old.config
    sed "s/^CONFIG_LOCALVERSION=.*$/CONFIG_LOCALVERSION=\"${localversion}\"/" \
        old.config > .config
}

# Setup new version
setup_version() {
    local last_build_id
    last_build_id=$(find_latest_build)
    echo "Last build ID: ${last_build_id}"

    NEW_BUILD_ID=$((last_build_id + 1))
    NEW_VERSION="${VERSION_WITH_UEK}.solos${NEW_BUILD_ID}"
    echo "New version: ${NEW_VERSION}"

    update_config_version "$NEW_BUILD_ID"
}

# Run the actual kernel build
run_build() {
    local build_dir=$1
    shift
    ./build-env/run-dev-env-ol9-kernel make -C "$build_dir" ARCH=x86_64 "$@"
}

# Build the perf tool from the kernel tree (SOL-154026). The perf rpm is no
# longer shipped on the appliance, so build perf alongside the kernel and
# leave the binary at tools/perf/perf for developers to copy to an appliance.
# -w silences the warnings the perf tree produces with the container's gcc.
build_perf() {
    local build_dir=$1
    echo "Building perf"
    run_build "$build_dir/tools/perf" clean
    run_build "$build_dir/tools/perf" -j"$(nproc)" EXTRA_CFLAGS="-w" WERROR=0
}

# Handle CI build (with BUILD_NUMBER set)
ci_build() {
    echo "CI build detected, publishing to ${LOAD_DIR}"

    # Tag and push
    git tag -a "v${NEW_VERSION}" -m "Build solos${NEW_BUILD_ID}"
    git push origin "v${NEW_VERSION}"

    # Setup build directory
    mkdir -p "$LOAD_DIR"
    local build_dir="${LOAD_DIR}/${NEW_VERSION}"
    mkdir "$build_dir"

    # Copy source and build
    echo "Copying kernel source to ${build_dir}"
    cp -diR . "$build_dir"

    local old_pwd="$PWD"
    cd "$build_dir"
    run_build "$build_dir" "$@"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        build_perf "$build_dir"
        rc=$?
    fi

    # Create source archive
    if [[ $rc -eq 0 ]]; then
        echo "Creating source archive..."
        git archive "v${NEW_VERSION}" | gzip > "kernel-${NEW_VERSION}-src.tar.gz"
        touch .keepme
    fi

    cd "$old_pwd"
    echo "Done!"
    return $rc
}

# Main execution
echo "Publish location: ${LOAD_DIR}"
setup_version

if [[ -n "${BUILD_NUMBER:-}" ]]; then
    ci_build "$@"
    rc=$?
else
    run_build . "$@"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        build_perf .
        rc=$?
    fi
fi

exit $rc

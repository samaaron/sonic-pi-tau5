#!/bin/bash
set -e # Quit script on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WORKING_DIR="$(pwd)"
ROOT_DIR="${SCRIPT_DIR}/../.."

cleanup_function() {
    # Restore working directory as it was prior to this script running on exit
    cd "${WORKING_DIR}"
}
trap cleanup_function EXIT

# clear Release dir ready for new build
cd "${ROOT_DIR}"
rm -rf Release
mkdir -p Release
cd Release

# Copy app across
cp -R ../app/build/*.app .

# Copy server across
cd *.app/Contents/Resources
cp -R "${ROOT_DIR}/server/_build" .

RELEASE_APP_DIR=$(find "${ROOT_DIR}/Release" -name "*.app" -type d | head -n 1)


# Now need to fix some things. Firstly, the crypto library found within Elixir releases appears
# to be linked ot the OpenSSL library found on the build machine. This is a problem as the OpenSSL
# library on the build machine may not be available on the target machine. To fix this, we copy the
# OpenSSL library into the release and then update the crypto library to link to the local copy.
cd "${RELEASE_APP_DIR}"/Contents/Resources/_build/prod/rel/bleep/lib/crypto-*/priv/lib

# Use otool to list linked libraries and grep for OpenSSL, then extract the first path
openssl_lib=$(otool -L crypto.so | grep -E '/openssl.*/libcrypto.*\.dylib' | awk '{print $1}')

# Check if the OpenSSL library was found
if [ -n "$openssl_lib" ]; then
    set -x
    echo "OpenSSL library found: $openssl_lib"
    cp "$openssl_lib" .
    filename_with_ext=$(basename "$openssl_lib")
    install_name_tool -change "$openssl_lib" "@loader_path/$filename_with_ext" crypto.so
    install_name_tool -change "$openssl_lib" "@loader_path/$filename_with_ext" otp_test_engine.so
    set +x
else
    echo "No OpenSSL library found in $file"
fi

# Next we need to remove all symlinks in the _build release directory and replace them with the
# actual content (or delete the symlinks if the content is missing)
replace_symlink() {
    local symlink="$1"
    local target=$(readlink "$symlink")

    # Resolve the absolute path of the symlink's target
    local absolute_target
    if [[ "$target" = /* ]]; then
        # Absolute path
        absolute_target="$target"
    else
        # Relative path
        local symlink_dir
        symlink_dir="$(cd "$(dirname "$symlink")" && pwd)"
        absolute_target="$symlink_dir/$target"
    fi
    absolute_target="$(cd "$(dirname "$absolute_target")" && pwd)/$(basename "$absolute_target")"

    if [ -e "$absolute_target" ]; then
        echo "Found symlink: $symlink -> $absolute_target"

        # Preserve permissions of the original symlink
        local permissions
        permissions=$(stat -f "%Lp" "$symlink")

        # Create a temporary location to copy the content
        local tmp_copy="${symlink}.tmp"

        # Check if the symlink points to a file or directory
        if [ -d "$absolute_target" ]; then
            echo "Copying directory $absolute_target to temporary location $tmp_copy"
            cp -R "$absolute_target" "$tmp_copy"
        else
            echo "Copying file $absolute_target to temporary location $tmp_copy"
            cp "$absolute_target" "$tmp_copy"
        fi

        # Remove the symlink and move the copied content to the original location
        echo "Removing symlink $symlink"
        rm "$symlink"

        echo "Renaming $tmp_copy to $symlink"
        mv "$tmp_copy" "$symlink"

        # Restore original permissions
        chmod "$permissions" "$symlink"

        echo "Replaced symlink with actual content and restored permissions."
    else
        # If the target doesn't exist, the symlink is broken
        echo "Warning: Broken symlink detected. Removing $symlink (points to $target)"
        rm "$symlink"
    fi
}

cd "${RELEASE_APP_DIR}"/Contents/Resources/_build

find . -type l | while IFS= read -r symlink; do
    replace_symlink "$symlink"
done

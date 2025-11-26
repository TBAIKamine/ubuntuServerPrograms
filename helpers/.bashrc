SOURCE_DIR="/usr/local/lib/scripts"
source() {
    if [ -f "$1" ]; then
        builtin source "$1"
        return
    fi    
    local candidate="$SOURCE_DIR/$1"
    if [ -f "$candidate" ]; then
        builtin source "$candidate"
        return
    fi
    echo "source: $1 not found (searched: ./ and $SOURCE_DIR)" >&2
    return 1
}

#! @shell@
set -eu -o pipefail +o posix
shopt -s nullglob

if (( "${NIX_DEBUG:-0}" >= 7 )); then
    set -x
fi

path_backup="$PATH"

# That @-vars are substituted separately from bash evaluation makes
# shellcheck think this, and others like it, are useless conditionals.
# shellcheck disable=SC2157
if [[ -n "@coreutils_bin@" && -n "@gnugrep_bin@" ]]; then
    PATH="@coreutils_bin@/bin:@gnugrep_bin@/bin"
fi

source @out@/nix-support/utils.bash


# Parse command line options and set several variables.
# For instance, figure out if linker flags should be passed.
# GCC prints annoying warnings when they are not needed.
dontLink=0
nonFlagArgs=0
cc1=0
# shellcheck disable=SC2193
[[ "@prog@" = *++ ]] && isCpp=1 || isCpp=0
cppInclude=1
cInclude=1

expandResponseParams "$@"
declare -i n=0
nParams=${#params[@]}
while (( "$n" < "$nParams" )); do
    p=${params[n]}
    p2=${params[n+1]:-} # handle `p` being last one
    if [ "$p" = -c ]; then
        dontLink=1
    elif [ "$p" = -S ]; then
        dontLink=1
    elif [ "$p" = -E ]; then
        dontLink=1
    elif [ "$p" = -E ]; then
        dontLink=1
    elif [ "$p" = -M ]; then
        dontLink=1
    elif [ "$p" = -MM ]; then
        dontLink=1
    elif [[ "$p" = -x && "$p2" = *-header ]]; then
        dontLink=1
    elif [[ "$p" = -x && "$p2" = c++* && "$isCpp" = 0 ]]; then
        isCpp=1
    elif [ "$p" = -nostdlib ]; then
        isCpp=-1
    elif [ "$p" = -nostdinc ]; then
        cInclude=0
        cppInclude=0
    elif [ "$p" = -nostdinc++ ]; then
        cppInclude=0
    elif [[ "$p" != -?* ]]; then
        # A dash alone signifies standard input; it is not a flag
        nonFlagArgs=1
    elif [ "$p" = -cc1 ]; then
        cc1=1
    fi
    n+=1
done

# If we pass a flag like -Wl, then gcc will call the linker unless it
# can figure out that it has to do something else (e.g., because of a
# "-c" flag).  So if no non-flag arguments are given, don't pass any
# linker flags.  This catches cases like "gcc" (should just print
# "gcc: no input files") and "gcc -v" (should print the version).
if [ "$nonFlagArgs" = 0 ]; then
    dontLink=1
fi

# Optionally filter out paths not refering to the store.
if [[ "${NIX_ENFORCE_PURITY:-}" = 1 && -n "$NIX_STORE" ]]; then
    rest=()
    nParams=${#params[@]}
    declare -i n=0
    while (( "$n" < "$nParams" )); do
        p=${params[n]}
        p2=${params[n+1]:-} # handle `p` being last one
        if [ "${p:0:3}" = -L/ ] && badPath "${p:2}"; then
            skip "${p:2}"
        elif [ "$p" = -L ] && badPath "$p2"; then
            n+=1; skip "$p2"
        elif [ "${p:0:3}" = -I/ ] && badPath "${p:2}"; then
            skip "${p:2}"
        elif [ "$p" = -I ] && badPath "$p2"; then
            n+=1; skip "$p2"
        elif [ "$p" = -isystem ] && badPath "$p2"; then
            n+=1; skip "$p2"
        else
            rest+=("$p")
        fi
        n+=1
    done
    # Old bash empty array hack
    params=(${rest+"${rest[@]}"})
fi

# Flirting with a layer violation here.
if [ -z "${NIX_BINTOOLS_WRAPPER_FLAGS_SET_@suffixSalt@:-}" ]; then
    source @bintools@/nix-support/add-flags.sh
fi

# Put this one second so libc ldflags take priority.
if [ -z "${NIX_CC_WRAPPER_FLAGS_SET_@suffixSalt@:-}" ]; then
    source @out@/nix-support/add-flags.sh
fi

# Clear march/mtune=native -- they bring impurity.
if [ "$NIX_ENFORCE_NO_NATIVE_@suffixSalt@" = 1 ]; then
    rest=()
    # Old bash empty array hack
    for p in ${params+"${params[@]}"}; do
        if [[ "$p" = -m*=native ]]; then
            skip "$p"
        else
            rest+=("$p")
        fi
    done
    # Old bash empty array hack
    params=(${rest+"${rest[@]}"})
fi

if [[ "$isCpp" = 1 ]]; then
    if [[ "$cppInclude" = 1 ]]; then
        NIX_CFLAGS_COMPILE_@suffixSalt@+=" $NIX_CXXSTDLIB_COMPILE_@suffixSalt@"
    fi
    NIX_CFLAGS_LINK_@suffixSalt@+=" $NIX_CXXSTDLIB_LINK_@suffixSalt@"
fi

source @out@/nix-support/add-hardening.sh

# Add the flags for the C compiler proper.
extraAfter=($NIX_CFLAGS_COMPILE_@suffixSalt@)
extraBefore=(${hardeningCFlags[@]+"${hardeningCFlags[@]}"} $NIX_CFLAGS_COMPILE_BEFORE_@suffixSalt@)

if [ "$dontLink" != 1 ]; then

    # Add the flags that should only be passed to the compiler when
    # linking.
    extraAfter+=($NIX_CFLAGS_LINK_@suffixSalt@)

    # Add the flags that should be passed to the linker (and prevent
    # `ld-wrapper' from adding NIX_LDFLAGS_@suffixSalt@ again).
    for i in $NIX_LDFLAGS_BEFORE_@suffixSalt@; do
        extraBefore+=("-Wl,$i")
    done
    for i in $NIX_LDFLAGS_@suffixSalt@; do
        if [ "${i:0:3}" = -L/ ]; then
            extraAfter+=("$i")
        else
            extraAfter+=("-Wl,$i")
        fi
    done
    export NIX_LDFLAGS_SET_@suffixSalt@=1
fi

# As a very special hack, if the arguments are just `-v', then don't
# add anything.  This is to prevent `gcc -v' (which normally prints
# out the version number and returns exit code 0) from printing out
# `No input files specified' and returning exit code 1.
if [ "$*" = -v ]; then
    extraAfter=()
    extraBefore=()
fi

# clang's -cc1 mode is not compatible with most options
# that we would pass. Rather than trying to pass only
# options that would work, let's just remove all of them.
if [ "$cc1" = 1 ]; then
  extraAfter=()
  extraBefore=()
fi

# Optionally print debug info.
if (( "${NIX_DEBUG:-0}" >= 1 )); then
    # Old bash workaround, see ld-wrapper for explanation.
    echo "extra flags before to @prog@:" >&2
    printf "  %q\n" ${extraBefore+"${extraBefore[@]}"}  >&2
    echo "original flags to @prog@:" >&2
    printf "  %q\n" ${params+"${params[@]}"} >&2
    echo "extra flags after to @prog@:" >&2
    printf "  %q\n" ${extraAfter+"${extraAfter[@]}"} >&2
fi

PATH="$path_backup"
# Old bash workaround, see above.

if (( "${NIX_RESPONSE_FILE_EXPANDED:-0}" >= 1 )); then
    responseFile=$(mktemp --tmpdir cc-params.XXXXXX)
    trap 'rm -f -- "$responseFile"' EXIT
    printf "%q\n" \
       ${extraBefore+"${extraBefore[@]}"} \
       ${params+"${params[@]}"} \
       ${extraAfter+"${extraAfter[@]}"} > "$responseFile"
    @prog@ "@$responseFile"
else
    exec @prog@ \
       ${extraBefore+"${extraBefore[@]}"} \
       ${params+"${params[@]}"} \
       ${extraAfter+"${extraAfter[@]}"}
fi

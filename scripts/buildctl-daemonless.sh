#!/bin/sh
# Borrowed from https://crazymax.dev/buildkit/examples/buildctl-daemonless/#buildctl-daemonless
# buildctl-daemonless.sh spawns ephemeral buildkitd for executing buildctl.
#
# Usage: buildctl-daemonless.sh build ...
#
# Flags for buildkitd can be specified as $BUILDKITD_FLAGS .
#
# The script is compatible with BusyBox shell.
set -euo pipefail

# Function to check if a required variable is set and not empty
require_var() {
    local var_name="$1"
    if [ -z "${!var_name+x}" ]; then
        echo "Error: Required environment variable $var_name is not set"
        exit 1
    elif [ -z "${!var_name}" ]; then
        echo "Error: Required environment variable $var_name is empty"
        exit 1
    fi
}

# check if variable is "truthy"
# evaluates to true if the variable is any of `y`, `yes`, `true`, `t`, '1' (case-insensitive)
# any other value evaluates to false
truthy_env() {
    key=$1

    # Check if variable is set in the environment
    # POSIX: 'set | grep' is portable (BusyBox set is simple)
    if ! set | grep -q "^${key}="; then
        return 1
    fi

    # Retrieve value safely (works under set -u)
    eval "val=\${$key}"

    # Normalize to lowercase (POSIX + BusyBox compatible)
    lower=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        y|yes|1|t|true)
            return 0 ;;
        *)
            return 1 ;;
    esac
}


require_var "BUILDCTL"
require_var "BUILDKITD"
require_var "ROOTLESSKIT"
require_var "XDG_RUNTIME_DIR"
: ${BUILDCTL_CONNECT_RETRIES_MAX=20}
: ${BUILDKITD_FLAGS=}

echo "XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"

# $tmp holds the following files:
# * pid - pid of buildkitd or rootlesskit
# * addr - address where you can connect to buildkitd
# * log - stdout+stderr of buildkitd
# * log_tail_pid - tail -f on log file so that stdout is preserved
tmp=$(mktemp -d /tmp/buildctl-daemonless.XXXXXX)
echo "Runtime dir: $tmp"

trap_cleanup() {
	set +x
	# cleanup tail on log file
    log_tail_pid=$(cat "$tmp/log_tail_pid" 2>/dev/null || true)

    if [ -n "$log_tail_pid" ] && kill -0 "$log_tail_pid" 2>/dev/null; then
		kill -s TERM "$log_tail_pid" 2>/dev/null || true
	fi

    pid=$(cat "$tmp/pid" 2>/dev/null || true)
	# -n - string is non-zero
	# kill -0 - test if the process exists and we can send signal to it
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "Stopping buildkitd (pid=$pid)..."
        kill -s TERM "$pid" 2>/dev/null || true

        # Wait up to 5 seconds for clean exit
        for i in $(seq 1 5); do
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "buildkitd exited"
                break
            fi
            sleep 1
        done

        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            echo "buildkitd did not exit in time, forcibly killing..."
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

	echo "cleaning up runtime dir $tmp"
    rm -rf "$tmp"
}
trap trap_cleanup EXIT

DEBUG_FLAGS=""

if truthy_env DEBUG_BUILD; then
  DEBUG_FLAGS="--debug"
fi

startBuildkitd() {
    addr=
    helper=
    if [ $(id -u) = 0 ]; then
        addr=unix:///run/buildkit/buildkitd.sock
        echo "Running as root"
    else
        addr=unix://$XDG_RUNTIME_DIR/buildkit/buildkitd.sock
        helper=$ROOTLESSKIT
        echo "Running as non-root"
    fi

	set -x
	# log the command to stderr
	$helper "$BUILDKITD" $BUILDKITD_FLAGS $DEBUG_FLAGS --addr="$addr" >>"$tmp/log" 2>&1 &
	set +x
	# gets pid of helper or buildkitd
    pid=$!

	# pipe buildkitd logs to stdout
	tail -F "$tmp/log" &
	log_tail_pid=$!
	
	echo $log_tail_pid >$tmp/log_tail_pid
    echo $pid >$tmp/pid
    echo $addr >$tmp/addr
    echo "Started buildkitd with pid $pid and addr $addr"
}

# buildkitd supports NOTIFY_SOCKET but as far as we know, there is no easy way
# to wait for NOTIFY_SOCKET activation using busybox-builtin commands...
waitForBuildkitd() {
    addr=$(cat $tmp/addr)
    try=0
    max=$BUILDCTL_CONNECT_RETRIES_MAX
    until $BUILDCTL --addr=$addr debug workers >/dev/null 2>&1; do
        if [ $try -gt $max ]; then
            echo >&2 "could not connect to $addr after $max trials"
            echo >&2 "========== log =========="
            cat >&2 $tmp/log
            exit 1
        fi
        sleep $(awk "BEGIN{print (100 + $try * 20) * 0.001}")
        try=$(expr $try + 1)
    done
}

startBuildkitd
waitForBuildkitd
# log the command to stderr
set -x
$BUILDCTL $DEBUG_FLAGS --addr=$(cat $tmp/addr) "$@"
# set +x in trap

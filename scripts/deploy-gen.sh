#!/bin/bash

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

if truthy_env DEBUG; then
	echo "WARNING: DEBUG variable is deprecated. Please set DEBUG_DEPLOY instead" > /dev/stderr
fi

if truthy_env DEBUG_DEPLOY; then
	set -x
fi

dprint() {
	if truthy_env DEBUG_DEPLOY; then
		echo "$@" > /dev/stderr
	fi
}

# which compose files to load
require_var COMPOSE_FILES

# working directory on the target server
require_var WORKDIR

# specifics in the docker compose (maybe delete this?)
require_var VERSION
# require_var REGISTRY_URL
# require_var REGISTRY_NAMESPACE
# require_var IMAGE_NAME

# which container to probe for health
require_var HEALTHCHECK_PROBE

MAX_RETRY=${MAX_RETRY:-30}

FILES_FRAG=""
for f in $COMPOSE_FILES
do
	FILES_FRAG="${FILES_FRAG}--file $f "
done

COMPOSE_CONFIG_ARGS=""
if truthy_env NOLOCK_IMAGES; then
	dprint "won't lock docker image digests"
else
	COMPOSE_CONFIG_ARGS="$COMPOSE_CONFIG_ARGS --resolve-image-digests "
fi

COMPOSE=$(mktemp -t compose.XXXXXXXXX.yml)
SCRIPT=$(mktemp -t deploy.XXXXXXXXX.sh)

CMD="docker compose $FILES_FRAG config $COMPOSE_CONFIG_ARGS"
dprint "exporting docker configuration using '$CMD'"
$CMD > $COMPOSE

dprint "checking if probe container $HEALTHCHECK_PROBE is present in compose file"
if ! docker compose $FILES_FRAG config --services | grep -q "$HEALTHCHECK_PROBE"; then
    echo "Error: Container $HEALTHCHECK_PROBE not found in compose configuration" >&2
    exit 1
fi

dprint "Generating deploy script"
cat > $SCRIPT << 'SCRIPT_END'
#!/bin/bash
if [ -n "$DEBUG" ]; then
	set -x
fi
set -euo pipefail

VERSION="__VERSION__"
WORKDIR="__WORKDIR__"
HEALTHCHECK_PROBE="__HEALTHCHECK_PROBE__"
MAX_RETRY="__MAX_RETRY__"

mkdir -p $WORKDIR
cd $WORKDIR

exec 200>.deploy.lock
lock_fail() {
	echo "Another deployment is already in progress"; 
	exit 3 
}
flock -n 200 || lock_fail

OLD_VERSION=$(readlink current 2>/dev/null | xargs -r basename || echo "none")

echo "-------------- Deploy info --------------"
echo "Working directory: $WORKDIR"
echo "Deploying version: $VERSION"
echo "Max retries for healthy status: $MAX_RETRY"
echo "Previous version: $OLD_VERSION"
echo "-----------------------------------------"
mkdir -p releases/$VERSION

cat > releases/$VERSION/compose.yml<<'COMPOSE_END'
__COMPOSE_CONTENT__
COMPOSE_END
echo "Compose file created"

# Stop old version
if [ "$OLD_VERSION" != "none" ]; then
	echo "Stopping old version: $OLD_VERSION"
	docker compose --file releases/$OLD_VERSION/compose.yml down --remove-orphans
fi

echo "Creating version $VERSION"
docker compose --file releases/$VERSION/compose.yml create

PROBE_CONTAINER=$(docker compose --file releases/$VERSION/compose.yml ps -a -q "$HEALTHCHECK_PROBE" | head -n1)
PROBE_IMAGE=$(docker inspect $PROBE_CONTAINER --format "{{.Image}}")
SUPPORTS_HEALTHCHECK=$(docker image inspect --format "{{.Config.Healthcheck}}" $PROBE_IMAGE)

docker compose --file releases/$VERSION/compose.yml start

commit() {
	# Update symlinks
	ln -sfn releases/$VERSION current
	[ "$OLD_VERSION" != "none" ] && ln -sfn releases/$OLD_VERSION previous

	echo $(date --utc +%Y-%m-%dT%H:%M:%S%Z) > releases/$VERSION/release-date

	# Cleanup old releases (keep last 3)
	echo "cleaning up old releases"
	(cd $WORKDIR/releases && ls -t | tail -n +4 | xargs -r rm -rf)

	echo "✅ Deployment successful: $VERSION"
	exit 0
}

# check if supports healthcheck
if [ "$SUPPORTS_HEALTHCHECK" = '<nil>' ]; then
	echo "WARNING: PROBE_CONTAINER $PROBE_CONTAINER does not support healthcheck. committing"
	commit
fi

echo "Waiting for health check (timeout: 150s)"
for i in $(seq $MAX_RETRY); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' $PROBE_CONTAINER 2>/dev/null || echo "starting")

    if [ "$STATUS" = "healthy" ]; then
        echo "✅ Health check passed"
		commit
    fi

    echo "Waiting for healthy status... (attempt $i/$MAX_RETRY, status: $STATUS)"
    sleep 5
done

if [ "$OLD_VERSION" != "none" ]; then
	echo "Health check timeout, rolling back"
	docker compose --file releases/$VERSION/compose.yml down
    echo "↩️ Rolling back to: $OLD_VERSION"
    docker compose --file releases/$OLD_VERSION/compose.yml up -d
	echo "Cleaning up broken version $VERSION"
	rm -rf releases/$VERSION
	exit 1
else
	echo "Health check timeout, no old version avaliable for rollback"
	exit 2
fi

SCRIPT_END

# Inject variables into script
sed -i "s|__VERSION__|$VERSION|g" $SCRIPT
sed -i "s|__WORKDIR__|$WORKDIR|g" $SCRIPT
sed -i "s|__HEALTHCHECK_PROBE__|$HEALTHCHECK_PROBE|g" $SCRIPT
sed -i "s|__MAX_RETRY__|$MAX_RETRY|g" $SCRIPT

# Inject compose content (preserve line by line)
COMPOSE_TEMP=$(mktemp)
cat $COMPOSE > $COMPOSE_TEMP
sed -i -e "/__COMPOSE_CONTENT__/r $COMPOSE_TEMP" -e "/__COMPOSE_CONTENT__/d" $SCRIPT
rm $COMPOSE_TEMP
rm $COMPOSE

echo $SCRIPT

#!/bin/bash
set -xeuo pipefail

echo "" > .deploy-scripts
TMPDIR=$(mktemp -d -t deploy-gen.test.XXXXXXXX)
echo "Working dir: $TMPDIR"

trap_cleanup() {
	VERSION=any docker compose -f ./data/compose.yml kill || true
	VERSION=any docker compose -f ./data/compose.yml down || true
	docker image rm deploy-gen:healthy-1 || true
	docker image rm deploy-gen:healthy-2 || true
	docker image rm deploy-gen:broken || true
	echo "State of working directory:"
	tree $TMPDIR
	rm -rf $TMPDIR
}
trap trap_cleanup EXIT

deploy() {
	export HEALTHCHECK_PROBE="test"
	export COMPOSE_FILES="./data/compose.yml"
	export WORKDIR=$TMPDIR
	export MAX_RETRY=4
	export NOLOCK_IMAGES="y"
	echo "Generating script ($1)"
	SCRIPT=$(VERSION=$1 ../deploy-gen.sh)
	echo $SCRIPT >> .deploy-scripts
	echo "Executing script ($1)"
	set +e
	bash $SCRIPT
	CODE=$?
	echo "Deploy script exit code: $CODE"
	set -e
}

echo "Building test images"
HEALTHY_1_IMG=$(docker buildx build --load -t deploy-gen:healthy-1 -f ./data/healthy-1.Dockerfile -q ./bin)
HEALTHY_2_IMG=$(docker buildx build --load -t deploy-gen:healthy-2 -f ./data/healthy-2.Dockerfile -q ./bin)
BROKEN_IMG=$(docker buildx build --load -t deploy-gen:broken -f ./data/broken.Dockerfile -q ./bin)

deploy "healthy-1"

HEALTH=$(docker inspect --format='{{.State.Health.Status}}' test-test-1)
if [ "$HEALTH" = "healthy" ]; then
	echo "OK: container reporting healthy"
else
	echo "FAIL: first stage of this test should report healthy container, but instead reporting $HEALTH"
	exit 1
fi

TAG=$(docker inspect --format='{{.Image}}' test-test-1)
if [ "$TAG" = "$HEALTHY_1_IMG" ]; then
	echo "OK: stage 1 test should have healthy-1 image"
fi

deploy "healthy-2"

HEALTH=$(docker inspect --format='{{.State.Health.Status}}' test-test-1)
if [ "$HEALTH" = "healthy" ]; then
	echo "OK: container reporting healthy"
else
	echo "FAIL: second stage of this test should report healthy container, but instead reporting $HEALTH"
	exit 1
fi

TAG=$(docker inspect --format='{{.Image}}' test-test-1)
if [ "$TAG" = "$HEALTHY_2_IMG" ]; then
	echo "OK: stage 2 test should have healthy-2 image"
else
	TAGS=$(docker image inspect --format "{{.RepoTags}}" $TAG)
	echo "FAIL: second stage should have healthy-2 image, but instead has image with tags: $TAGS"
	exit 1
fi

deploy "broken"
if [ $CODE -ne 0 ]; then
	echo "OK: deploy script returned error code as expected"
else
	echo "FAIL: deploy script should have returned non-zero exit code"
	exit 1
fi

HEALTH=$(docker inspect --format='{{.State.Health.Status}}' test-test-1)
if [ "$HEALTH" != "healthy" ]; then
	echo "OK: container healthy after rollback"
else
	echo "FAIL: third stage of test should have rolled back deployment"
	exit 1
fi

TAG=$(docker inspect --format='{{.Image}}' test-test-1)
if [ "$TAG" = "$HEALTHY_2_IMG" ]; then
	echo "OK: deployment rolled back successfully"
else
	TAGS=$(docker image inspect --format "{{.RepoTags}}" $TAG)
	echo "FAIL: deployment did not roll back. currently running image has tags: $TAGS"
	exit 1
fi

echo "----------- Everything ok -----------"

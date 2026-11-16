#!/usr/bin/env bash
#
# rbd_mirror_telemetry_leaks.sh - check that the telemetry report does
# not contain the pool, namespace and image names that rbd-mirror's
# per-image perf counters (rbd_mirror_snapshot_image) carry in their labels.
#
# Mirrors two images (one in the default namespace, one in a namespace) in
# snapshot mode from cluster1 to cluster2, with rbd-mirror running on
# cluster2 only, and then checks cluster2's telemetry report the same way as
# qa/workunits/mgr/test_telemetry_leaks.sh does for the other daemons.
#

set -ex

RBD_MIRROR_INSTANCES=${RBD_MIRROR_INSTANCES:-1}
RBD_MIRROR_MANUAL_PEERS=1
RBD_MIRROR_MODE=snapshot
. $(dirname $0)/rbd_mirror_helpers.sh
. $(dirname $0)/../mgr/telemetry_leaks_helpers.sh

POOL=${TELEMETRY_LEAK_MARKER}_mirror_pool
NS1=${TELEMETRY_LEAK_MARKER}_ns
IMAGE=${TELEMETRY_LEAK_MARKER}_mirror_image

TELEMETRY_CEPH=(env CEPH_ARGS= ceph --cluster ${CLUSTER2})

setup

testlog "TEST: bootstrap ${CLUSTER2} from ${CLUSTER1}"
TOKEN=${TEMPDIR}/peer-token
CEPH_ARGS='' rbd --cluster ${CLUSTER1} mirror pool peer bootstrap create ${POOL} > ${TOKEN}
CEPH_ARGS='' rbd --cluster ${CLUSTER2} --pool ${POOL} mirror pool peer bootstrap import ${TOKEN} --direction rx-only

testlog "TEST: mirror ${POOL}/${IMAGE} and ${POOL}/${NS1}/${IMAGE}"
start_mirrors ${CLUSTER2}
create_image_and_enable_mirror ${CLUSTER1} ${POOL} ${IMAGE}
create_image_and_enable_mirror ${CLUSTER1} ${POOL}/${NS1} ${IMAGE}
wait_for_image_replay_started ${CLUSTER2} ${POOL} ${IMAGE}
wait_for_image_replay_started ${CLUSTER2} ${POOL}/${NS1} ${IMAGE}
write_image ${CLUSTER1} ${POOL} ${IMAGE} 100
write_image ${CLUSTER1} ${POOL}/${NS1} ${IMAGE} 100
wait_for_replay_complete ${CLUSTER2} ${CLUSTER1} ${POOL} ${POOL} ${IMAGE}
wait_for_replay_complete ${CLUSTER2} ${CLUSTER1} ${POOL}/${NS1} ${POOL}/${NS1} ${IMAGE}

testlog "TEST: telemetry report of ${CLUSTER2}"
telemetry_check_no_leaks

# the counters that carry our names were in the report: one per image
telemetry_expect_counter rbd_mirror_snapshot_image 2

echo OK

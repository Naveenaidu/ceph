#!/usr/bin/env bash
#
# test_telemetry_leaks.sh - check that the telemetry report does not
# contain the user-chosen names that labeled perf counters carry.
#
# Labeled perf counters (see key_create() in src/common/perf_counters_key.h)
# often hold names that the user chose: CephFS file system names and
# subvolume paths, RGW users and buckets, RBD pools and images. The telemetry
# module has to anonymize these labels before it reports them.
#
# This creates a file system, a subvolume, an RGW user and a bucket with
# TELEMETRY_LEAK_MARKER in their names, does the I/O that makes the MDS and RGW
# create their labeled perf counters, waits TELEMETRY_WAIT seconds, and then
# checks with 'ceph telemetry preview-all' that none of the names appears
# anywhere in the report, in any channel. It keeps writing to the subvolume
# until then, since the MDS removes a subvolume's perf counters after 30s
# without I/O.
#
# The rbd-mirror per-image counters need two clusters, see
# qa/workunits/rbd/rbd_mirror_telemetry_leaks.sh.
#
# Needs:
#  - a spare MDS daemon for the file system the test creates
#  - an rgw with rgw_user_counters_cache and rgw_bucket_counters_cache set to
#    true, listening on RGW_HOST:RGW_PORT
#  - s3cmd, jq, ceph-fuse and sudo
#
# To run it against a vstart cluster (from the build directory):
#   PATH=$PWD/bin:$PATH RGW_PORT=8000 \
#     CEPH_FUSE_ARGS="-c $PWD/ceph.conf -k $PWD/keyring" \
#     ../qa/workunits/mgr/test_telemetry_leaks.sh

set -ex

. $(dirname $0)/telemetry_leaks_helpers.sh

RGW_HOST=${RGW_HOST:-localhost}
RGW_PORT=${RGW_PORT:-80}
CEPH_FUSE_ARGS=${CEPH_FUSE_ARGS:-}

FS=${TELEMETRY_LEAK_MARKER}_fs
GROUP=${TELEMETRY_LEAK_MARKER}_group
SUBVOL=${TELEMETRY_LEAK_MARKER}_subvol
RGW_USER=${TELEMETRY_LEAK_MARKER}_user
RGW_ACCESS_KEY=${TELEMETRY_LEAK_MARKER}key
RGW_SECRET_KEY=${TELEMETRY_LEAK_MARKER}secret
BUCKET=${TELEMETRY_LEAK_MARKER}-bucket

MNT=$(mktemp -d -t telemetry-leaks-mnt.XXXXXX)
S3CFG=$(mktemp -t telemetry-leaks-s3cfg.XXXXXX)
WRITER=

cleanup()
{
    local rc=$?

    set +e
    if [ -n "${WRITER}" ]; then
        kill ${WRITER}
        wait ${WRITER}
    fi
    sudo umount ${MNT}
    rmdir ${MNT}
    rm -f ${S3CFG}
    echo "last telemetry report is in ${TELEMETRY_REPORT}"
    exit ${rc}
}
trap cleanup EXIT

# CephFS: mds_client_metrics has an fs_name label. Once a client does I/O in
# a subvolume, the MDS also adds mds_subvolume_metrics, with fs_name and
# subvolume_path labels, and mds_client_metrics-<fs_name>, with the file
# system name in the collection name itself.
ceph fs volume create ${FS}
ceph fs subvolumegroup create ${FS} ${GROUP}
ceph fs subvolume create ${FS} ${SUBVOL} --group_name ${GROUP}
SUBPATH=$(ceph fs subvolume getpath ${FS} ${SUBVOL} --group_name ${GROUP})
sudo ceph-fuse ${CEPH_FUSE_ARGS} --client_fs ${FS} ${MNT}
sudo dd if=/dev/zero of=${MNT}${SUBPATH}/file bs=1M count=4 conv=fsync

# the MDS removes mds_subvolume_metrics after subv_metrics_window_interval
# (30s) without I/O to the subvolume: keep writing to it until the report has
# been checked (cleanup stops this)
(
    set +x
    while true; do
        sudo dd if=/dev/zero of=${MNT}${SUBPATH}/file bs=4k count=1 \
             conv=fsync status=none
        sleep 1
    done
) &
WRITER=$!

# RGW: with rgw_{user,bucket}_counters_cache, rgw_op_per_user has a user
# label and rgw_op_per_bucket a bucket label.
#
# the port must not be part of host_base when it is 80, for the v4 signature
# to match
HOST_BASE=${RGW_HOST}
if [ ${RGW_PORT} -ne 80 ]; then
    HOST_BASE=${RGW_HOST}:${RGW_PORT}
fi
cat > ${S3CFG} <<EOF
[default]
access_key = ${RGW_ACCESS_KEY}
secret_key = ${RGW_SECRET_KEY}
host_base = ${HOST_BASE}
host_bucket = ${HOST_BASE}
use_https = False
EOF
radosgw-admin user create --uid ${RGW_USER} --display-name x \
    --access-key ${RGW_ACCESS_KEY} --secret ${RGW_SECRET_KEY}
s3cmd -c ${S3CFG} mb s3://${BUCKET}
s3cmd -c ${S3CFG} put /etc/hostname s3://${BUCKET}/obj1

telemetry_check_no_leaks

# the counters that carry our names were in the report. Only our subvolume
# gets I/O and only our RGW user makes requests, so these collections can only
# come from our names. The cluster has another file system, so for the one
# that holds the fs name in its collection name, look for ours, hashed.
telemetry_expect_counter mds_client_metrics-$(telemetry_hash ${FS})
telemetry_expect_counter mds_subvolume_metrics
telemetry_expect_counter rgw_op_per_user
telemetry_expect_counter rgw_op_per_bucket

echo OK

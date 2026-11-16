# telemetry_leaks_helpers.sh - shared functions for the workunits that
# check that the telemetry report does not contain user-chosen names (file
# systems, subvolumes, RGW users and buckets, pools, RBD images, ...), such as
# the ones that labeled perf counters carry in their labels.
#
# Sourced by:
#   qa/workunits/mgr/test_telemetry_leaks.sh
#   qa/workunits/rbd/rbd_mirror_telemetry_leaks.sh
#
# The tests put TELEMETRY_LEAK_MARKER in the name of everything they create,
# so a plain grep of a report for TELEMETRY_LEAK_MARKER finds a name wherever
# and in whatever form it leaks (in a label, in a collection name, inside a
# path, in any channel, ...).
#
# The report comes from 'ceph telemetry preview-all' with every channel
# enabled: it is the whole report (all channels and the device report) built
# with all collections, without opting in to telemetry, so no report is ever
# sent.
#
# A report without the counters that carry our names would pass the grep
# too, so after telemetry_check_no_leaks the tests also check with
# telemetry_expect_counter that these counters are in the report.

TELEMETRY_LEAK_MARKER=telemetryleakmarker

TELEMETRY_CHANNELS=(basic crash device ident perf)

# how long to give the daemons to create their labeled perf counters and
# send them to the mgr before checking the report: it takes them ~15s at
# most (client tick 1s + mds_metrics_update_interval 2s + mgr_stats_period 5s)
TELEMETRY_WAIT=${TELEMETRY_WAIT:-30}

# the report, kept for debugging
TELEMETRY_REPORT=$(mktemp -t telemetry-leaks.XXXXXX)

# command that talks to the cluster under test; override it after sourcing
# this file, e.g. TELEMETRY_CEPH=(env CEPH_ARGS= ceph --cluster cluster2)
TELEMETRY_CEPH=(ceph)

# the salt that the telemetry module anonymizes names with, set by
# telemetry_check_no_leaks
TELEMETRY_SALT=

# telemetry_check_no_leaks: wait TELEMETRY_WAIT seconds, then fail if the
# whole telemetry report holds any of our names in plain text
telemetry_check_no_leaks()
{
    # 'preview-all' covers the enabled channels only, and ident and perf are
    # off by default. Enabling a channel does not opt in to telemetry.
    local channel
    for channel in "${TELEMETRY_CHANNELS[@]}"; do
        "${TELEMETRY_CEPH[@]}" config set mgr mgr/telemetry/channel_${channel} true
    done

    sleep ${TELEMETRY_WAIT}

    "${TELEMETRY_CEPH[@]}" telemetry preview-all > ${TELEMETRY_REPORT}

    # 'preview-all' prints a message instead of a report when telemetry is
    # already opted in to all collections, and a report without all channels
    # would not check them all; grepping either would pass too easily
    if ! jq -e '(.report.channels | sort) == ($ARGS.positional | sort) and
                (.report | has("perf_counters")) and has("device_report")' \
            ${TELEMETRY_REPORT} --args "${TELEMETRY_CHANNELS[@]}" > /dev/null; then
        echo "ERROR: 'telemetry preview-all' did not return a report of all channels:" >&2
        cat ${TELEMETRY_REPORT} >&2
        return 1
    fi

    # for the log: the labeled perf counters that were checked
    jq -c '.report.perf_counters[] | to_entries[] |
           select(any(.value[]; .labels != {})) |
           {(.key): [.value[].labels]}' ${TELEMETRY_REPORT}

    if grep -n ${TELEMETRY_LEAK_MARKER} ${TELEMETRY_REPORT}; then
        echo "ERROR: the telemetry report contains user-chosen names" >&2
        return 1
    fi

    # the telemetry module creates the salt when it starts
    TELEMETRY_SALT=$("${TELEMETRY_CEPH[@]}" config-key get mgr/telemetry/salt)
}

# telemetry_hash <name>: print <name> anonymized the way the telemetry module
# does it (_salted_hash() in src/pybind/mgr/telemetry/module.py)
telemetry_hash()
{
    if [ -z "${TELEMETRY_SALT}" ]; then
        echo "ERROR: telemetry_hash called before telemetry_check_no_leaks" >&2
        return 1
    fi
    printf '%s%s%s' "${TELEMETRY_SALT}" "$1" "${TELEMETRY_SALT}" |
        sha1sum | cut -d' ' -f1
}

# telemetry_expect_counter <collection> [<count>]: fail unless the report
# that telemetry_check_no_leaks checked has at least <count> (1 by default)
# instances of the <collection> perf counter, from any daemon. Use it for
# collections that only the test's own names create, or whose name holds a
# name hashed with telemetry_hash.
telemetry_expect_counter()
{
    local collection=$1
    local count=${2:-1}

    if ! jq -e --arg c "${collection}" --argjson n "${count}" \
            '[.report.perf_counters[][$c][]?] | length >= $n' \
            ${TELEMETRY_REPORT} > /dev/null; then
        echo "ERROR: the telemetry report has fewer than ${count}" \
             "${collection} perf counters" >&2
        return 1
    fi
}

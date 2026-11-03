import json
import pickle
import pytest
import unittest
from collections import defaultdict
from unittest import mock

import telemetry
from typing import cast, Any, DefaultDict, Dict, List, Optional, Tuple, TypeVar, TYPE_CHECKING, Union

OptionValue = Optional[Union[bool, int, float, str]]

Collection = telemetry.module.Collection
ALL_CHANNELS = telemetry.module.ALL_CHANNELS
MODULE_COLLECTION = telemetry.module.MODULE_COLLECTION

COLLECTION_BASE = ["basic_base", "device_base", "crash_base", "ident_base"]

class TestTelemetry:
    @pytest.mark.parametrize("preconfig,postconfig,prestore,poststore,expected",
            [
                (
                    # user is not opted-in
                    {
                        'last_opt_revision': 1,
                        'enabled': False,
                    },
                    {
                        'last_opt_revision': 1,
                        'enabled': False,
                    },
                    {
                        # None
                    },
                    {
                        'collection': []
                    },
                    {
                        'is_opted_in': False,
                        'is_enabled_collection':
                        {
                            'basic_base': False,
                            'basic_mds_metadata': False,
                        },
                    },
                ),
                (
                    # user is opted-in to an old revision
                    {
                        'last_opt_revision': 2,
                        'enabled': True,
                    },
                    {
                        'last_opt_revision': 2,
                        'enabled': True,
                    },
                    {
                        # None
                    },
                    {
                        'collection': []
                    },
                    {
                        'is_opted_in': False,
                        'is_enabled_collection':
                        {
                            'basic_base': False,
                            'basic_mds_metadata': False,
                        },
                    },
                ),
                (
                    # user is opted-in to the latest revision
                    {
                        'last_opt_revision': 3,
                        'enabled': True,
                    },
                    {
                        'last_opt_revision': 3,
                        'enabled': True,
                    },
                    {
                        # None
                    },
                    {
                        'collection': COLLECTION_BASE
                    },
                    {
                        'is_opted_in': True,
                        'is_enabled_collection':
                        {
                            'basic_base': True,
                            'basic_mds_metadata': False,
                        },
                    },
                ),
            ])
    def test_upgrade(self,
                preconfig: Dict[str, Any], \
                postconfig: Dict[str, Any], \
                prestore: Dict[str, Any], \
                poststore: Dict[str, Any], \
                expected: Dict[str, Any]) -> None:

        m = telemetry.Module('telemetry', '', '')

        if preconfig is not None:
            for k, v in preconfig.items():
                # no need to mock.patch since _ceph_set_module_option() which
                # is called from set_module_option() is already mocked for
                # tests, and provides setting default values for all module
                # options
                m.set_module_option(k, v)

        m.config_update_module_option()
        m.load()

        collection = json.loads(m.get_store('collection'))

        assert collection == poststore['collection']
        assert m.is_opted_in() == expected['is_opted_in']
        assert m.is_enabled_collection(Collection.basic_base) == expected['is_enabled_collection']['basic_base']
        assert m.is_enabled_collection(Collection.basic_mds_metadata) == expected['is_enabled_collection']['basic_mds_metadata']

    def test_defaultdict_helpers_are_picklable(self) -> None:
        """Regression test for pickle serialization of defaultdict factories.

        The telemetry report returned through mgr.remote() must be pickle-serializable.
        Verify that the module-level defaultdict factories can be pickled.
        """
        factories = [
            telemetry.module._defaultdict_list,
            telemetry.module._defaultdict_dict,
            telemetry.module._defaultdict_defaultdict_int,
            telemetry.module._defaultdict_histogram,
        ]

        for factory in factories:
            d = defaultdict(factory)
            restored = pickle.loads(pickle.dumps(d))
            assert restored is not None, \
                f"defaultdict({factory.__name__}) failed pickle round-trip"


# User-chosen names that labeled perf counters carry; none of them may appear
# in a telemetry report.
PERF_LABEL_NAMES = [
    'secret_fs',
    '/volumes/secret_group/secret_subvol',
    'secret_pool',
    'secret_ns',
    'secret_image',
    'secret_user',
    'secret_tenant',
    'secret-bucket',
    'secret_topic',
    'secret_peer_cluster',
    'secret_peer_fs',
    '/secret_dir',
    'secret-zone-id',
]


def _labeled(labels: Dict[str, str]) -> Dict[str, Any]:
    return {
        'labels': labels,
        'counters': {
            'some_counter': {
                'description': 'some counter',
                'nick': '',
                'type': 10,
                'priority': 5,
                'units': 1,
                'value': 42,
            },
        },
    }


# get_perf_counters() output with one sample of every labeled perf counter
# in the tree.
PERF_COUNTERS = {
    'mds.a': {
        'mds_client_metrics': [
            _labeled({'fs_name': 'secret_fs', 'id': '4137'})],
        'mds_client_metrics-secret_fs': [
            _labeled({'client': 'client.4192', 'rank': '0'})],
        'mds_subvolume_metrics': [
            _labeled({'subvolume_path': '/volumes/secret_group/secret_subvol',
                      'fs_name': 'secret_fs'})],
        'mds_rank_perf': [
            _labeled({'rank': '0'})],
        'AsyncMessenger::Worker': [
            _labeled({'id': '1'})],
    },
    'osd.0': {
        'osd_scrub_sh_repl': [
            _labeled({'level': 'shallow', 'pooltype': 'replicated'})],
        'osd_scrub_dp_ec': [
            _labeled({'level': 'deep', 'pooltype': 'ec'})],
    },
    'client.rbd-mirror.a': {
        'rbd_mirror_snapshot_image': [
            _labeled({'pool': 'secret_pool', 'namespace': 'secret_ns',
                      'image': 'secret_image'})],
        'rbd_mirror_journal_image': [
            _labeled({'pool': 'secret_pool', 'namespace': '',
                      'image': 'secret_image'})],
    },
    'client.rgw.a': {
        'rgw_op_per_user': [
            _labeled({'user': 'secret_user', 'tenant': 'secret_tenant'})],
        'rgw_op_per_bucket': [
            _labeled({'bucket': 'secret-bucket', 'tenant': 'secret_tenant'})],
        'rgw_topic': [
            _labeled({'topic': 'secret_topic'})],
        'rgw_sync_delta': [
            _labeled({'local_zone_id': 'secret-zone-id',
                      'source_zone_id': 'secret-zone-id',
                      'shard_id': '3'})],
    },
    'client.cephfs-mirror.a': {
        'cephfs_mirror_mirrored_filesystems': [
            _labeled({'filesystem': 'secret_fs'})],
        'cephfs_mirror_directory': [
            _labeled({'source_fscid': '1',
                      'source_filesystem': 'secret_fs',
                      'peer_uuid': 'secret-zone-id',
                      'peer_cluster_name': 'secret_peer_cluster',
                      'peer_cluster_filesystem': 'secret_peer_fs',
                      'directory': '/secret_dir'})],
    },
}


class TestPerfLabelAnonymization:
    SALT = '3f0c1e2a-6b9d-4c51-a2f7-0d8e9b4c7a11'

    def _module(self, salt: Optional[str] = SALT) -> Any:
        m = telemetry.Module('telemetry', '', '')
        m.salt = salt
        return m

    def _gather(self, m: Any, mode: str) -> Dict[str, Any]:
        with mock.patch.object(m, 'get_perf_counters', return_value=PERF_COUNTERS):
            return json.loads(json.dumps(m.gather_perf_counters(mode)))

    def test_no_names_in_report(self) -> None:
        # the report only uses 'separated' mode
        report = json.dumps(self._gather(self._module(), 'separated'))
        for name in PERF_LABEL_NAMES:
            assert name not in report
        # 'secret' is part of every name above, so this also catches a name
        # that leaked in a modified form
        assert 'secret' not in report

    def test_safe_labels_are_kept(self) -> None:
        m = self._module()
        assert m.anonymize_perf_labels({'level': 'shallow', 'pooltype': 'replicated'}) == \
            {'level': 'shallow', 'pooltype': 'replicated'}
        assert m.anonymize_perf_labels({'level': 'deep', 'pooltype': 'ec'}) == \
            {'level': 'deep', 'pooltype': 'ec'}
        assert m.anonymize_perf_labels(
            {'rank': '0', 'id': '4137', 'shard_id': '3', 'source_fscid': '12'}) == \
            {'rank': '0', 'id': '4137', 'shard_id': '3', 'source_fscid': '12'}

    @pytest.mark.parametrize('labels', [
        # a name under a key that is not anonymized for its usual values
        {'id': 'secret-bucket'},
        {'rank': 'secret_fs'},
        {'shard_id': '3secret'},
        {'source_fscid': '1 secret_fs'},
        {'level': 'deep-secret'},
        {'pooltype': 'secret_pool'},
    ])
    def test_names_under_safe_keys_are_anonymized(self, labels: Dict[str, str]) -> None:
        m = self._module()
        anonymized = m.anonymize_perf_labels(labels)
        for key, value in labels.items():
            assert anonymized[key] == m._salted_hash(value)

    def test_names_are_anonymized(self) -> None:
        m = self._module()
        labels = {'fs_name': 'secret_fs',
                  'subvolume_path': '/volumes/secret_group/secret_subvol',
                  'pool': 'secret_pool',
                  'image': 'secret_image',
                  'some_future_label': 'secret_thing'}
        anonymized = m.anonymize_perf_labels(labels)
        assert anonymized.keys() == labels.keys()
        for key, value in labels.items():
            assert anonymized[key] == m._salted_hash(value)
            assert len(anonymized[key]) == 40

    def test_empty_label_is_kept(self) -> None:
        # e.g. the default RBD namespace
        assert self._module().anonymize_perf_labels({'namespace': ''}) == {'namespace': ''}

    def test_client_label_is_anonymized_like_entity_names(self) -> None:
        m = self._module()
        anonymized = m.anonymize_perf_labels({'client': 'client.4192'})
        assert anonymized == {'client': m.anonymize_entity_name('client.4192')}
        assert anonymized['client'].startswith('client.')
        assert '4192' not in anonymized['client']
        # not an entity name: anonymize the whole value
        assert m.anonymize_perf_labels({'client': 'secret'}) == \
            {'client': m._salted_hash('secret')}

    def test_collection_name_is_anonymized(self) -> None:
        m = self._module()
        report = self._gather(m, 'separated')
        mds = report[m.anonymize_entity_name('mds.a')]
        fs_hash = m._salted_hash('secret_fs')
        assert 'mds_client_metrics-secret_fs' not in mds
        assert 'mds_client_metrics-' + fs_hash in mds
        # the collection name and the fs_name label hash to the same value
        assert mds['mds_client_metrics'][0]['labels']['fs_name'] == fs_hash
        # other collection names are unchanged
        assert m.anonymize_perf_collection('mds_client_metrics') == 'mds_client_metrics'
        assert m.anonymize_perf_collection('AsyncMessenger::Worker') == \
            'AsyncMessenger::Worker'
        assert m.anonymize_perf_collection('mds_client_metrics-') == 'mds_client_metrics-'

    def test_counter_values_are_kept(self) -> None:
        m = self._module()
        report = self._gather(m, 'separated')
        sub = report['osd.0']['osd_scrub_sh_repl'][0]
        assert sub['labels'] == {'level': 'shallow', 'pooltype': 'replicated'}
        assert sub['counters'] == {'some_counter': {'value': 42}}

    def test_hash_depends_on_salt(self) -> None:
        a = self._module('salt-a')
        b = self._module('salt-b')
        assert a._salted_hash('secret_fs') == a._salted_hash('secret_fs')
        assert a._salted_hash('secret_fs') != b._salted_hash('secret_fs')
        assert a._salted_hash('secret_fs') != a._salted_hash('secret_fs2')

    def test_no_salt(self) -> None:
        # used to raise UnboundLocalError (missing 'global NO_SALT_CNT')
        m = self._module(None)
        report = json.dumps(self._gather(m, 'separated'))
        assert 'secret' not in report
        assert m.anonymize_entity_name('mds.a').startswith('mds.')

JAEGER DISTRIBUTED TRACING
==========================

Ceph tracing is now based on OpenTelemetry. The older blkin tracing
documentation and implementation were removed as tracing support was migrated to
OpenTelemetry-based spans exported to Jaeger.

In the current implementation, Ceph creates OpenTelemetry spans and uses a
Jaeger exporter to send them to a Jaeger agent. Jaeger remains the easiest way
to collect and inspect Ceph traces during development.

BASIC ARCHITECTURE AND TERMINOLOGY
----------------------------------

For a high-level overview of traces, spans, Jaeger agents, collectors, and the
Jaeger UI, refer to the `Ceph Tracing documentation
<../../../jaegertracing/#basic-architecture-and-terminology>`_.

MIGRATION NOTE
--------------

If you are working from older documentation or scripts, replace any blkin-based
setup with the OpenTelemetry-based tracing described here. In particular:

- build Ceph with ``-DWITH_JAEGER=ON``
- enable tracing with ``jaeger_tracing_enable``
- run a Jaeger agent or Jaeger all-in-one instance that accepts spans on the
  configured Jaeger agent port

HOW TO GET STARTED USING TRACING
--------------------------------

For developer testing, the usual workflow is:

#. install the tracing dependencies
#. build Ceph with Jaeger support enabled
#. start a Jaeger backend
#. enable Ceph tracing
#. generate traced operations and inspect them in Jaeger

1. Install dependencies
^^^^^^^^^^^^^^^^^^^^^^^

Use ``install-deps.sh`` with Jaeger support enabled::

  $ WITH_JAEGER=true ./install-deps.sh

2. Build Ceph with tracing support
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Build Ceph with ``WITH_JAEGER`` enabled.

For an existing build directory::

  $ cd build
  $ cmake -DWITH_JAEGER=ON ..
  $ ninja

For a fresh build using ``do_cmake.sh``::

  $ ./do_cmake.sh -DWITH_JAEGER=ON
  $ ninja -C build vstart

3. Start Jaeger
^^^^^^^^^^^^^^^

For local development, ``vstart.sh --with-jaeger`` can deploy a Jaeger
all-in-one container for you::

  $ MON=1 MGR=0 OSD=1 ../src/vstart.sh --with-jaeger

If automatic deployment is unsuccessful, you can start Jaeger manually and run
``vstart.sh`` without ``--with-jaeger``. A suitable single-node test
deployment is documented in :doc:`../../../jaegertracing/index`.

.. note::

   Ceph's Jaeger exporter sends spans to a Jaeger agent port configured by
   ``jaeger_agent_port``. For manual Jaeger all-in-one deployments, use the
   Ceph documentation's recommended port mapping and startup option so the
   agent listens on port ``6799`` instead of Jaeger's default ``6831``.

4. Enable tracing in Ceph
^^^^^^^^^^^^^^^^^^^^^^^^^

Tracing is disabled by default. After starting the cluster, enable it with:

.. prompt:: bash $

   ceph config set global jaeger_tracing_enable true

You can also enable tracing for a single daemon or daemon type instead of
globally:

.. prompt:: bash $

   ceph config set <entity> jaeger_tracing_enable true

Examples of ``<entity>`` include ``osd`` or ``rgw``.

5. Generate traced operations
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Generate some traced activity, for example with ``rados bench``::

  $ bin/rados -p test bench 5 write --no-cleanup

Then open the Jaeger UI and look for Ceph services such as the traced daemon's
service name.

PRACTICAL NOTES
---------------

- Tracing code compiles to no-op behavior when Ceph is built without
  ``WITH_JAEGER=ON``.
- Cross-daemon child spans depend on serialized OpenTelemetry span context. This
  is relevant when reading or extending tracing code, because the parent-child
  relationship across message boundaries is reconstructed from the propagated
  span context rather than from an in-memory span pointer.
- For cluster-wide or cephadm-managed tracing deployments, see
  :doc:`../../../jaegertracing/index`.

.. seealso::

   `using-jaeger-cpp-client-for-distributed-tracing-in-ceph <https://medium.com/@deepikaupadhyay/using-jaeger-cpp-client-for-distributed-tracing-in-ceph-8b1f4906ca2>`_
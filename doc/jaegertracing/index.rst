.. _jaegertracing:

JAEGER DISTRIBUTED TRACING
==========================

Ceph tracing is based on OpenTelemetry spans that are exported to Jaeger.
Older blkin-based tracing has been removed and replaced by the current
OpenTelemetry-based implementation.

BASIC ARCHITECTURE AND TERMINOLOGY
----------------------------------

* TRACE: A trace shows the data/execution path through a system.
* SPAN: A single unit within a trace. A span records information such as an
  operation name, timestamps, and parent-child relationships.
* OPENTELEMETRY IN CEPH: Ceph instruments operations with OpenTelemetry APIs and
  propagates span context between components so related work appears in the same
  trace.
* JAEGER AGENT: A daemon that listens for spans sent over UDP. The agent is
  typically placed on the same host as the instrumented application.
* JAEGER COLLECTOR: A daemon that receives spans from agents and stores or
  forwards them for querying.
* JAEGER QUERY AND CONSOLE FRONTEND: The UI-based frontend that presents trace
  data. It is typically accessible at ``http://<jaeger-host>:16686``.

Read more about Jaeger tracing:

https://www.jaegertracing.io/docs/

JAEGER DEPLOYMENT
-----------------

Jaeger can be deployed using cephadm or manually.

CEPHADM-BASED DEPLOYMENT AS A SERVICE
-------------------------------------

`Cephadm Jaeger Services Deployment <../cephadm/services/tracing/>`_

MANUAL TEST DEPLOYMENT FOR JAEGER ALL-IN-ONE
--------------------------------------------

For single-node testing, Jaeger all-in-one can be deployed using:

.. prompt:: bash $

   docker run -d --name jaeger \
     -e COLLECTOR_ZIPKIN_HOST_PORT=:9411 \
     -e COLLECTOR_OTLP_ENABLED=true \
     -p 6799:6799/udp \
     -p 6832:6832/udp \
     -p 5778:5778 \
     -p 16686:16686 \
     -p 4317:4317 \
     -p 4318:4318 \
     -p 14250:14250 \
     -p 14268:14268 \
     -p 14269:14269 \
     -p 9411:9411 \
     jaegertracing/all-in-one:latest \
     --processor.jaeger-compact.server-host-port=6799

`Jaeger Deployment <https://www.jaegertracing.io/docs/1.25/deployment/>`_

`Jaeger Performance Tuning <https://www.jaegertracing.io/docs/1.25/performance-tuning/>`_

.. note::

   Ceph sends spans to a local Jaeger agent. In multi-host deployments, each
   host running traced Ceph daemons should also run a Jaeger agent. If an agent
   is not available on a traced host, spans generated there can be lost.

   Ceph uses Jaeger agent port ``6799`` by default, not Jaeger's usual
   ``6831``. For manual Jaeger all-in-one deployments, include
   ``--processor.jaeger-compact.server-host-port=6799`` so the agent listens on
   the port expected by Ceph.

.. _jaegertracing-enable:

HOW TO ENABLE TRACING IN CEPH
-----------------------------

Tracing in Ceph is disabled by default.

Tracing can be enabled globally, and tracing can also be enabled separately for
individual daemon types (for example, for rgw).

Enable tracing globally:

.. prompt:: bash $

   ceph config set global jaeger_tracing_enable true

Enable tracing for a specific entity:

.. prompt:: bash $

   ceph config set <entity> jaeger_tracing_enable true

Examples of ``<entity>`` include ``osd`` and ``rgw``.

.. note::

   Building Ceph with tracing support requires ``-DWITH_JAEGER=ON``. Without
   that build option, tracing code falls back to no-op behavior.


TRACES IN RGW
-------------

Traces run on RGW can be found under the Service `rgw` in the Jaeger Frontend.

REQUESTS
^^^^^^^^
Every user request is traced. Each trace contains tags for `Operation name`,
`User id`, `Object name` and `Bucket name`.

There is also an `Upload id` tag for Multipart upload operations.

The names of request traces have the following format: `<command> <transaction
id>`.

MULTIPART UPLOAD
^^^^^^^^^^^^^^^^
There is a kind of trace that consists of a span for each request made by a
multipart upload, and it includes all `Put Object` requests.

The names of multipart traces have the following format: `multipart_upload
<upload id>`.


rgw service in Jaeger Frontend:

.. image:: ./rgw_jaeger.png
  :width: 400


osd service in Jaeger Frontend:

.. image:: ./osd_jaeger.png
  :width: 400

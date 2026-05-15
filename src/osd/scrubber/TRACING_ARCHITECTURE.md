# Scrubber Tracing Architecture: Span Stack

## Problem

Looking at the trace screenshot and the code, I can see two issues:

  1. Flat siblings instead of proper nesting: ReservingReplicas appears as a
  sibling of ActiveScrubbing rather than nested under Session. Similarly, the
  in-chunk states (NewChunk, WaitPushes, etc.) all appear as children of
  ActiveScrubbing but not as siblings — some get attached to the wrong parent
  because m_tracer is swapped inconsistently.

  2. Only two levels tracked: You have m_tracer (current) and m_parent_trace
  (one level up), but the hierarchy is up to 5 levels deep (PrimaryActive >
  Session > ActiveScrubbing > in-chunk > NewChunk). When you swap, you lose the
  grandparent and above.

The root cause: std::swap overwrites m_tracer with the new span, and
m_parent_trace with the old m_tracer, but there's no way to restore the parent
when you exit a state. It's a single-slot "stack" that can only hold one
previous value

The current tracing implementation uses `std::swap(span, m_tracer)` with a single
`m_parent_trace` to track span hierarchy. This only tracks 2 levels, but the state
machine is up to 5 levels deep. Spans end up as flat siblings instead of properly
nested, and parent context is lost on state transitions.

## State Hierarchy

```
ScrubMachine
├── NotActive
├── PrimaryActive                          (depth 0)
│   ├── PrimaryIdle                        (depth 1) [RESET]
│   └── Session                            (depth 1)
│       ├── ReservingReplicas              (depth 2)
│       └── ActiveScrubbing                (depth 2)
│           ├── PendingTimer               (depth 3)
│           ├── RangeBlocked               (depth 3)
│           └── in-chunk states:           (depth 3)
│               NewChunk, WaitPushes, WaitLastUpdate,
│               BuildMap, DrainReplMaps, WaitReplicas,
│               WaitDigestUpdate
├── ReplicaActive                          (depth 0)
│   ├── ReplicaIdle                        (depth 1) [RESET]
│   └── ReplicaActiveOp                    (depth 1)
│       ├── ReplicaWaitUpdates             (depth 2)
│       └── ReplicaBuildingMap             (depth 2)
```

RESET states: {NotActive, PrimaryIdle, ReplicaIdle} — clear the stack on entry.

## Solution: Span Stack

A `std::vector<otel_span_ref>` that mirrors the Boost.Statechart nesting. Each state's
constructor pushes a span (parented to the stack's top), and its destructor pops it.

### Why a stack (not a tree or hashmap)?

- At any point, exactly one leaf state is active with a single chain of ancestors.
  No concurrent sibling states exist — so a tree's branching ability is unnecessary.
- A hashmap requires key management and lookup logic; a stack just needs push/pop.
- The stack mirrors Boost.Statechart's own constructor/destructor LIFO order.

### Why a stack, not a tree or hashmap?

1. The state machine is hierarchical but not branching concurrently — at any
point, you're in exactly one leaf state with a single chain of ancestors. You
never have two sibling states active at the same time. This means you don't need
a tree's ability to track multiple branches.
2. A hashmap requires keys — you'd need to map state names to spans, and
managing lookups/cleanup is error-prone. A stack just needs push/pop.
3. The stack mirrors Boost.Statechart's own behavior — when you enter a nested
state, its constructor runs (push span); when you exit, its destructor runs (pop
span). This is exactly LIFO order.


### API

```cpp
// In ScrubMachine, replacing m_tracer + m_parent_trace:
std::vector<otel_span_ref> m_span_stack;

otel_span_ref& current_span();           // returns stack top or noop
void push_span(const std::string& label);  // add_span(label, current_span())
void push_span(const std::string& label, const otel_span_context_t& parent_ctx); // for replica
void pop_span();                     // pop and end the top span
void clear_spans();                  // end all spans (used by RESET states)
```

### Usage pattern in each state

```cpp
SomeState::SomeState(my_context ctx) : ... {
    context<ScrubMachine>().push_span(
        fmt::format("{}_primary_SomeState", pg_id.pgid));
}

SomeState::~SomeState() {
    context<ScrubMachine>().pop_span();
}
```

### Stack behavior during transitions

```
Enter PrimaryActive   → stack: [PrimaryActive]
  Enter Session       → stack: [PrimaryActive, Session]
    Enter Reserving   → stack: [PrimaryActive, Session, Reserving]
    Exit Reserving    → stack: [PrimaryActive, Session]
    Enter ActiveScrub → stack: [PrimaryActive, Session, ActiveScrub]
      Enter NewChunk  → stack: [PrimaryActive, Session, ActiveScrub, NewChunk]
      Exit NewChunk   → stack: [PrimaryActive, Session, ActiveScrub]
      Enter WaitPushes→ stack: [PrimaryActive, Session, ActiveScrub, WaitPushes]
```

### Replica spans

ReplicaActiveOp uses the overload that takes a `otel_span_context_t` (from MOSDRepScrub)
instead of the stack's current top as parent, linking replica spans under the
primary's trace.

### In-chunk cycling

Sibling transitions (NewChunk → WaitPushes → ... → NewChunk) work naturally:
destructor pops, constructor pushes. Each chunk iteration creates new sibling spans
under ActiveScrubbing.

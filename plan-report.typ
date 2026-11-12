// Project plan report. Build: typst compile plan-report.typ (from final_project/).
// Red TODO marks are undecided items; remove the todo() calls before submitting.

#let title = "TODO: Project Title"
#let members = ("Rishiraj Dhar", "Bhoomika Gupta")
#let team = "TODO"

#let todo(body) = text(fill: red)[*TODO:* #body]

#set document(title: title, author: members)
#set page(paper: "us-letter", margin: 1in)
#set text(font: "New Computer Modern", size: 11pt)
#set par(leading: 0.65em, spacing: 1.2em, justify: true)
#set list(indent: 0.5em)
#set enum(indent: 0.5em)
#show heading.where(level: 2): set block(above: 1.4em, below: 0.8em)

#align(center)[
  #text(size: 16pt, weight: "bold")[#title] \
  #v(0.3em)
  CS 6650 Project Plan · Team #team \
  #members.join(", ") · November 2026
]

== Overview

A sharded, fault-tolerant key-value store in C++17, run on the Khoury Linux cluster.

- Keys are partitioned across a fixed set of *shard groups* by hashing.
- Each shard group is replicated across 3 servers with Raft.
- Clients see a single store with `Put(key, value)` and `Get(key)`; the client library hides
  the shard layout.
- There is no central master: any server redirects a request to the group that owns the key,
  and followers redirect to their group's leader.

== Goals

- *Sharding:* spread data and requests across multiple shard groups.
- *Replication and failover:* each group keeps serving while a majority of its replicas is up.
- *Linearizable operations:* `Put` and `Get` behave as if executed one at a time on a single
  copy, including across leader changes.
- *Exactly-once writes:* a client retrying a request after a timeout never causes it to be
  applied twice.
- *Crash recovery:* a crashed server restarts from its persisted log and rejoins its group.

Out of scope for this plan: distributed transactions and cross-shard operations; moving shards
between groups or changing membership at runtime (a possible later extension); snapshots and
log compaction #todo[confirm].

== Assumptions

- *Failures:* crash-recover, non-Byzantine. With 3 replicas, each group tolerates 1 server down
  at a time.
- *Network:* messages may be lost, delayed, or reordered. A partition inside a group is
  tolerated: the majority side keeps making progress and the minority cannot commit. A client
  that cannot reach a majority of the owning group times out; this is accepted.
- *Configuration:* the server list and the key-to-group map are fixed at startup and known to
  every server.
- *Clients:* each client has a unique id and at most one outstanding request.
- *Workload and users:* #todo[who issues requests, how many clients, read/write mix, key
  distribution (uniform or skewed)].

== Design

=== Routing

- The key-to-group map is a fixed hash function over the keys.
- A client sends a request to any server. A server outside the owning group replies with a
  redirect to that group; a follower replies with a redirect to its leader. The client follows
  redirects and retries on timeout.
- No separate master: routing is folded into the servers, so there is no single point of
  failure in front of the shard groups.

=== Replication (per shard group)

- Standard Raft: leader election (`RequestVote`), log replication (`AppendEntries`), commit on
  majority.
- `Put` is appended to the leader's log and applied to the key-value map after it commits.

=== Linearizable reads

- A new leader appends a no-op entry at the start of its term, so it learns which entries are
  committed.
- On `Get`, the leader records its commit index, confirms it is still leader by a heartbeat
  round acknowledged by a majority, waits until it has applied up to the recorded index, then
  reads the map. (Raft paper §8.)

=== Exactly-once writes

- Each request carries (client id, sequence number), and log entries carry them too.
- The state machine keeps a table: client id → (last applied sequence number, its reply).
- The check happens when a committed entry is applied: a duplicate is skipped and the stored
  reply is returned. Every replica applies the same log in the same order, so all replicas
  build the same table, and a new leader has it.
- The leader replies to the client once the entry at its assigned index is applied.

=== Persistence

- One append-only log file per server, holding tagged records: term/vote records, and entry
  records carrying the entry's term, client id, sequence number, and operation.
- On a log conflict, the file is truncated at the first conflicting entry and the leader's
  entries are appended.
- State is written to disk before the server responds to an RPC (Raft Figure 2).
- On restart, the server replays the file to rebuild its term, vote, log, key-value map, and
  dedup table.
- The exact record format will be settled during implementation. Known risks: a crash between
  truncation and the following write must not lose the latest term/vote; torn writes must be
  detected on replay; replay time grows with the log.

== Modules

- *Raft server:* `RequestVote`, `AppendEntries`, elections, commit tracking.
- *Request handler:* `Put`/`Get`, redirects, read path, replying once an entry is applied.
- *State machine:* key-value map (`std::map`) plus the dedup table.
- *Persistent log:* append, truncate, and replay of the log file.
- *Client library:* `Put(K, V)` and `Get(K)`; sequence numbers, retries, following redirects.
- #todo[workload generator / test harness, failure injection, if separate modules]

== Evaluation

=== Sharding

- Vary the number of shard groups from 1 to 3 and measure throughput; expect throughput to rise.
- Latency is expected to stay about the same, since per-entry Raft work dominates, or rise
  slightly from redirect hops.
- Servers stamp each response with their group id, and the client reports the number of keys
  served per group.
- #todo[which resource sharding relieves, and how process placement and client load make it
  the bottleneck with 1 group; what result counts as success; a correctness check that each key
  is served by its owning group and `Get` returns the latest `Put`].

=== Replication and failover

- #todo[experiment, what is measured, expected result]

=== Linearizable operations

- #todo[experiment, what is measured, expected result]

=== Exactly-once writes

- #todo[experiment, what is measured, expected result]

=== Crash recovery

- #todo[experiment, what is measured, expected result]

=== Running on the Khoury cluster

- #todo[number of machines, placement of servers and clients, how processes are started and
  killed, how results are collected]

== Timeline

Fixed dates: progress reports Nov 16, 23 and 30; code and report due Fri Dec 4; video due
Mon Dec 7. Rishiraj is unavailable Nov 20–28; Dec 5–7 is reserved for recording the video.

#todo[step-by-step build and evaluation plan with dates]

== Division of work

#todo[which features each member owns end to end]

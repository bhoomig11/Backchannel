// Project plan report. Build: typst compile plan-report.typ (from the repo root).

#import "@preview/cetz:0.5.3"

#let title = "Backchannel: Sharded, Raft-Replicated Storage for Chat"
#let members = ("Rishiraj Dhar", "Bhoomika Gupta")
#let team = "5"


// One hue: shades of a single blue; elements differ by lightness and dash only.
#let accent = rgb("#1f5f9e")
#let redirect = accent
#let raft-ink = accent.lighten(55%)
#let group-fill = accent.lighten(94%)
#let group-ink = accent.lighten(60%)
#let server-fill = group-fill
#let server-ink = group-ink
// Circled step number; its box is cap-height tall so it never changes line spacing.
#let step(n) = box(width: 1.2em, height: 0.7em, place(center + horizon,
  circle(radius: 0.58em, inset: 0pt, stroke: 0.5pt + black,
    align(center + horizon, text(0.8em, str(n))))))

#set document(title: title, author: members)
#set page(
  paper: "us-letter",
  margin: 1in,
  numbering: "1",
  header: {
    set text(size: 9pt)
    grid(
      columns: (1fr, auto, 1fr),
      align(left)[CS 6650 Fall 2026], [Final Project Plan], align(right)[November 12, 2026],
    )
  },
  footer: context align(center, text(size: 9pt)[
    Page #counter(page).display() of #counter(page).final().first()
  ]),
)
#set text(font: "New Computer Modern", size: 11pt)
#set par(leading: 0.65em, spacing: 1.2em, justify: true)
#set list(indent: 0.5em)
#set enum(indent: 0.5em)
#show heading.where(level: 1): set block(above: 1.4em, below: 0.8em)
#show figure.caption: set text(size: 9.5pt)
// Terms lists render like the report's bullet lists: same indent and marker. Code-style terms
// stay regular weight; monospace already sets them apart.
#show terms: it => list(..it.children.map(i => {
  let term = if i.term.func() == raw { i.term } else { strong(i.term) }
  [#term: #i.description]
}))

#align(center)[
  #text(size: 16pt, weight: "bold")[#title] \
  #v(0.3em)
  Team #team #sym.dot.c #members.join(", ")
]

= Overview

The robot business has recovered from the downturn and every factory is back in production,
running around the clock in shifts. The crews coordinate over an in-house chat app. Engineers
use it to flag defects and call quality holds, and admins use it to schedule maintenance with
the line crews. Shift handovers also happen over chat, so that is when traffic peaks. There is
a channel for each production line, shift and team, which comes to about a thousand channels.

The chat app's servers keep all of its messages on a single storage server. It can no longer keep up at handover, and
when it crashes, every line loses coordination at the same time. To fix this, the business is
moving the chat app onto Backchannel, a new storage backend: a key-value store, sharded across
groups of servers, each group replicated with Raft.

- Each channel's message history is one key: a post appends to it, and a load reads it.
- Channels are spread across a fixed set of shard groups by hashing.
- Each shard group is replicated across 3 servers with Raft.
- The chat app's servers see one store, where they post messages and load channels.
- The client library hides the shard layout and sends each request to the owning group.
- Instead of a central master directing clients, a follower redirects each request to its leader.

= Goals

Together, the primary goals let the chat app use Backchannel as if it were one storage server,
without that server's limits. Evaluation tests each goal with one experiment, in the same order.

== Primary goals

- *Replication and failover.* Each group keeps serving while a majority of its three replicas is
  up, and a leader failure costs only the time it takes to elect a new one.
- *Crash recovery.* A crashed server restarts from its persisted log and catches up with its
  group, and no acknowledged write is lost, even if all three replicas crash at once.
- *Exactly-once writes.* A request retried after a timeout takes effect only once, even if the
  server applied it and only the reply was lost.
- *Linearizable operations.* Every operation acts as if run one at a time on a single copy, even
  across leader changes, so a read never misses a write acknowledged before it started.
- *Sharding.* Shard groups split the keys and their load, so throughput grows with the number
  of groups instead of being bounded by a single server.

== Stretch goal

- *Batching.* The leader sends several log entries per replication round and disk write.
  Measure its effect on throughput and latency, and check that histories stay linearizable.

#block(breakable: false)[
== Out of scope and future work

- *Snapshots and log compaction.* Bounding log size and restart time.
- *Cross-shard transactions.* Atomic writes across shard groups, using two-phase commit.
- *Resharding and membership changes.* Moving shards and servers at runtime.
- *Pipelined replication.* Several replication rounds in flight per follower.
]

= Design

Backchannel favors consistency over availability: a group serves only while a majority is up.

== Assumptions

- *Failures.* Crash-recover, non-Byzantine. Any number of servers may crash at the same time.
- *Network.* Messages may be lost, delayed, duplicated, reordered or cut off by partitions.
- *Storage.* Each server's disk is local to its machine and survives a process crash.
- *Workload.* Simulated chat servers run closed-loop clients (each sends its next request once
  the last one completes), choosing channels uniformly from 1,000. Two operation mixes:
  - *Update-heavy.* 50% loads, 50% posts, maximizing interleaved reads and writes.
  - *Read-mostly.* 95% loads, 5% posts, stressing the read path.

== Architecture

Keys are split across independent Raft groups with no central master, as @fig-topology shows.

#figure(
  cetz.canvas(length: 1mm, {
    import cetz.draw: *
    // Spacing ladder (mm): every gap, padding and margin is one of these.
    let sp(n) = { assert(n in (1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 32, 48, 64)); n }
    let fs = 10.5pt
    let lfs = 9.5pt
    let lr = 2.5
    let cap = fs * 0.7 / 1mm
    let thin = 0.5pt
    let mid = 0.75pt
    let heavy = 1pt
    let r = 3
    let node(pos, leader, rad: r, size: fs) = {
      circle(pos, radius: rad, stroke: mid + accent, fill: if leader { accent } else { white })
      content(pos, text(size, fill: if leader { white } else { accent }, if leader [L] else [F]))
    }
    let label(pos, anchor, body, size: fs) = content(pos, anchor: anchor, text(size, body))
    let arrow(a, b, paint, dash: none) = line(a, b, mark: (end: ">", fill: paint, scale: 0.9),
      stroke: (paint: paint, thickness: heavy, dash: dash))

    // Shard groups: three replicas each, a vertical edge facing the chat server.
    let pad = sp(3)
    let padx = sp(4)
    let edge = sp(20)
    let reach = 17
    let pw = 2 * padx + 2 * r + reach
    let ph = 2 * pad + 2 * r + edge
    let srv-right = pw
    let lib = (padx, pw - padx)
    let px = srv-right + sp(64)
    let stride = ph + sp(2) + cap + sp(3)
    let top(g) = -g * stride
    let pts(g) = {
      let y = top(g) - pad - r
      ((px + padx + r, y), (px + padx + r, y - edge), (px + padx + r + reach, y - edge / 2))
    }
    let leaders = (2, 1, 0)
    for g in range(3) {
      rect((px, top(g)), (px + pw, top(g) - ph), stroke: thin + group-ink, fill: group-fill)
      label((px, top(g) + sp(2)), "base-west", [Shard group #g])
      let p = pts(g)
      for (i, j) in ((0, 1), (1, 2), (2, 0)) { line(p.at(i), p.at(j), stroke: thin + raft-ink) }
      for i in range(3) { node(p.at(i), i == leaders.at(g)) }
    }

    // Chat servers (a stacked copy behind), each layer the size of a shard group panel,
    // with a client library module inside.
    let (f, l, _) = pts(1)
    let srv = (0, srv-right, top(1), top(1) - ph)
    let lib-top = srv.at(2) - pad
    let lib-bot = srv.at(3) + pad
    rect((srv.at(0) + sp(2), srv.at(2) - sp(2)), (srv.at(1) + sp(2), srv.at(3) - sp(2)),
      stroke: thin + server-ink, fill: server-fill)
    rect((srv.at(0), srv.at(2)), (srv.at(1), srv.at(3)), stroke: thin + server-ink, fill: server-fill)
    rect((lib.at(0), lib-top), (lib.at(1), lib-bot), stroke: thin + server-ink, fill: white, name: "lib")
    content("lib", align(center, text(fs)[Client \ library]))
    label((srv.at(0), srv.at(2) + sp(2)), "base-west", [Chat server])

    // Routing exchange with group 1: request to a follower and its redirect, then the retry at
    // the leader and its reply. Requests are labelled above their arrows, replies below.
    let off = sp(2)
    let hit = calc.sqrt(r * r - off * off)
    let tx = srv.at(1) + sp(2) + sp(4)
    arrow((lib.at(1), f.at(1) + off), (f.at(0) - hit, f.at(1) + off), accent)
    label((tx, f.at(1) + off + sp(2)), "south-west", [#step(1) `Append(k, v)`])
    arrow((f.at(0) - hit, f.at(1) - off), (lib.at(1), f.at(1) - off), redirect, dash: "dashed")
    label((tx, f.at(1) - off - sp(2)), "north-west", [#step(2) `NOT_LEADER`, hint])
    arrow((lib.at(1), l.at(1) + off), (l.at(0) - hit, l.at(1) + off), accent)
    label((tx, l.at(1) + off + sp(2)), "south-west", [#step(3) retry at leader])
    arrow((l.at(0) - hit, l.at(1) - off), (lib.at(1), l.at(1) - off), redirect, dash: "dashed")
    label((tx, l.at(1) - off - sp(2)), "north-west", [#step(4) `OK`])

    // Legend, beside group 0.
    let row = sp(8)
    let ly = top(0) - ph / 2 + row
    let lx = (0, 40)
    let key(x, y, sym, body) = { sym; label((x + 8 + sp(2), y), "west", body, size: lfs) }
    key(lx.at(0), ly, node((lx.at(0) + 4, ly), true, rad: lr, size: lfs), [Leader])
    key(lx.at(0), ly - row, node((lx.at(0) + 4, ly - row), false, rad: lr, size: lfs), [Follower])
    key(lx.at(0), ly - 2 * row, line((lx.at(0), ly - 2 * row), (lx.at(0) + 8, ly - 2 * row),
      stroke: thin + raft-ink), [Raft traffic])
    key(lx.at(1), ly, arrow((lx.at(1), ly), (lx.at(1) + 8, ly), accent), [Request])
    key(lx.at(1), ly - row, arrow((lx.at(1) + 8, ly - row), (lx.at(1), ly - row), redirect,
      dash: "dashed"), [Reply])

    // Walkthrough of the numbered steps, in the free space beside group 2.
    content((0, top(2) - sp(3)), anchor: "north-west", box(width: (px - sp(8)) * 1mm, {
      set text(fs)
      set enum(numbering: n => step(n), spacing: 0.9em)
      set par(justify: false)
      enum(
        [The library sends `Append(k, v)` to group 1.],
        [A follower replies `NOT_LEADER` with a hint.],
        [The library retries at the leader.],
        [The leader serves it and replies `OK`.],
      )
    }))
  }),
  caption: [Backchannel topology, with the routing of one request.],
) <fig-topology>


== Concepts

/ Client: A chat server worker that sends requests to the store through the client library.
/ Channel: A conversation for one production line, shift or team, with a message history.
/ Message: A piece of text a user sends to a channel, with its sender and a unique id. A
  channel's history is its messages in the order they were posted.

== Data model and client API

- Each client has a unique id and at most one outstanding request.
- Keys and values are opaque strings. A channel's history lives at #box(`"channel/<id>/msgs"`).
- Each message is stored as a self-delimiting record of its sender, text and id, so a history
  parses back into messages. The id is the posting request's (client id, sequence number).
- Operations and their chat use. There is no overwrite, since histories only grow:
  / `Append(k, v)`: Adds `v` to the end of `k`'s value. Posts a message to a channel's history.
  / `Get(k)`: Returns `k`'s value. Loads a channel's history.
- A load returns the whole history; experiments keep histories short, so pagination is left for
  later.
- Each key belongs to one shard group, chosen by a hash that spreads keys evenly and that every
  process, clients included, computes from its server list. The client library sends each request to the key's group: to
  the last leader it saw there, or else to any member.
- Request fields: client id, sequence number, operation, key, value.
- Reply fields: status, value, group id of the replying server, and a hint (a server id to retry
  at).
- Statuses:
  / `OK`: The operation succeeded.
  / `NOT_FOUND`: `Get` on a missing key.
  / `NOT_LEADER`: The server is a follower or candidate, and the hint names the leader if known.
    With no hint, the client waits one election timeout and tries another server.
  / `WRONG_GROUP`: The key belongs to another group, so the client's server list is wrong. The
    request fails fast instead of reading or writing the wrong key.
- A request with no reply within the request timeout is retried at the group's next server.
  After the retry cap, the library reports that it may or may not have taken effect.

== Replication (per shard group)

- Standard Raft, as summarized in Figure 2 of the Raft paper @raft: leader election
  (`RequestVote`), log replication (`AppendEntries`), commit on majority. Groups run independent
  Raft instances.
- Each `Append` enters the leader's log and is applied to the key-value map after it
  commits, as in the write path of @fig-paths below.
- A group without a majority stops serving its keys rather than risk returning stale data.
  Other groups are unaffected, and the group resumes once a majority restarts.

#figure(
  cetz.canvas(length: 1cm, {
    import cetz.draw: *
    let xs = (0, 5, 10)
    let names = ([Client], [Leader], [Followers (#sym.times;2)])
    for i in range(3) {
      content((xs.at(i), 0.4), text(9pt, weight: "bold", names.at(i)))
      line((xs.at(i), 0), (xs.at(i), -10.4), stroke: (paint: gray, dash: "dashed"))
    }
    let arr = (end: ">", fill: black)
    let msg(y, a, b, label) = {
      line((xs.at(a), y), (xs.at(b), y), mark: arr)
      content(((xs.at(a) + xs.at(b)) / 2, y + 0.27), text(8.5pt, label))
    }
    let note(y, i, body) = content((xs.at(i), y),
      box(fill: white, inset: 2pt, outset: (x: 1pt, y: 3pt), text(8.5pt, body)))
    let section(y, body) = content((-0.9, y), anchor: "east", text(9pt, style: "italic", body))

    section(-0.6, [Write])
    msg(-0.6, 0, 1, [`Append(k, v)`, client id, seq])
    note(-1.3, 1, [append to log, persist])
    msg(-2.0, 1, 2, [`AppendEntries`])
    note(-2.6, 2, [append, persist])
    msg(-3.2, 2, 1, [ack])
    note(-3.9, 1, [majority: commit, apply (dedup check)])
    msg(-4.6, 1, 0, [`OK`])

    section(-5.8, [Read])
    msg(-5.8, 0, 1, [`Get(k)`])
    note(-6.5, 1, [readIndex #sym.arrow.l commitIndex])
    msg(-7.2, 1, 2, [heartbeat])
    msg(-7.9, 2, 1, [ack])
    note(-8.6, 1, [still leader; wait until applied #sym.gt.eq readIndex])
    msg(-9.3, 1, 0, [value])
  }),
  caption: [Write and read paths in one shard group.],
) <fig-paths>

== Linearizable reads

- A new leader appends a no-op entry when its term starts, to learn which entries are committed.
- `Get` follows the read-index protocol from Section 8 of the Raft paper @raft, shown in
  @fig-paths above. With no log entry, one heartbeat round keeps a deposed leader from serving
  stale data.

== Exactly-once writes

- Each request carries (client id, sequence number), and log entries carry them too.
- The state machine's deduplication (dedup) table maps client id #sym.arrow.r (last applied seq, reply).
- When a committed entry is applied, a duplicate is skipped and its stored reply returned.
  Every replica applies the same log in order, so all build the same table and a new leader
  has it.
- The leader replies to the client once the entry at its assigned index is applied.

== Persistence

- Each server keeps its term, vote and log on local disk and makes every change durable before
  answering any RPC, as Figure 2 of the Raft paper @raft requires.
- On restart, a server rebuilds its term, vote, log, key-value map and dedup table from disk.
- Known risks:
  - A crash while the log is rewritten after a conflict must not lose the latest term or vote.
  - Partially written records must be detected on restart.
  - Restart time grows with the log, since there are no snapshots.

== Configuration and timing

- The server list and the key-to-group map are fixed at startup. Every process, server or
  client, gets the same list of each server's id, group, host and port as command-line
  arguments.
- Timing:
  / Election: 250--500 ms, randomized per server and term.
  / Heartbeat: 50 ms between heartbeats from the leader.
  / Request: 1 s before the client library retries a request.
  / Retry cap: 10 s of retries before the library gives up on a request.

== Modules

All modules are written in C++17.

- *RPC layer.* Client and server stubs for every message, one listener per server that dispatches
  by type (client operations to the request handler, Raft messages to Raft), and fault injection.
- *Raft server.* Elections (`RequestVote`), log replication (`AppendEntries`), commits, read index.
- *Request handler.* Serves `Get` and `Append`, redirects followers' requests to the
  leader, rejects requests for other groups, and replies once an entry is applied.
- *State machine.* Applies committed entries to the key-value map and keeps the dedup table.
- *Persistent log.* Stores Raft state durably and returns it on restart.
- *Client library.* Offers `Get` and `Append`, routes by key, numbers requests, retries, follows hints.

= Evaluation

== Setup on the Khoury cluster

- Machines: linux-071 to linux-085 (15). Each server runs on its own machine: 3 groups #sym.times 3
  replicas = 9 machines, plus 2 machines for clients. Ports are in 10000--65535.
- Processes are started and killed over `ssh` (`kill -9` for crashes); logs live under `/tmp`
  on each machine's local disk, since home directories are on NFS, shared by all machines.
- Partitions are simulated in-process (no root access for firewall rules): a server told to
  isolate itself drops all messages to and from its peers until told to stop.
- Lost replies are simulated by a server option that drops a given fraction of client replies
  after the request has been applied.
- Every client records each operation's start time, end time, arguments and result. Servers'
  clocks are not used.
- *History checker.* Every appended message is a unique token (client id and sequence
  number), so all reads of a channel must be prefixes of one message order. The checker
  verifies, per channel: (1) every read is a prefix of the longest read; (2) a read includes
  every append acknowledged before it started; (3) a read that started after another read
  finished returns at least as much; (4) a read contains no message whose append started after
  the read finished; (5) every message appears at most once, and every acknowledged message
  appears.
- Repeat each experiment 5 times and report medians, plus p99 for latency.

== Replication and failover

- One group under steady update-heavy load; `kill -9` the leader. Measure the unavailability window: time
  from the kill to the first completed write.
- Expected: about one election timeout plus a round trip (under 1 s). Killing a follower
  instead causes no gap.
- Partition the leader from its followers: the old leader's writes never complete, and the
  majority elects a new leader and continues.
- Success: in every run the group recovers, and the checker finds every acknowledged message.

== Crash recovery

- Kill one follower under load and restart it: it catches up, and after the load stops all
  three replicas hold identical key-value maps (compared by hash).
- Kill all three servers of a group at once and restart them: every acknowledged message is
  still present.
- Measure restart time against log length (10#super[4], 10#super[5], 10#super[6] entries).
  Expected: linear growth, the cost of having no snapshots.

== Exactly-once writes

- Update-heavy mix, while servers drop 20% of replies and leaders are killed, so many
  requests are retried.
- Success: the checker finds no message twice.
- Control: with the dedup check disabled, duplicates should appear.

== Linearizable operations

- Update-heavy mix, 10 clients on 3 channels (high contention), for 2 minutes, with a leader kill or partition
  every 10 s. Run the checker over the history.
- Success: no violations in any run.
- Control: a variant where the leader serves `Get` from its local map without the read-index
  round. With a partitioned old leader, the checker should report stale reads, showing it can
  detect the failure it guards against.

== Sharding

- Read-mostly mix. Vary the number of shard groups from 1 to 3. For each, increase the number of clients until
  throughput stops rising, and report peak throughput and the latency at that load.
- Expected: near-linear scaling, since each group's leader is the bottleneck (with mostly
  reads, its CPU and network for read-index rounds) and groups share nothing. Success: 3 groups
  reach at least 2.5#sym.times the throughput of 1 group.
- Correctness: each reply's group id matches the key's group, and histories pass the checker.

== Batching (stretch)

- Repeat the 1-group throughput experiment with batching off and on, under the update-heavy
  mix (batching only speeds up writes).
- Expected: higher peak throughput with batching, since one disk write covers many entries;
  latency at low load roughly unchanged. Rerun the linearizability experiment with batching on
  to check it breaks nothing.

= Timeline

The first three weeks end on progress report dates; the last ends at the code and report deadline.

#table(
  columns: (auto, 1fr),
  stroke: none,
  inset: (x: 6pt, y: 5pt),
  table.hline(),
  [*Week*], [*Team deliverable*],
  table.hline(stroke: 0.5pt),
  [Nov 12--16], [Frozen message, log entry and command-line formats; leader election and in-memory
    replication of `Append` in one shard group.],
  [Nov 17--23], [Persistence and crash recovery; exactly-once writes; linearizable `Get`;
    failover after a leader kill, tested on the cluster.],
  [Nov 24--30], [Sharding across 3 groups, with routing by key; a first end-to-end evaluation run on
    the cluster.],
  [Dec 1--4], [All experiments, run on the cluster, with fixes; the final report and run
    instructions (due Dec 4); batching, if time allows.],
  table.hline(),
)

= References

#bibliography("refs.bib", title: none, style: "ieee")

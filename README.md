# Tsss

A distributed, anonymous, encrypted messaging system built on pure Erlang/OTP.

## Features

- **Distributed & Agentic** — Messages route autonomously across Erlang nodes. Each session has an autonomous agent that handles heartbeats, delivery retries, and receipts independently.
- **Service Discovery** — Ephemeral handles are registered via OTP `pg` (process groups), which propagates membership to all connected nodes without locks or a central coordinator.
- **Anonymous & Encrypted** — Users have no persistent identity. Each session generates an ephemeral x25519 keypair. Messages are encrypted with AES-256-GCM after ECDH key exchange + HKDF-SHA256 key derivation.
- **Self-Destruct / Kill Switch** — Per-message TTL timers, session wipe, and a cluster-wide kill switch that halts all nodes and purges all ETS state within 500ms.
- **Self-organizing Leader Election** — Pure OTP Bully algorithm. No external dependencies (no Zookeeper, etcd, or Raft library).

## Architecture

```
tsss_sup (one_for_one)
├── tsss_cluster_sup     → tsss_node_mon, tsss_cluster
├── tsss_election_sup    → tsss_election (Bully FSM), tsss_leader
├── tsss_registry_sup    → tsss_registry (pg + ETS), tsss_presence
├── tsss_destruct_sup    → tsss_ttl_server, tsss_wipe
├── tsss_router_sup      → tsss_router
├── tsss_session_sup     → tsss_session (one per user, temporary)
└── tsss_client_sup      → tsss_client (one per connection, temporary)
```

## Cryptography

| Primitive | Algorithm | Notes |
|-----------|-----------|-------|
| Key exchange | ECDH x25519 | Ephemeral per session |
| Key derivation | HKDF-SHA256 | Salt = session_id for domain separation |
| Encryption | AES-256-GCM | 12-byte random nonce per message |
| MAC | HMAC-SHA256 | Used internally in HKDF |

All crypto uses OTP's built-in `crypto` module. No third-party crypto libraries.

## Usage

```erlang
%% Start the application
application:ensure_all_started(tsss).

%% Create anonymous sessions (each gets an ephemeral keypair + handle)
{ok, #{pid := PidA, handle := HandleA, pub_key := PubA}} = tsss_api:new_session().
{ok, #{pid := PidB, handle := HandleB, pub_key := PubB}} = tsss_api:new_session().

%% Complete ECDH key exchange
tsss_api:exchange_keys(PidA, HandleB, PubB).
tsss_api:exchange_keys(PidB, HandleA, PubA).

%% Send an encrypted message with a 60-second self-destruct TTL
tsss_api:send(PidA, HandleB, <<"hello">>, 60000).

%% Receive (blocking, 5-second timeout)
tsss_api:recv_blocking(PidB, 5000).

%% Wipe a single session (deletes key material, unregisters handle)
tsss_api:wipe_session(PidA).

%% Kill switch: broadcast wipe to all cluster nodes, then halt
tsss_api:kill_switch().
```

## Multi-Node Cluster

Update `config/sys.config` to list cluster peers:

```erlang
{known_nodes, ['tsss@node1.local', 'tsss@node2.local', 'tsss@node3.local']}
```

Then start each node:

```bash
erl -name tsss@node1.local -setcookie tsss_secret_cookie \
    -kernel dist_auto_connect never \
    -pa _build/default/lib/*/ebin \
    -eval "application:ensure_all_started(tsss)"
```

Nodes connect automatically via `tsss_node_mon`. Leader election runs on startup and on every node join/leave event.

## Building

Requires Erlang/OTP 24+ (for `x25519`, `pg`, and `crypto:crypto_one_time_aead/7`).

```bash
rebar3 compile
rebar3 ct          # Common Test suites
rebar3 proper      # PropEr property-based tests
rebar3 dialyzer    # type checking
```

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Node connections | `dist_auto_connect never` | Kill switch must permanently disconnect nodes |
| Service discovery | `pg` (not `global`) | `global` can deadlock under partition; `pg` is lock-free |
| Leader election | Bully algorithm | Simple O(n) election; no log replication needed |
| Session restart | `temporary` | Crashed session loses key material; silent restart is a security hazard |
| Identity | No persistent storage | Private keys never touch disk; forward secrecy by construction |

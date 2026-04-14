# Tsss

A distributed, anonymous, encrypted messaging system built on pure Erlang/OTP.

No accounts. No usernames. No persistent identity. Messages can self-destruct.
The whole cluster can be wiped in under a second.

---

## Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/tordbjorn77/Tsss/main/install.sh | bash
```

The script:
- Detects your OS (macOS or Linux)
- Installs **Erlang/OTP 27** if not already present (via Homebrew, apt, dnf, pacman, or asdf)
- Downloads and installs **rebar3**
- Clones this repo, compiles it, and builds a production release
- Writes a `./tsss` wrapper script with subcommands

**Requirements:** `curl`, `git`, and a supported OS (macOS 12+, Ubuntu 20.04+, Debian 11+, Fedora 36+, Arch, RHEL 8+). No root required on macOS.

---

## Quick start

```bash
cd Tsss
./tsss demo          # interactive demo — send and receive a message
./tsss console       # full Erlang shell with the app loaded
./tsss cluster 3     # spin up 3 local nodes for distributed testing
```

---

## The `tsss` command

```
Usage: tsss <command> [options]

Commands:
  start             Start a Tsss node in the background
  stop              Stop the running node
  console           Start a node with an interactive Erlang shell
  shell             Attach to a running node's shell
  status            Check if the node is running
  demo              Run a guided demo (key exchange + messaging + wipe)
  cluster <N>       Start N local nodes on this machine
  help              Show this help

Options (for start / console):
  --name   <name>   Erlang node name  (default: tsss@127.0.0.1)
  --cookie <cookie> Erlang cookie     (default: tsss_secret_cookie)
```

---

## Usage from the Erlang shell

### 1. Start a session

```erlang
{ok, #{pid := PidA, handle := HandleA, pub_key := PubA}} = tsss_api:new_session().
% → {ok, #{handle => <<"hawk-4a2f">>, pid => <0.234.0>, pub_key => <<...>>}}
```

A *session* is one anonymous participant. It generates an ephemeral x25519 keypair.
The handle (`<<"hawk-4a2f">>`) is a random short token — not a username.

### 2. Discover a peer and exchange keys

```erlang
%% Peer creates their session:
{ok, #{pid := PidB, handle := HandleB, pub_key := PubB}} = tsss_api:new_session().

%% Exchange public keys (ECDH — both sides compute the same shared secret):
tsss_api:exchange_keys(PidA, HandleB, PubB).
tsss_api:exchange_keys(PidB, HandleA, PubA).
```

In a real deployment, peers share their handle + public key out-of-band
(e.g. via a QR code or a separate channel). The registry lets you look up
a handle once it's registered:

```erlang
{ok, PubKey} = tsss_api:lookup_handle(<<"hawk-4a2f">>).
```

### 3. Send and receive messages

```erlang
%% Send a message (TTL = 0 means no automatic deletion):
tsss_api:send(PidA, HandleB, <<"Hello!">>, 0).

%% Receive (blocking, 5-second timeout) — works if client => self() was set:
{ok, {message, _From, Body}} = tsss_api:recv_blocking(PidB, 5000).
% Body => <<"Hello!">>
```

Messages are always encrypted before leaving the session process.
The router never sees plaintext — only `<<Nonce:12, Tag:16, Ciphertext/binary>>`.

### 4. Self-destruct timers

```erlang
%% Message disappears from Bob's mailbox after 30 seconds:
tsss_api:send(PidA, HandleB, <<"Expires in 30s">>, 30000).

%% Session expires after 10 minutes:
{ok, Info} = tsss_api:new_session(#{ttl_ms => 600000}).
```

### 5. Wipe and kill switch

```erlang
%% Destroy a single session (key material gone, handle unregistered):
tsss_api:wipe_session(PidA).

%% Wipe this node (stop all sessions, clear all ETS tables, disconnect):
tsss_api:wipe_node().

%% KILL SWITCH — broadcast wipe to every cluster node, then halt all of them:
tsss_api:kill_switch().
```

---

## Multi-node cluster

### Option A — `tsss cluster N` (local testing)

```bash
./tsss cluster 3     # starts 3 nodes on 127.0.0.1, ports 9100-9130
```

The nodes connect to each other automatically. A leader is elected via the
Bully algorithm within ~5 seconds.

### Option B — real machines

**Step 1.** Edit `config/sys.config` on each machine:

```erlang
{known_nodes, ['tsss@node1.example.com',
               'tsss@node2.example.com',
               'tsss@node3.example.com']}
```

**Step 2.** Start each node with a unique name and the same cookie:

```bash
# On node1:
./tsss start --name tsss@node1.example.com --cookie my_secret_cookie

# On node2:
./tsss start --name tsss@node2.example.com --cookie my_secret_cookie

# On node3:
./tsss start --name tsss@node3.example.com --cookie my_secret_cookie
```

**Step 3.** Verify the cluster formed and a leader was elected:

```bash
./tsss shell    # attaches to the running node
```

```erlang
tsss_cluster:members().
% → ['tsss@node1.example.com', 'tsss@node2.example.com', 'tsss@node3.example.com']

tsss_cluster:get_leader().
% → 'tsss@node2.example.com'
```

---

## API reference

```erlang
%% Session lifecycle
tsss_api:new_session()                        → {ok, #{pid, handle, pub_key, session_id}}
tsss_api:new_session(#{ttl_ms, handle, client}) → {ok, ...}
tsss_api:end_session(Pid)                     → ok

%% Key exchange
tsss_api:get_my_pubkey(Pid)                   → {ok, PubKey}
tsss_api:get_my_handle(Pid)                   → {ok, Handle}
tsss_api:exchange_keys(Pid, PeerHandle, PeerPubKey) → ok

%% Messaging
tsss_api:send(Pid, ToHandle, Plaintext)        → ok     % no TTL
tsss_api:send(Pid, ToHandle, Plaintext, TTLms) → ok     % self-destruct after TTLms
tsss_api:recv(Pid)                             → [#envelope{}]  % non-blocking drain
tsss_api:recv_blocking(Pid, TimeoutMs)         → {ok, Msg} | timeout

%% Service discovery
tsss_api:lookup_handle(Handle)                 → {ok, PubKey} | {error, not_found}
tsss_api:list_handles()                        → [Handle]   % cluster-wide

%% Presence
tsss_api:heartbeat(Handle)                     → ok  % call every ~10s to stay visible

%% Destruction
tsss_api:wipe_session(Pid)                     → ok
tsss_api:wipe_node()                           → ok
tsss_api:kill_switch()                         → ok  % ⚠ halts the entire cluster
```

---

## Building from source

**Requirements:** Erlang/OTP 24+, rebar3

```bash
git clone https://github.com/tordbjorn77/Tsss
cd Tsss
rebar3 compile           # compile all modules
rebar3 as prod release   # build a self-contained release
rebar3 ct                # run Common Test suites
rebar3 proper            # run PropEr property-based tests
rebar3 dialyzer          # type checking
```

The installer handles all of this automatically; manual steps are only needed
if you want to modify the source.

---

## Architecture

```
tsss_sup (one_for_one)
├── tsss_cluster_sup  (rest_for_one)
│   ├── tsss_node_mon      monitors nodeup/nodedown; manual connect/disconnect
│   └── tsss_cluster       membership map + pg group bookkeeping
├── tsss_election_sup (one_for_one)
│   ├── tsss_election      Bully algorithm FSM  (follower/candidate/leader)
│   └── tsss_leader        coordinator duties (sync, offline mailbox)
├── tsss_registry_sup (one_for_one)
│   ├── tsss_registry      handle→pid via pg + local ETS cache
│   └── tsss_presence      TTL-based online presence
├── tsss_destruct_sup (one_for_one)
│   ├── tsss_ttl_server    all TTL timers in one ETS table
│   └── tsss_wipe          wipe coordinator (msg / session / node / cluster)
├── tsss_router_sup   → tsss_router   (local + remote + store-and-forward)
├── tsss_session_sup  → tsss_session  (one per user, restart=temporary)
│                        spawns: tsss_mailbox + tsss_session_agent
└── tsss_client_sup   → tsss_client   (one per connection, restart=temporary)
```

### Cryptography

| Primitive | Algorithm | Implementation |
|-----------|-----------|----------------|
| Key exchange | ECDH x25519 | `crypto:generate_key(ecdh, x25519)` |
| Key derivation | HKDF-SHA256 | Manual extract+expand via `crypto:mac(hmac, sha256, ...)` |
| Encryption | AES-256-GCM | `crypto:crypto_one_time_aead/7` |
| Randomness | CSPRNG | `crypto:strong_rand_bytes/1` |

All crypto is OTP's built-in `crypto` module backed by OpenSSL. No external crypto libraries.

### Key design decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Node connections | `dist_auto_connect never` | Kill switch needs permanent disconnect |
| Service discovery | `pg` not `global` | `global` can deadlock under partition; `pg` is lock-free |
| Leader election | Bully algorithm | Simple O(n) election, no log replication overhead |
| Session restart | `temporary` | A crashed session has lost its key material; silent restart would create a ghost identity |
| Identity storage | None | Private keys never touch disk — forward secrecy by construction |
| Offline messages | Store-and-forward | Envelopes held by leader node, delivered on reconnect |

---

## Uninstall

```bash
rm -rf ~/.tsss          # if installed via one-liner
rm -f ~/.local/bin/rebar3
# Erlang: brew uninstall erlang  OR  sudo apt remove erlang
```

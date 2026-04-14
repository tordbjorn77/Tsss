# Tsss — Private Messaging Guide

This guide walks you through sending encrypted private messages between two computers over the internet using Tsss. No accounts, no usernames, no data stored on any server.

**Recommended for most users:** install, then run `./tsss chat`. A short wizard collects your IP and a shared secret, and you're chatting with end-to-end encryption in under two minutes. Jump to [The chat command](#the-chat-command--easiest-way) to get started.

The later sections cover the [manual Erlang shell approach](#manual-setup--erlang-shell) for those who want full control or are building on top of Tsss.

---

## What you need

- **Two computers** running macOS or Linux, both connected to the internet
- **Ports 9100–9200 open (TCP inbound)** on both machines — see [Firewall setup](#firewall-setup) below
- About **5 minutes** to install and get started

---

## Step 1 — Install on both computers

Run this on **each machine**:

```bash
curl -fsSL https://raw.githubusercontent.com/tordbjorn77/Tsss/main/install.sh | bash
```

The installer will:
- Install Erlang/OTP if you don't have it (via Homebrew on Mac, apt/dnf on Linux)
- Download the build tool (rebar3)
- Clone and compile Tsss into `~/.tsss/src`
- Create a `./tsss` command in that folder

Once finished, move into the install directory:

```bash
cd ~/.tsss/src
```

---

## Step 2 — Firewall setup

Tsss nodes talk to each other directly over TCP. You need to open a port range on both machines.

### macOS (built-in firewall)
macOS firewall is off by default — you most likely don't need to change anything. If you've turned it on, allow incoming connections for `erl` in **System Settings → Network → Firewall**.

### Linux (ufw)
```bash
sudo ufw allow 9100:9200/tcp
```

### Linux (firewalld)
```bash
sudo firewall-cmd --add-port=9100-9200/tcp --permanent
sudo firewall-cmd --reload
```

### Cloud server (AWS, GCP, Azure)
Add an inbound rule to your security group or firewall:
- **Protocol:** TCP
- **Port range:** 9100–9200
- **Source:** the IP address of the other machine (or `0.0.0.0/0` for any)

### Home router / NAT
If either machine is behind a home router, forward ports **9100–9200 TCP** to that machine's local IP address in your router's admin panel.

---

## Step 3 — Find your IP address

Each node needs to know the other's IP address. Run this to find yours:

```bash
# macOS
ipconfig getifaddr en0

# Linux
hostname -I | awk '{print $1}'
```

Share your IP with the other person (via text, Signal, email — any channel works).

---

## The chat command — easiest way

`./tsss chat` is an interactive chat client that handles everything for you: node startup, key exchange, and messaging — no Erlang shell required.

### First run — setup wizard

The first time you run it, a short wizard walks you through configuration:

```
$ cd ~/.tsss/src
$ ./tsss chat

  ── Tsss Chat Setup ──────────────────────────────────────────
  No config found. Let's get you set up — takes about a minute.

  Detecting your public IP... found: 93.184.216.34
  Your public IP [93.184.216.34]: ↵

  Shared cookie [a3f9c12e4b7d8e1f]: ↵

  Choose a name for yourself — this is the part before @ in your node name.
  Keep it short and memorable. It is shared with peers but not tied to your machine.
  Your name [hawk42]: ↵
  Your node name: hawk42@93.184.216.34

  Enter your peers' full node names (e.g. wolf42@5.6.7.8).
  Your peers see their own node name at the end of setup — ask them to share it.
  Leave blank when done.

  Peer: wolf15@198.51.100.7 ↵
  Peer: ↵

  ── Share this with your peers ───────────────────────────────
  Cookie    : a3f9c12e4b7d8e1f
  Your node : hawk42@93.184.216.34
  (Peers need the cookie AND your node name to connect.)
  ─────────────────────────────────────────────────────────────
```

The wizard saves your settings to `~/.tsss/client.cfg` and starts the node immediately.

**What to share with your peers:** Send them your **cookie** and **node name** over any out-of-band channel (Signal, email, etc.) before you both run `./tsss chat`. They need both to connect.

### What happens next

Once both nodes are running and keys have been exchanged automatically, you'll see the chat banner and a prompt:

```
  +------------------------------------------+
  |  Tsss Encrypted Chat                     |
  |  Handle : hawk-7f3a                      |
  |  Peers  : 1 key-exchanged and ready      |
  +------------------------------------------+
  Type /help for commands. Typing sends to all ready peers.

You>
```

Your session handle (like `hawk-7f3a`) is randomly generated each time — it is not your node name and has no relation to your machine.

Type anything and press Enter to send to all connected peers. Their messages appear automatically between your prompts.

### Chat commands

| Command | What it does |
|---|---|
| `<text>` | Send message to all key-exchanged peers |
| `/to <handle> <text>` | Send to one specific peer by their session handle |
| `/peers` | List connected peers and their key-exchange status |
| `/help` | Show command list |
| `/quit` or `/q` | Wipe session and exit |
| `/wipe` | Destroy session keys immediately and exit |

### Subsequent runs

After the first setup, `./tsss chat` loads your saved config and starts instantly — no wizard.

### Reset configuration

To wipe your saved config and run the wizard again from scratch:

```bash
./tsss chat --reset
```

This is useful if you want to change your node name, cookie, or peer list.

### How key exchange works

When both nodes are online, the chat client automatically:
1. Connects to your configured peer nodes
2. Discovers their session handles via the cluster registry
3. Exchanges encryption keys — no manual copying of public keys needed

If a peer isn't online yet when you start, the client checks every 5 seconds and exchanges keys as soon as they appear.

---

## Manual setup — Erlang shell

The steps below describe the same process using the raw Erlang shell. This gives you full control and is useful for scripting, debugging, or using features not exposed by the chat client.

---

## Step 4 — Start your node

On **each machine**, start Tsss with a unique name and a shared secret cookie. Both machines must use the **same cookie**.

```bash
cd ~/.tsss/src
./tsss console --name tsss@YOUR_IP --cookie choose_a_long_secret_here
```

Replace `YOUR_IP` with your actual IP address, for example:

```bash
# Alice's machine (IP: 1.2.3.4)
./tsss console --name tsss@1.2.3.4 --cookie my_secret_phrase_123

# Bob's machine (IP: 5.6.7.8)
./tsss console --name tsss@5.6.7.8 --cookie my_secret_phrase_123
```

> **The cookie is how nodes recognise each other.** Pick something long and random. Anyone who knows the cookie and can reach your port can connect to your node.

You'll see the Erlang shell prompt:

```
Erlang/OTP 26 ...
Eshell V14.2.5 (press Ctrl+G to abort, type help(). for help)
1>
```

---

## Step 5 — Connect the nodes to each other

In your Erlang shell, tell your node to connect to the other machine. **One person does this** — the connection works both ways.

```erlang
net_kernel:connect_node('tsss@5.6.7.8').
```

Replace `5.6.7.8` with the other person's IP. You should see `true` if it worked.

Verify both nodes see each other:

```erlang
tsss_cluster:members().
```

You should see both node names listed. Give it 5–10 seconds for the leader election to finish, then:

```erlang
tsss_cluster:get_leader().
```

This shows which node was elected the coordinator. Either node can be the leader — it doesn't matter.

---

## Step 6 — Create your session

In your shell, create an anonymous session. The `client => self()` part tells Tsss to deliver incoming messages to your shell.

```erlang
{ok, #{pid := Pid, handle := Handle, pub_key := PubKey}} = tsss_api:new_session(#{client => self()}).
```

You'll get back three things:
- **`Pid`** — the process running your session (you'll use this to send messages)
- **`Handle`** — your anonymous identity for this session, something like `<<"wolf-3a9c">>`
- **`PubKey`** — your public key (a binary of bytes, used for encryption setup)

Check your handle:

```erlang
Handle.
%% → <<"wolf-3a9c">>
```

---

## Step 7 — Share your handle and public key

You and the other person each need to share two things:
1. Your **handle** (short, easy to type)
2. Your **public key** (a binary — copy the whole thing including `<<` and `>>`)

Send these to each other over any channel (text message, email, etc.). They are not secret — your public key is designed to be shared.

To see your public key in a copyable format:

```erlang
binary:encode_hex(PubKey).
%% → <<"A3F2...long hex string...">>
```

The other person can decode it back:

```erlang
BobPubKey = binary:decode_hex(<<"A3F2...the hex they sent you...">>).
```

> **Tip:** If you're both sitting at computers on the same network, you can use `lookup_handle` instead of manually copying the public key — see [Shortcut for same-network users](#shortcut-for-same-network-users) below.

---

## Step 8 — Exchange keys

Once you each have the other person's handle and public key, both of you run this in your own shell:

```erlang
%% Alice runs this (using Bob's handle and pubkey):
tsss_api:exchange_keys(Pid, <<"wolf-3a9c">>, BobPubKey).

%% Bob runs this (using Alice's handle and pubkey):
tsss_api:exchange_keys(Pid, <<"hawk-f12a">>, AlicePubKey).
```

Both should return `ok`.

This performs an ECDH key agreement — both sides independently compute the same encryption key without ever sending it over the network. From this point on, all messages between you are encrypted with that shared key.

---

## Step 9 — Send a message

```erlang
tsss_api:send(Pid, <<"wolf-3a9c">>, <<"Hello! Can you see this?">>, 0).
```

Arguments:
1. Your session `Pid`
2. The recipient's handle
3. The message text (as a binary — wrap it in `<<"` and `">>`)
4. Time-to-live in milliseconds (`0` means the message stays until you wipe it)

---

## Step 10 — Receive messages

Incoming messages appear in your shell automatically. If you don't see one, type:

```erlang
flush().
```

This prints all messages that arrived at your shell process. You'll see something like:

```
Shell got {tsss_event,{message,<<"hawk-f12a">>,<<"Hello! Can you see this?">>}}
ok
```

The format is `{tsss_event, {message, SenderHandle, MessageText}}`.

To wait for the next message (blocking, 60-second timeout):

```erlang
tsss_api:recv_blocking(Pid, 60000).
%% → {ok, {message, <<"hawk-f12a">>, <<"Hello!">>}}
```

---

## Self-destructing messages

Add a TTL (in milliseconds) to make a message disappear automatically:

```erlang
%% This message deletes itself after 30 seconds:
tsss_api:send(Pid, <<"wolf-3a9c">>, <<"Gone in 30 seconds">>, 30000).

%% 5 minutes:
tsss_api:send(Pid, <<"wolf-3a9c">>, <<"Gone in 5 minutes">>, 300000).
```

The timer starts when the message is sent. Once it fires, the message is removed from the recipient's mailbox in memory.

---

## Ending a session

When you're done, wipe the session. This destroys your encryption keys and removes your handle from the network — as if you were never there.

```erlang
tsss_api:wipe_session(Pid).
```

To quit the Erlang shell:

```erlang
q().
```

---

## Emergency kill switch

If you need to wipe everything on all connected nodes immediately:

```erlang
tsss_api:kill_switch().
```

This broadcasts a wipe command to every node in the cluster, clears all session data and keys from memory, disconnects all nodes, and shuts them all down within 500ms. Use this if you need to ensure no trace of the session remains anywhere in the cluster.

---

## Shortcut for same-network users

If both you and the other person are already connected in the same Tsss cluster, you can skip manually copying public keys. Just share handles, then look up the public key automatically:

```erlang
%% Alice already knows Bob's handle is <<"wolf-3a9c">>
%% She can get his public key directly from the cluster:
{ok, BobPubKey} = tsss_api:lookup_handle(<<"wolf-3a9c">>).
tsss_api:exchange_keys(Pid, <<"wolf-3a9c">>, BobPubKey).
```

This only works after Bob has already created his session (Step 6).

To see everyone currently online in the cluster:

```erlang
tsss_api:list_handles().
%% → [<<"wolf-3a9c">>, <<"hawk-f12a">>]
```

---

## Quick reference

### Chat client

| What you want to do | Command |
|---|---|
| First-time setup and start chat | `./tsss chat` |
| Start chat (config already saved) | `./tsss chat` |
| Reconfigure from scratch | `./tsss chat --reset` |
| Send to all peers | type your message and press Enter |
| Send to one peer | `/to <handle> <message>` |
| List peers | `/peers` |
| Exit and wipe session | `/quit` |

### Erlang shell

| What you want to do | Command |
|---|---|
| Create a session | `{ok, #{pid := Pid, handle := H, pub_key := K}} = tsss_api:new_session(#{client => self()}).` |
| See your handle | `H.` |
| See your public key (hex) | `binary:encode_hex(K).` |
| Decode a received hex key | `K = binary:decode_hex(<<"hex...">>).` |
| Connect to another node | `net_kernel:connect_node('tsss@1.2.3.4').` |
| Check who's in the cluster | `tsss_cluster:members().` |
| See who's online | `tsss_api:list_handles().` |
| Exchange keys | `tsss_api:exchange_keys(Pid, <<"handle">>, PubKey).` |
| Send a message | `tsss_api:send(Pid, <<"handle">>, <<"text">>, 0).` |
| Send with self-destruct (30s) | `tsss_api:send(Pid, <<"handle">>, <<"text">>, 30000).` |
| Check for messages | `flush().` |
| Wait for next message | `tsss_api:recv_blocking(Pid, 60000).` |
| Wipe your session | `tsss_api:wipe_session(Pid).` |
| Wipe the whole cluster | `tsss_api:kill_switch().` |
| Quit the shell | `q().` |

---

## Troubleshooting

**`./tsss chat` says "Could not parse client.cfg"**

- Your config file at `~/.tsss/client.cfg` may be malformed. Run `./tsss chat --reset` to delete it and go through the wizard again.

**Peer doesn't appear after both nodes are running**

- Make sure both sides used the **same cookie**. The cookie is checked by Erlang's distribution layer before any connection is made.
- Check that the node name the peer entered matches exactly what you shared — including the part before `@`. Node names are case-sensitive.
- Verify ports 9100–9200 are open on both machines (see [Firewall setup](#firewall-setup)).

**`/peers` shows no peers or all peers as "key-pending"**

- The peer may not have started their chat session yet, so their handle isn't registered. Give it a moment — the client re-checks every 5 seconds.
- If a peer shows "key-pending" for more than 30 seconds, they may have restarted their session. Their new handle will be discovered automatically.

**Messages I send don't arrive on the other side**

- Check `/peers` — you can only send to peers shown as `ready`. If your peer shows `key-pending`, wait for automatic key exchange to complete.
- If no peers appear at all, check the node connection (see above).

**`./tsss chat --reset` deleted my config but I want to keep the cookie**

- The cookie is just a shared password. You can reuse any cookie — type it manually when the wizard asks instead of pressing Enter for a new one.

---

**`tsss_cluster:members()` only shows my node**

The nodes haven't connected yet. Check:
1. Did you run `net_kernel:connect_node('tsss@OTHER_IP').` and get `true`?
2. Are ports 9100–9200 open on both machines? Try `telnet OTHER_IP 9100` to test.
3. Are both nodes using the exact same `--cookie` value?
4. Is the node name an exact IP address, not a hostname? Try `tsss@1.2.3.4` format.

**`net_kernel:connect_node(...)` returns `false`**

- The other node is not reachable. Check firewall rules and that `./tsss console` is running on the other machine.
- Verify the IP is correct: `ping OTHER_IP` should work first.

**`lookup_handle` returns `{error, not_found}`**

- The other person hasn't created their session yet (Step 6). Ask them to run `tsss_api:new_session(...)` first.
- Or their session handle TTL expired — they need to create a new session.

**Messages not appearing in my shell**

- Make sure you created your session with `client => self()`. If you forgot, create a new session with that option.
- Type `flush().` to see any messages that already arrived.

**`exchange_keys` returns an error**

- Double-check the public key binary. The `<<` and `>>` must be included.
- Make sure you decoded the hex correctly: `binary:decode_hex(<<"...hex...">>) `.

**Node name error: `...not alive...`**

- The Erlang node name must be started before connecting. Make sure `./tsss console --name tsss@YOUR_IP` is running.
- Use your actual IP address, not `localhost` or `127.0.0.1`, when connecting between machines.

---

## Security notes

- **No accounts.** Tsss has no signup, no login, no server that knows who you are.
- **Your handle is temporary.** It's randomly generated each session and disappears when you wipe it.
- **Messages are encrypted on your machine** before they travel anywhere. Intermediate nodes in the cluster only ever see encrypted bytes.
- **Keys exist only in RAM.** When you call `wipe_session()` or close the shell, your private key is gone — nothing is written to disk.
- **The cookie is your access control.** Keep it secret. Anyone with the cookie and network access can join your cluster.
- **Self-destruct is real.** TTL-expired messages are removed from memory, not just hidden.

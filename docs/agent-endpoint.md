# The agent endpoint

`alohajet -p "<prompt>"` runs no agent loop. It POSTs one turn to an HTTP server and  
reports what comes back. The default is `http://127.0.0.1:8765`, the Aloha browser's own  
automation server; `--endpoint <url>` names any other.

## Ground rules

**Base URL.** Routes are appended to `--endpoint`, preserving any path it carries, so
`--endpoint http://host/api` gives `http://host/api/agent/run`.

**Scheme.** `http` is accepted only to a loopback host (`localhost`, `127.0.0.0/8`, `::1`,
parsed with `inet_pton`, not prefix-matched). `https` is accepted anywhere. Anything else
is refused at argument-parse time with exit 2, before the prompt leaves the machine.

**Auth.** Every route is expected to be bearer-token gated. The token is read *per request*
(so rotation needs no restart): `ALOHAJET_AGENT_TOKEN` if set, otherwise
`~/Library/Application Support/Aloha/automation-token` — and that ambient file is sent to a
**loopback endpoint only**. A non-loopback endpoint gets a credential from the environment
variable or not at all, and `alohajet` says so on stderr. With no token there is no
`Authorization` header and no unauthenticated retry: answer `401` and the user sees it.

**Content-Type.** `application/json` is sent on `POST /agent/run` and `POST /agent/terms`
only. `POST /agent/task` carries the raw prompt as the body and is deliberately unlabelled.

**Failures are values.** Transport errors, non-200s and undecodable bodies all become a
`failed` run result on this side; `-p` exits 1 and prints the reason. Nothing throws.

## 1. Protocol probe — `GET /agent/lane`

The first request of every turn, and the only one made before anything is decided.


| answer                                               | meaning                                          |
| ---------------------------------------------------- | ------------------------------------------------ |
| `200` with `{"protocol": 2, "conversation": "<id>"}` | protocol 2 (below)                               |
| anything else, including `404`                       | protocol 1 (legacy, [below](#legacy-protocol-1)) |


A new server should answer protocol 2. `conversation` is the chat the server is currently
on; it is what `--continue` pins, and its absence makes `--continue` fail by name.

## 2. The turn — `POST /agent/run`

```json
{ "prompt": "book me a table", "permissions": [], "conversation": "UUID" }
```

`conversation` is omitted for a fresh chat. `permissions` is what the run grants the page —
`camera`, `microphone`, `geolocation`, `storage_access`, `external_scheme`. `-p` sends `[]`,
which denies everything.

`200` answers:

```json
{ "taskId": "<opaque>", "conversation": "UUID", "known": true }
```

`conversation` is the chat the server **actually ran in** — when the request named one, an
answer that differs (case-insensitively) fails the turn, and a missing one fails it too.
`known: false` on a resume means the id named no existing chat; the client warns and
carries on rather than making a printed id dead forever. A `200` without `taskId` fails.

Refusals, each reported in the user's words:


| status | `error`                | what `-p` prints                             |
| ------ | ---------------------- | -------------------------------------------- |
| `409`  | `permissions_conflict` | the server's own `message`                   |
| `409`  | anything else          | that conversation already has a turn running |
| `400`  | `empty_prompt`         | `-p` needs a non-empty prompt                |
| `400`  | `bad_conversation_id`  | the server's own `message`                   |
| `415`  | —                      | body rejected; this browser is too old       |
| other  | —                      | the raw status and body, unsmoothed          |




## 3. The poll — `GET /agent/result?taskId=<id>`

Every 250 ms, with a 10 s request timeout, up to 2400 polls (~10 minutes) before the wait
is abandoned as a timeout. 20 *consecutive* transport failures abandon it sooner; a single
dropped poll costs one attempt, not the run, because the server may be on a blocked main
thread.

```json
{ "state": "running", "pendingTerms": { … } }
{ "state": "done", "result": { … } }
```


| `state`       | outcome                                         |
| ------------- | ----------------------------------------------- |
| `running`     | poll again                                      |
| `done`        | decode `result` (below)                         |
| `rejected`    | failed — empty prompt, nothing to run           |
| `displaced`   | failed — unknown, evicted or superseded task id |
| anything else | failed — unknown state                          |


Any non-200, or an envelope with no `state`, fails the turn.

### The terminal result

`result` decodes as:

```json
{ "finalText": "…", "completion": "end_turn", "failureReason": null }
```

`completion` is one of `end_turn`, `max_turns`, `stuck_repeated_tool_error`, `failed`,
`interrupted`. `finalText` and `failureReason` are nullable.

**Do not send a success flag.** The verdict is re-derived on this side: a run succeeds only
when `completion` is `end_turn` *and* `finalText` is non-null. A `done` state with a missing
or undecodable `result` is itself a failure.

### Terms of service, mid-run

A `running` envelope may carry:

```json
{ "pendingTerms": { "id": "…", "termsUrl": "https://…", "privacyUrl": "https://…",
                    "answerableInApp": false } }
```

All four fields are required. A `pendingTerms` object missing any one of them decodes to
no question at all: the client asks nothing, warns about nothing, and keeps polling — and
the turn then waits for an answer that cannot come.

The client asks the user once per `id` and replies `POST /agent/terms` with
`{"id": "…", "accept": true}`. `200` and `409` are both accepted; anything else is a
stderr notice, not a failure. Polls carrying a question draw on a separate budget of 2400
polls (~10 minutes) before they start consuming the turn's own, so ordinary deliberation
cannot time the turn out. Expire a question yourself rather than leaving one standing.

## 4. `POST /quit`

Stops the instance at `--endpoint`. `200` is success; anything else is reported on stderr.

## Legacy: protocol 1

Served only for hosts that predate the probe. It cannot bind a turn to a conversation, so
two overlapping turns race; the client warns and runs anyway. Do not implement it in a new
server.

1. `POST /agent/new` with `{"sessionId": "<id>"}` (or no body for a fresh chat) →
  `{"sessionId": "<id>"}`. A mismatch, or a missing id, fails the turn.
2. `POST /agent/permissions` with `{"permissions": [...]}` — sent on every run, including
  the empty deny list, so a run never inherits the previous one's grants.
3. `POST /agent/task` with the **raw prompt** as the body → `{"taskId": "…"}`.
4. The same poll as above.


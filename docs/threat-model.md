# Threat model

Read this before pointing alohajet at anything you are logged into.

**alohajet drives a real browser. It is not a sandbox, and it is not a
security boundary.** The tools do what a person sitting at that browser could
do: navigate it, read the rendered page, click, type, select, press keys. If
the browser it is driving is signed in to something, so is the agent using
alohajet.

## The lanes are not equally exposed


| Lane                            | Browser                                                                                                                             | What is reachable                                                                                                                                                                                         |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| default (shared) and `--launch` | Chromium that alohajet launches itself, on a throwaway profile under the temp directory                                             | Only what the agent itself navigates to. No cookies, no saved logins, no history — the profile starts empty and is deleted on `alohajet quit` or on SIGINT/SIGTERM.                                       |
| `--cdp <endpoint>`              | a browser someone else started; alohajet never launches or terminates it                                                            | **Everything in that browser.** Every open tab, every live session cookie, every logged-in application. If you point `--cdp` at your everyday browser, you have handed the agent your logged-in accounts. |
| `--browser aloha`               | the Aloha browser, over its own CDP listener on `127.0.0.1:9222` (`ALOHA_CDP_PORT`); started if it is not running, never terminated | **The same as** `--cdp`**.** It needs no flag pointing at a port and no browser started in debug mode: the listener is the browser's own, so the exposure is one word on a command line away.             |


`--cdp` and `--browser aloha` against a personal profile are a deliberate
capability, not an oversight. Use them knowing what they grant. On the aloha
lane, `manage_tabs` marks the user's pre-existing tabs and refuses to close
them; that is a courtesy to the human, not a confidentiality boundary — every
one of those tabs is still readable.

## The CDP endpoint has no authentication

Chrome's `--remote-debugging-port` is unauthenticated by design. Any process  
running as the same user can connect to it and issue any DevTools command —  
read cookies, evaluate JavaScript on any origin, navigate anywhere. alohajet  
does not add a credential to that port and could not enforce one if it did:  
the port is Chrome's, not ours. Loopback binding is Chrome's default, not a  
guarantee this package makes. **Treat an open debugging port as full control**  
**of that browser by anything on the machine.**

## The other defences, and their defaults

- **Password-field masking — on, always.** The in-page walker and `get_text`
blank the *value* of fields classified as credential fields
(`../Sources/BrowserTools/Runtime/SensitiveFieldScript.swift`), in the page,
before the value can cross the CDP wire. Classification is by `type=password`
plus a fragment match on name/id/placeholder/aria-label/autocomplete. It is a
heuristic: a credential field named nothing like one is not caught.
- **Credential-typing refusal — off by default.** Set
`ALOHAJET_CREDENTIAL_GUARD=1` to make `page_type` refuse to type into a field
it classifies as a credential field and hand entry back to the human.
- **Network logging — off by default.** No traffic is written to disk unless
`ALOHAJET_NETWORK_LOG` is set. When it is on, credential-bearing headers
(`cookie`, `set-cookie`, `authorization`, `x-api-key`, …) and
credential-named body fields are masked, and URL-valued headers get the same
query-string redaction the request URL gets. What remains is still a
plaintext record of everything the agent's tabs requested, in a file on
disk. Turn it on for debugging, not for a session that matters.
- **Launched browsers are reaped.** SIGINT and SIGTERM terminate a Chromium  
this process launched and delete its throwaway profile. A browser reached  
through `--cdp` or `--browser aloha` is the user's and is deliberately left alone — including tabs alohajet itself opened in it, which for the same reason it also cannot close.


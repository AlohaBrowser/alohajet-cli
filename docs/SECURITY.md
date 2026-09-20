# Security

## Supported versions

The latest release. Fixes land on `main` and ship in the next tag; older tags are not
patched.

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting:

    https://github.com/AlohaBrowser/alohajet-cli/security/advisories/new

Please do not open a public issue, pull request or discussion for a vulnerability; the
advisory thread stays private to you and the maintainers until a fix ships.

A useful report contains: the alohajet commit you tested, the connection lane (`--cdp`,
`--browser aloha`, or the default launched browser), the Chrome/Chromium version, the
exact tool calls or CLI commands in order, and what you observed versus what you expected.
A transcript is worth more than a description; a reproduction page is worth more than
either.

## What counts

[threat-model.md](threat-model.md) states what this package defends and what it
deliberately does not. The absence of a host policy, a sandbox or prompt-injection
detection is a design limit, not a defect. A *bypass* of a defence the threat model claims
— page text escaping the field masking, a non-`http(s)` tab reached through a content
tool, a credential surviving into the network log — is in scope.

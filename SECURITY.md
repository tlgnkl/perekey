# Security policy

## Reporting a vulnerability

Report privately through GitHub: open the **Security** tab of this repository,
then **Report a vulnerability** (private vulnerability reporting). Do not open a
public issue. We aim to reply within a week.

## Scope

Perekey watches keystrokes, so these areas matter most:

- The event tap: anything that lets another process read or inject keystrokes through Perekey.
- Permissions: Accessibility and Input Monitoring handling, or escalation beyond them.
- Privacy: typed text reaching logs, disk, pasteboard leftovers or the network; handling of Secure Input and password fields.
- The update channel and app signing.

Wrong corrections are not security issues; use the "False switch" issue template.

# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/lirriel/DragonLair/security/advisories/new),
not in a public issue.

Include what you found, how to reproduce it, and what an attacker could do with it.
You should hear back within a week.

## Supported versions

Only the latest commit on `main` is supported. Fixes are not backported.

## Scope

Things worth reporting include:

- API keys leaking out of the Keychain, into logs, backups or the share extension
- screenshots or other data sent anywhere other than the AI provider the user chose
- requests the app can be tricked into making to local or private network addresses
- crafted screenshots, backups or web pages that crash the app or corrupt the library

Problems in the AI providers or cover sources themselves should go to those services.

# Peer Login asks the source at every sign-in and keeps a cached password

Server Sync never creates users and does not sync passwords, so without more a
replica needs a second set of users. Peer Login, an authentication provider on
the replica, forwards each sign-in to the source and lets the source's answer
decide. It creates the replica user at their first accepted sign-in (R-LOGIN-1,
R-LOGIN-2). It also keeps a cached password, which signs a user in only while
the source is unreachable (R-LOGIN-3), because the replica exists to keep
serving its users then. The source needs no changes.

## Considered Options

- LDAP or single sign-on plugins. They need a separate identity service, and
  that service would also have to be reachable while the source is not.

## Consequences

- The replica handles plaintext passwords, so it sends them to the source only
  over HTTPS (R-LOGIN-7).
- The source owns each password. The replica refuses password changes for Peer
  Login users, including an administrator's reset (R-LOGIN-5).
- A Peer Login user is tied to a source user by name only. Disabling or
  deleting the source user refuses their later sign-ins that reach the source,
  but their replica sessions and cached password stay valid until the replica
  user is disabled or deleted too.
- The source's lockout counts forwarded sign-ins. Attempts against the cached
  password while the source is unreachable are limited only by the replica's
  own lockout.
- Peer Login never copies administrator rights (R-LOGIN-6). A new replica user
  gets Jellyfin's default policy, which includes access to all libraries.
- Peer Login creates no user mapping. `sea-nettle setup` maps a spec user on
  its next run after their first sign-in.

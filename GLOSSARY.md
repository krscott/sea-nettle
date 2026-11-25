# sea-nettle

sea-nettle runs a replica Jellyfin server next to a source server, so that
users near the replica get the source's media and sign in with their source
credentials. This glossary names the concepts that the code, the commands, the
requirements, and the documentation share.

## Language

### Servers

**Source**:
The Jellyfin server that holds the media and is the authority for its users'
passwords.
_Avoid_: origin, primary, upstream

**Replica**:
A Jellyfin server near a group of users that presents the source's libraries
without owning the media, and that the source's users sign in to.
_Avoid_: mirror, cache machine, regional server

**Role**:
Which of the two a server is in its pair: source or replica.

**Pair**:
One source and one replica of that source.
_Avoid_: cluster, deployment

**Peer**:
A server's counterpart in Server Sync, as that server sees it. In a pair, each
server is the other's peer.
_Avoid_: remote, partner

**Operator**:
The person who runs a server: they rebuild the system, run the `sea-nettle`
command, and use the dashboard.

**Configuration**:
The settings of Jellyfin and its plugins that an operator controls, whoever
first set them: network settings, users, libraries, plugin settings, peer
entries, mappings, and caller grants. State that a server keeps for itself,
such as sessions, sign-in dates, and pairing secrets, is not configuration.

**HTTPS endpoint**:
The one HTTPS address at which other machines reach a server's Jellyfin.
_Avoid_: public URL, serve port (for the address)

**Media directory**:
The directory of media that a server's Jellyfin can read and cannot change.

**Pinned plugin**:
A plugin that the NixOS modules hold at one exact version.
_Avoid_: managed plugin

**Claimed server**:
A server that has an administrator with a password. An unclaimed server lets
anyone who reaches it become its administrator.
_Avoid_: initialized server

### Users

**User**:
A Jellyfin user on one server. Two users with the same name on the two servers
are separate users.
_Avoid_: account (except in "sync account")

**Administrator**:
A user with Jellyfin's administrator rights on their server.

**Standard user**:
A user without administrator rights.
_Avoid_: limited account, limited key, ordinary user

**Initial administrator**:
The administrator that the operator names for a server. sea-nettle creates it
to claim a new server, and the `sea-nettle` command signs in as it.
_Avoid_: configured administrator, local administrator

**Peer Login**:
The plugin on the replica that signs users in with their source credentials.
Despite its name, the only server it asks is the source.
_Avoid_: login plugin

**Peer Login user**:
A replica user whose authentication provider is Peer Login.
_Avoid_: source-backed user

**Local user**:
A replica user whose authentication provider is not Peer Login.
_Avoid_: local account, local (for "on this server")

**Sync account**:
A dedicated user on one server that the peer's entry signs in as. No person
signs in with it.
_Avoid_: service account, source account (for the source's sync account)

**Spec user**:
A source user that the setup spec names.
_Avoid_: person, ordinary source user

**Cached password**:
The password, kept as a hash, that the replica checks a Peer Login user's
sign-in against only while the source is unreachable. It is the last password
the source accepted through the replica, or the password the user had as a
local user if they have not signed in through the source since they were
switched to Peer Login.
_Avoid_: cached hash, stored hash

**Unreachable**:
Said of a server that does not answer. At a sign-in, the source is unreachable
when the connection fails, it does not answer in time, or it answers with a
server error; a refusal or any other answer is not unreachable. A peer is
unreachable when the link check, or `setup`'s own call to it, says so, which can
include a peer that refuses the entry key.
_Avoid_: unavailable, down, offline

### Server Sync

**Server Sync**:
The third-party Jellyfin plugin that syncs content, watch history, and user
settings between peers.

**Peer entry**:
One server's record of a peer in Server Sync: where the peer is, how to sign in
to it, and what to sync with it. "Entry" for short.
_Avoid_: server (Server Sync's dashboard name), peer record

**Server ID**:
The identifier a Jellyfin server reports for itself. A peer entry records its
peer's server ID.

**Entry ID**:
A peer entry's own identifier within one server's Server Sync.
_Avoid_: key, server key (Server Sync's field names)

**Entry key**:
The credential a peer entry stores to call its peer: an access token of a user
on the peer, or one of the peer's API keys.
_Avoid_: stored key, peer key

**Caller grant**:
A server's permission for one of its users to call its Server Sync as a peer.
_Avoid_: caller access, peer grant, whitelist (Server Sync's dashboard name for
the list of grants)

**Link check**:
Server Sync's check of one peer entry: whether the peer answers, lists this
server, and pairs with it.
_Avoid_: peer check, connection test, link (for the connection between peers)

**Pairing**:
Server Sync's handshake for one direction between two peers, in which the
checked server gives the checking server a pairing secret. A pair is fully
paired when each server has paired its own direction.

**Pairing secret**:
The secret that a pairing exchanges. Server Sync creates and renews it.

**Link**:
A video in a replica library that refers to the source's media instead of being
a copy. It plays from the source, or from the link cache.

**Link cache**:
The replica's temporary copies of linked videos, kept within limits the
operator sets.
_Avoid_: cache (alone)

**Library mapping**:
A rule in the replica's entry for the source that ties one source library to one
replica library, and says what to sync from it and how to store it.

**User mapping**:
A rule in the replica's entry for the source that ties one source user to one
replica user. Their watch history can then sync, and a source whose sync
account is an administrator streams the replica user's links as that source
user.

**Link fallback user**:
The source user, named in the source's entry for the replica, as whom the
source streams links for a replica user it cannot tie to a source user of their
own.

**Content whitelist**:
The top-level items of a library that the setup spec asks to sync, in place of
all of its content.

### Setup and status

**Setup spec**:
The one description of a pair that both of its servers share, from which
`sea-nettle setup` works. "Spec" for short.
_Avoid_: pair spec, setup configuration

**Library key**:
The short name the setup spec gives a library. It names the library's folder on
the replica.

**Run**:
One invocation of `sea-nettle setup` or `sea-nettle status` on one server.

**Report**:
The result of a run: this server's peers, what the run changed, its findings,
and its waiting items.

**Finding**:
Something a report says needs attention, with how to fix it.
_Avoid_: attention (for one item), attention item

**Conflict**:
A finding that existing configuration contradicts the setup spec.

**Waiting item**:
Something `setup` cannot do until an event that no operator brings about, such
as a spec user's first sign-in to the replica. A report lists it, and it is not
a finding.

erlang\_couchdb is a really simple CouchDB client. Simple means that it does as little as possible and doesn't get in the way. I developed this module because the existing modules seemed too big and did too much for my taste. This module provides several public functions to do things like manipulating databases, documents and views.

The implemented functionality is really limited because I'm only really implementing the stuff that I'm using in I Play WoW.

* Get server information
* Create database
* Get database information
* Create document
* Create document with specific ID
* Update document
* Get document
* Create design document
* Invoke a design document

A quick demo:

    erlang_couchdb:create_database({"localhost", 5984}, "iplaywow").
    erlang_couchdb:database_info({"localhost", 5984}, "iplaywow").
    erlang_couchdb:server_info({"localhost", 5984}).
    erlang_couchdb:create_document({"localhost", 5984}, "iplaywow", [{<<"name">>, <<"Korale">>}, {<<"type">>}, <<"character">>}]).
    erlang_couchdb:retrieve_document({"localhost", 5984}, "iplaywow", "0980...").
    erlang_couchdb:update_document({"localhost", 5984}, "iplaywow", "0980...", [{<<"_rev">>, <<"3419...">>}, {<<"name">>, <<"Korale">>}, {<<"level">>, <<"70">>}, {<<"type">>}, <<"character">>}]).
    erlang_couchdb:delete_document({"localhost", 5984}, "iplaywow", "1fd0...", "1193...").
    erlang_couchdb:create_view({"localhost", 5984}, "iplaywow", "characters", <<"javascript">>, [{<<"realm">>, <<"function(doc) { if (doc.type == 'character')  emit(doc.realm_full, null) }">>}]).
    erlang_couchdb:invoke_view({"localhost", 5984}, "iplaywow", "characters", "realm", [{"key", "\"Medivh-US\""}]).

Patches are welcome. For the time being this module should be considered alpha. Support is limited but feel free to contact me via email and submit patches. If you use this module please let me know.


couchdb\_lier
=============

Problem Description
-------------------

CouchDB is an atomically-accessible Key-Value storage.  It guarantees
consistency for reading and writing on a per-document basis.

We, however, desire the ability to operate on multiple documents while
using a consistent database and must not disturb other
transactions. CouchDB provides no locking.

CouchDB Prerequisites
---------------------

CouchDB automatically assigns revisions to data records
(documents). When updating a document, the client must pass the
current revision identifier within the HTTP PUT request. If this
revision doesn't match with the revision of the document currently
stored in CouchDB, the PUT request will be denied.

Additionally, we can use CouchDB's bulk update interface and extend
this revision consistency to multiple documents at once by writing.

The Approach
------------

A transaction uses the process dictionary as a document/revision
cache. Read data is being placed there with document content and
revision. Document write and delete operations are being delayed until
the user-provided transaction Fun() has ended. This allows us to
exploit the bulk update interface and ensure consistency over the
database.

Write-only documents will always be fetched to retrieve their
revision.

Because it is important that read but not modified documents are
consistent with the ones being written, if there are documents to be
written, the only-read documents will also be written.

If that bulk update request goes wrong, meaning that some data the
transaction depended on was modified while the transaction ran, we
clean up and restart everything. This is the same that mnesia
(although with locking) and ejabberd\_odbc (with sophisticated
databases behind) do.

Corner Case: No Writes
----------------------

As an optimization when there are no documents to write no bulk update
will be done. This imposes that all other users use the bulk update
interface, too, when modifying multiple documents and the database is
thus always consistent.

Can't Transaction Restarting Loop Forever?
------------------------------------------

The main doubt is: when there are many writers to the same document,
won't they always restart each other?

No, because all clients do only one write by using the bulk update
function. When all clients are disturbing each other, that means no
writes are being performed, which means at least one client succeeds.

There is a test/couch\_lier\_counter.erl program which uses parallel
workers to get, increase, and put a counter value. It finishes within
61 restarted transactions for one worker at 100 workers total. While
running, CouchDB accounts for much more CPU than our Erlang
instance. Of course, the counter value amounts to the number of
workers that increased it.

Nevertheless, the goal should be to avoid transaction restarts most of
the time. Calculate data before and keep transactions short!

Do not spawn processes or execute network communication/message
passing in transactions. Think of it as (database-)pure code that must
have no side-effects. Use the transaction Fun() return value to pass
data to code outside a transaction. This will avoid bad effects when
transactions are being restarted.

Why Use Mnesia to Look Up Databases?
------------------------------------

Before any CouchDB request the database server and port are being
dirty\_read from mnesia. This is a bit of overhead, but mnesia
provides fast real-time queries and the current bottlenecks are the
CouchDB backend itself and erlang_couchdb creating one HTTP connection
per request.

By storing database information in mnesia we are preparing for future
features of connection pooling and load-balancing.

couch\_lier API
---------------

The API is being designed to resemble mnesia functionality. The
transaction functions work like their mnesia
counterparts. Nevertheless, you cannot replace usage of mnesia by
search and replace because CouchDB is fundamentally different: data
records (documents) are always identified by their \_id key, are
always JSON-encoded and possess revisions which must be taken care of
when using the dirty interface.

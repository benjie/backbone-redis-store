Work in Progress
================

This is a work in progress, it's not been thoroughly tested in
development, let alone production. You have been warned.

Alternatives
------------

There are npm modules that serve the backbone/redis storage problem, but
they seem to include socket.io or similar transports to synchronize to
the browser. This is great if you need that functionality, but I simply
what a backbone.js redis store that neither knows about nor cares about
the client.

 * <https://github.com/sorensen/backbone-redis> [Blog
   post][sorensen/introducing]
 * <https://github.com/JeromeParadis/server-backbone-redis>

[sorensen/introducing]: https://sorensen.posterous.com/introducing-backbone-redis

backbone-redis-store
====================

backbone-redis-store is intended to be a simple (yet powerful) bridge
between backbone.js and redis.

It is written in CoffeeScript, so you'll need CoffeeScript to run it.

Features
--------

 * MIT license
 * Written in CoffeeScript
 * Overrides Backbone.sync to check for `redisStore` and take appropriate
   action (should revert back to old Backbone.sync if no `redisStore` is
   found)
 * Stores models to redis (as values to a `model.id` keyed hash)
 * Auto-increment ids (optional, can be overridden)
 * Can enforce unique values for arbitrary keys (optional)
 * Indexing (currently only indexes unique keys)
 * Find model by unique key (asynchronously loads if not already loaded)
 * Sets (e.g. foreign key lookups)

Storage
-------

Stores the model as JSON encoded data into a redis hash named
`options.key`, where the `id` of the model is the key to the hash.

Auto-increment counter is stored as `next|{options.key}`

Unique indexes are stored as a normal redis key:
`unique|{options.key}:{field}|{value.toLowerCase()}` with value:
`model.id`. They are not stored in a hash so that we can avoid the use
of `WATCH` and instead use `MSETNX` to check and set the unique keys.

Why avoid WATCH?
----------------

Simply because we're sharing one redis connection across all clients
(probably) - we don't want various other `WATCH`s to conflict, or an
`UNWATCH` to cancel our watch. An alternate solution would be to use a
separate redis connection per transaction - this may be implemented in
future.

Usage
-----

Dependencies:

 * [Backbone][Backbone]
 * [node_redis][node_redis]

To use it, you would:

```coffeescript
# Create a new redisClient (npm install redis)
redisClient = require('redis').createClient()

# Require backbone (npm install backbone)
Backbone = require 'backbone'

# Import backbone-redis-store
RedisStore = require './backbone-redis-store'

# Implement RedisStore's Backbone.sync method
RedisStore.infect Backbone

# Define yourself a new model
class MyModel extends Backbone.Model
  username: null
  uniqueNumber: null
  somethingElse: null

# Define a collection, setting a `redisStore` property
class MyModelCollection extends Backbone.Collection
  redisStore: new RedisStore
    key: 'mymodel'
    redisClient: redisClient
    unique: ['username','uniqueNumber']
  model: MyModel

# Create a new instance of this collection and populate it
myModelCollection = new MyModelCollection()
myModelCollection.fetch()
```

Note: I would not recommend doing the last line for large stores - I would lazily fetch
data as you need it using `myModelCollection.getByUnique` or similar.

RedisStore options
------------------

`new RedisStore` takes the following options:

 * `key` - the redis key under which to store the model data
 * `redisClient` - the connection to redis to use for storage
 * `unique` - an array of columns of the model that should be treated as
   unique indexes. An empty array is perfectly valid.

Backbone.Collection.getByUnique
-------------------------------

`Backbone.Collection.getByUnique(key, value, options)`

 * `key` - the model key to look for
 * `value` - the value of said key to look for
 * `options` - accepts `success` and `error` callbacks like many Backbone
   methods

Future
------

I intend to add the following features in time:

 * Non-unique indexes
 * Redis pub/sub notification of updates (allows a cluster of
   NodeJS/Backbone instances to stay in sync)
 * Better error handling
 * Package as an npm module
 * Redis connection pooling (maybe)

If you fancy contributing, please get in touch! :)

[node_redis]: https://github.com/mranney/node_redis
[Backbone]: https://github.com/documentcloud/backbone

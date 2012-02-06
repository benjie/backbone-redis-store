###
backbone-redis-store - a simple backbone/redis bridge

Stores data inside hashes in Redis for fast lookup

Inspired by:
  https://github.com/jeromegn/Backbone.localStorage
###

_ = require 'underscore'
EventEmitter = require('events').EventEmitter

###
Takes two arguments:
  * `name` - the name to be used as the key for the hash in Redis
  * `redis` - the redis connection (using https://github.com/mranney/node_redis)
###
class RedisStore extends EventEmitter
  constructor: (@name, @redis) ->
    super

  ###
  Override this if you want to change the id generation

  Currently generates an auto-increment field stored under next.@name
  ###
  generateId: (cb) =>
    @redis.INCR "next.#{@name}", cb

  create: (model, options) ->
    next = =>
      @redis.HSETNX @name, model.id, JSON.stringify(model.toJSON()), (err, res) =>
        if err
          options.error err
        else
          options.success model

    unless model.id
      @generateId (err, id) =>
        if err
          options.error "Couldn't generate id for new record."
        else
          model.id = id
          model.set 'id', id
          next()
    else
      next()
    return

  update: (model, options) ->
    @redis.HSET @name, "#{model.id}", JSON.stringify(model.toJSON()), (err, res) =>
      if err
        options.error err
      else
        options.success model
    return

  find: (model, options) ->
    @redis.HGET @name, "#{model.id}", (err, res) =>
      if err
        options.error err
      else
        options.success JSON.parse res
    return

  findAll: (model, options)->
    @redis.HVALS @name, (err, res) =>
      if err
        options.error err
      else
        data = []
        for r in res
          data.push JSON.parse r
        options.success data
    return

  destroy: (model, options) ->
    @redis.HDEL @name, "#{model.id}", (err, res) ->
      if err
        options.error err
      else
        options.success model
    return

  ###
  This function injects our sync method into a different scope's Backbone
  ###
  @infect: (Backbone) ->
    _oldBackboneSync = Backbone.sync
    Backbone.sync = (method, model, options) ->
      # See if we have a redisStore to use. If so, use it. Otherwise do
      # normal backbone stuff.
      store = model.redisStorage || model.collection.redisStorage
      unless store
        return _oldBackboneSync.call @, method, model, options
      else
        fn = switch method
          when "read"
            if model.id
              store.find
            else
              store.findAll
          when "create"
            store.create
          when "update"
            store.update
          when "delete"
            store.destroy

        fn.call store, model, options
        return

module.exports = RedisStore

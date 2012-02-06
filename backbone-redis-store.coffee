###
backbone-redis-store - a simple backbone/redis bridge

Stores data inside hashes in Redis for fast lookup

Inspired by:
  https://github.com/jeromegn/Backbone.localStorage
###

_ = require 'underscore'
EventEmitter = require('events').EventEmitter

###
Takes the following options:
  * `key` - the key to be used for the hash in Redis
  * `redis` - the redis connection (using https://github.com/mranney/node_redis)
  * `unique` - an array of fields to uniquely index (they will be stringified and lowercased)
###
class RedisStore extends EventEmitter
  constructor: (options) ->
    @key = options.key
    @redis = options.redisClient
    @unique = options.unique || []
    @uniques = {}
    @uniques[uniqueKey] = {} for uniqueKey in @unique
    super

  ###
  Override this if you want to change the id generation

  Currently generates an auto-increment field stored under next.@key
  ###
  generateId: (cb) =>
    @redis.INCR "next|#{@key}", cb

  index: (model, reason) ->
    prev = model.previousAttributes()
    prev |= {}
    for uniqueKey in @unique
      if reason is 'delete'
        oldVal = "#{prev[uniqueKey]}".toLowerCase()
        delete @uniques[uniqueKey][oldVal]
        @redis.HDEL "#{@uniqueKey}:#{uniqueKey}", oldVal, (err,res) ->
          if err
            throw err
      else
        oldVal = null
        if prev[uniqueKey]
          oldVal = "#{prev[uniqueKey]}".toLowerCase()
        newVal = "#{model.attributes[uniqueKey]}".toLowerCase()
        if newVal isnt oldVal
          if oldVal isnt null
            delete @uniques[uniqueKey][oldVal]
            @redis.HDEL "#{@uniqueKey}:#{uniqueKey}", oldVal, (err,res) ->
              if err
                throw err
          @uniques[uniqueKey][newVal] = model
          @redis.HSET "#{@uniqueKey}:#{uniqueKey}", newVal, model.id, (err,res) ->
            if err
              throw err

  create: (model, options) ->
    next = =>
      @redis.HSETNX @key, model.id, JSON.stringify(model.toJSON()), (err, res) =>
        if err
          options.error err
        else
          @index model, 'create'
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
    @redis.HSET @key, "#{model.id}", JSON.stringify(model.toJSON()), (err, res) =>
      if err
        options.error err
      else
        @index model, 'update'
        options.success model
    return

  find: (model, options) ->
    @redis.HGET @key, "#{model.id}", (err, res) =>
      if err
        options.error err
      else
        options.success JSON.parse res
    return

  findAll: (model, options)->
    if options.searchUnique
      uniqueKey = options.searchUnique.key
      value = "#{options.searchUnique.value}".toLowerCase()
      @redis.HGET "#{@key}:#{uniqueKey}", value, (err, res) =>
        if err
          options.error err
        else if res is null
          options.success null
          #console.log "#{@key}:#{uniqueKey}, #{value} is #{res}"
        else
          @redis.HGET "#{@key}", "#{res}", (err, res) ->
            if err
              options.error err
            else
              options.success JSON.parse res
    else
      @redis.HVALS @key, (err, res) =>
        if err
          options.error err
        else
          data = []
          for r in res
            data.push JSON.parse r
          options.success data
    return

  destroy: (model, options) ->
    @redis.HDEL @key, "#{model.id}", (err, res) ->
      if err
        options.error err
      else
        @index model, 'delete'
        options.success model
    return

  ###
  This function injects our sync method into a different scope's Backbone
  ###
  @infect: (Backbone) ->
    _oldBackboneSync = Backbone.sync
    Backbone.Collection::getByUnique = (uniqueKey, value, options) ->
      store = @redisStorage
      if store.uniques[uniqueKey][value]
        options.success store.uniques[uniqueKey][value]
      else
        success = (collection, resp) ->
          #console.log "Response: #{resp.id}"
          #console.dir resp
          if options.success
            options.success (if resp then collection.get(resp.id) else null)
        error = (err) ->
          if options.error
            options.error err
        @fetch
          searchUnique:
            key: uniqueKey
            value: value
          add: true
          success: success
          error: error
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

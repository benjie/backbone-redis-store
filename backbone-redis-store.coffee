###
backbone-redis-store - a simple backbone/redis bridge

Stores data inside hashes in Redis for fast lookup

Inspired by:
  https://github.com/jeromegn/Backbone.localStorage
###

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
    @_byUnique = {}
    @_byUnique[uniqueKey] = {} for uniqueKey in @unique
    super

  ###
  Override this if you want to change the id generation

  Currently generates an auto-increment field stored under next|@key
  ###
  generateId: (cb) =>
    @redis.INCR "next|#{@key}", cb

  checkUnique: (model,reason,cb) =>
    # Check no other records already have these values.
    #
    # This check isn't 100% necessary (we could leave it to SETNX)
    # but it saves generating a new id if another record obviously
    # already exists.
    keys = []
    ks = []
    if @unique.length
      prev = model.previousAttributes()
      for key in @unique
        oldVal = ''
        unless reason is 'create'
          oldVal = "#{prev[key] or ''}".toLowerCase()
        newVal = "#{model.attributes[key]}".toLowerCase()
        if oldVal != newVal
          ks.push key
          keys.push "unique|#{@key}:#{key}|#{newVal}"

    if keys.length
      @redis.MGET keys, (err, res) ->
        for key,i in keys
          if res[i] isnt null
            cb
              errorCode: 409
              errorMessage: "Unique key conflict for key '#{ks[i]}'"
            return
        cb null
        return
    else
      cb null
    return

  clearOldUnique: (model, cb) =>
    keys = []
    if @unique.length
      prev = model.previousAttributes()
      for key in @unique
        oldVal = "#{prev[key]}".toLowerCase()
        newVal = "#{model.attributes[key]}".toLowerCase()
        if oldVal != newVal
          keys.push "unique|#{@key}:#{key}|#{oldVal}"
    if keys.length
      @redis.DEL keys, (err, res) ->
        if err
          cb
            errorCode: 500
            errorMessage: "Couldn't delete old keys?"
        else
          cb null
        return
    cb null
    return

  storeUnique: (model, reason, cb) =>
    # Because we're just using one redis connection, using WATCH in
    # many places could cause us to fail frequently under high load
    # due to watching a vast number of keys and only one needing to
    # change to invalidate the transaction.
    #
    # Instead we will use MSETNX which will only set the keys if they
    # don't already exist. An error from this implies that there is a
    # conflict.
    #
    # TODO: Check error type to confirm conflict.
    keys = []
    if @unique.length
      prev = model.previousAttributes()
      for key in @unique
        oldVal = ''
        unless reason is 'create'
          oldVal = "#{prev[key]}".toLowerCase()
        newVal = "#{model.attributes[key]}".toLowerCase()
        if oldVal != newVal
          keys.push "unique|#{@key}:#{key}|#{newVal}"
          keys.push model.id

    if keys.length
      @redis.MSETNX keys, (err,res) ->
        if err
          cb
            errorCode: 409
            errorMessage: "Unique key conflict"
        else
          cb null
        return
    else
      cb null
    return

  create: (model, options) ->
    storeModel = =>
      @redis.HSETNX @key, model.id, JSON.stringify(model.toJSON()), (err, res) =>
        if err
          options.error
            errorCode: 500
            errorMessage: "Couldn't save model even after reserving id."
        else
          options.success model
        return
      return
    storeUnique = =>
      @storeUnique model, 'create', (err, res) ->
        if err
          options.error err
        else
          storeModel()
    checkId = =>
      unless model.id
        @generateId (err, id) =>
          if err
            options.error
              errorCode: 500
              errorMessage: "Couldn't generate id for new record."
          else
            model.id = id
            model.set 'id', id
            storeUnique()
          return
      else
        storeUnique()
      return
    @checkUnique model, 'create', (err,res) ->
      if err
        options.error err
      else
        checkId()
    return

  update: (model, options) ->
    storeModel = =>
      @redis.HSET @key, "#{model.id}", JSON.stringify(model.toJSON()), (err, res) =>
        if err
          options.error err
        else
          options.success model
    storeUnique = =>
      @storeUnique model, 'update', (err, res) =>
        if err
          options.error err
        else
          storeModel()
          @clearOldUnique model, (err, res) ->
            #TODO: Log errors
    @checkUnique model, 'update', (err, res) ->
      if err
        options.error err
      else
        storeUnique()
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
      @redis.GET "unique|#{@key}:#{uniqueKey}|#{value}", (err, res) =>
        if err
          options.error err
        else if res is null
          options.success null
        else
          @redis.HGET "#{@key}", "#{res}", (err, res) ->
            if err
              options.error err
            else
              m = JSON.parse res
              if model.get m.id
                console.warn "SKIPPED record #{m.id} because it's already in the collection"
                options.success []
              else
                options.success [m]
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
        @clearOldUnique model, (err, res) ->
          #TODO: LOG errors
        options.success model
    return

  ###
  This function injects our sync method into a different scope's Backbone

  'infect' inspired by https://github.com/tpope/vim-pathogen
  ###
  @infect: (Backbone) ->
    _oldBackboneSync = Backbone.sync
    Backbone.Collection::getByUnique = (uniqueKey, value, options) ->
      store = @redisStore || @model::redisStore
      value = value.toLowerCase()
      resolveFromCache = ->
        if store._byUnique[uniqueKey][value]
          model = @get store._byUnique[uniqueKey][value]
          if model
            options.success model
          else
            console.error "Corrupted unique index - no model found for id '#{store._byUnique[uniqueKey][value]}'"
            options.error @, {errorCode: 500, errorMessage: "Corrupted unique index"}
          return true
        return false
      unless resolveFromCache()
        success = (collection, resp) ->
          if resp.length == 1
            if options.success
              options.success collection.get(resp[0].id)
          else
            unless resolveFromCache()
              if options.error
                options.error collection, {errorCode: 404, errorMessage: "Not found"}
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
      #
      # NOTE: model might actually be a collection
      store = model.redisStore || model.collection?.redisStore || model.model?.prototype.redisStore
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

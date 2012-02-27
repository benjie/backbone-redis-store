###
backbone-redis-store - a simple backbone/redis bridge

Stores data inside hashes in Redis for fast lookup

Inspired by:
  https://github.com/jeromegn/Backbone.localStorage
###

EventEmitter = require('events').EventEmitter
async = require('async')

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

  clearOldUnique: (model, del=false, cb) =>
    keys = []
    ks = []
    if @unique.length
      prev = model.previousAttributes()
      for key in @unique
        oldVal = "#{prev[key]}".toLowerCase()
        newVal = "#{model.attributes[key]}".toLowerCase()
        if oldVal != newVal or del
          keys.push "unique|#{@key}:#{key}|#{oldVal}"
          ks.push key
    if keys.length
      @redis.DEL keys, (err, res) =>
        if err
          console.error "backbone-redis-store: Failed to delete old unique keys"
          console.dir err
          cb
            errorCode: 500
            errorMessage: "Couldn't delete old keys?"
        else
          for key in ks
            delete @_byUnique[key]["#{prev[key]}".toLowerCase()]
          cb null
        return
    else
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
      @redis.MSETNX keys, (err,res) =>
        if err
          cb
            errorCode: 409
            errorMessage: "Unique key conflict"
        else
          for key in @unique
            @_byUnique[key]["#{model.attributes[key]}".toLowerCase()] = model.id
          cb null
        return
    else
      cb null
    return

  create: (model, options) ->
    storeModel = =>
      data = model.toJSON()
      sets = {}
      if model instanceof Backbone.RedisModel
        sets = data.sets
        delete data.sets
      @redis.HSETNX @key, model.id, JSON.stringify(data), (err, res) =>
        if err
          options.error
            errorCode: 500
            errorMessage: "Couldn't save model even after reserving id."
        else
          for k,v of sets
            vals = []
            for k2 of v
              vals.push k2
            if vals.length
              for val in vals # Support older redis stores, pre 2.4
                @redis.SADD "#{@key}|set:#{k}|#{model.id}", val, (err, res) ->
                  if err
                    console.error "ERROR: from redis:"
                    console.error err
              # TODO: Error handling, delay options.success, etc
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
      data = model.toJSON()
      sets = {}
      pSets = {}
      if model instanceof Backbone.RedisModel
        sets = data.sets
        pSets = model.previous('sets')
        delete data.sets
      @redis.HSET @key, "#{model.id}", JSON.stringify(data), (err, res) =>
        if err
          options.error err
        else
          for k,v of sets
            vals = []
            for k2 of v
              vals.push k2
            if vals.length
              for val in vals # Support older redis stores, pre 2.4
                @redis.SADD "#{@key}|set:#{k}|#{model.id}", val, (err, res) ->
                  console.error "ERROR: from redis:"
                  console.dir err
              # TODO: Error handling, delay options.success, etc
          for k,v of pSets
            if !sets[k]
              @redis.DEL "#{@key}|set:#{k}|#{model.id}"
              # TODO: Error handling, delay options.success, etc
            else
              vals = []
              for k2 of v
                if typeof sets[k][k2] is 'undefined'
                  vals.push k2
              if vals.length
                @redis.SREM "#{@key}|set:#{k}|#{model.id}", vals
                # TODO: Error handling, delay options.success, etc
          options.success model
    storeUnique = =>
      @storeUnique model, 'update', (err, res) =>
        if err
          options.error err
        else
          storeModel()
          @clearOldUnique model, false, (err, res) ->
            #TODO: Log errors
    @checkUnique model, 'update', (err, res) ->
      if err
        options.error err
      else
        storeUnique()
    return

  find: (model, options, multiId) ->
    id = if multiId? then multiId else model.id
    @redis.HGET @key, "#{id}", (err, res) =>
      if err
        options.error err
      else if multiId? and !res?
        console.error "ERROR: '#{id}' has no record!"
        options.success []
      else if !res
        console.error "ERROR: '#{id}' has no record(2)!"
        options.error {errorCode:404,errorMessage:"Not found"}
      else
        m = JSON.parse res
        for key in @unique
          @_byUnique[key]["#{m[key]}".toLowerCase()] = m.id
        if multiId? and model.get m.id
          console.warn "SKIPPED record #{m.id} because it's already in the collection"
          options.success []
        else
          sKeys = []
          modl = model
          if multiId?
            modl = model.model
          if modl instanceof Backbone.RedisModel
            for k of modl.sets
              sKeys.push k
          fetchSet = (k, cb) =>
            @redis.SMEMBERS "#{@key}|set:#{k}|#{m.id}", (err, res) ->
              if !err
                m.sets = {} unless m.sets
                m.sets[k] = {} unless m.sets[k]
                for v in res
                  m.sets[k][v] = true
                cb()
          async.forEach sKeys, fetchSet, ->
            if multiId?
              options.success [m]
            else
              options.success m
    return

  findAll: (model, options)->
    if options.searchUnique
      uniqueKey = options.searchUnique.key
      value = "#{options.searchUnique.value}".toLowerCase()
      @redis.GET "unique|#{@key}:#{uniqueKey}|#{value}", (err, res) =>
        if err
          options.error err
        else if res is null
          options.success []
        else
          @find model, options, res
    else
      if Object.keys(model.model.sets).length
        console.dir model
        console.trace()
        throw "ERROR: Don't support a full fetch of a model with sets"
      @redis.HVALS @key, (err, res) =>
        if err
          options.error err
        else
          data = []
          for r in res
            m = JSON.parse r
            for key in @unique
              @_byUnique[key]["#{m[key]}".toLowerCase()] = m.id
            data.push m
          options.success data
    return

  destroy: (model, options) ->
    @redis.HDEL @key, "#{model.id}", (err, res) =>
      if err
        options.error err
      else
        if model instanceof Backbone.RedisModel
          for k of model.sets
            @redis.DEL "#{@key}|set:#{k}|#{model.id}"
            # TODO: Error handling, delay options.success, etc
        @clearOldUnique model, true, (err, res) ->
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
      if uniqueKey is @model::idAttribute
        unless value?
          console.trace()
          console.error "id lookup requires an id to be set!"
          return
        model = @get value
        if model
          options.success model
          return
        else
          model = new @model {id: value}
          success = options.success
          options.success = (model) =>
            eModel = @get(model.id)
            if model and !eModel
              @add model
            else
              model = eModel
            if success
              success(model)
          model.fetch options
        return
      value = value.toLowerCase()
      resolveFromCache = =>
        if store._byUnique[uniqueKey][value]
          model = @get store._byUnique[uniqueKey][value]
          if model
            options.success model
          else
            console.trace()
            console.error "Corrupted unique index - no model found for id '#{store._byUnique[uniqueKey][value]}'"
            console.dir store
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

    class Backbone.RedisModel extends Backbone.Model
      sets: {}

      setAdd: (key, val) ->
        unless @sets[key]
          throw "ERROR: Set '#{key}' not defined"
        sets = @get('sets') || {}
        sets[key] = {} unless sets[key]?
        if typeof sets[key][val] is 'undefined'
          sets[key][val] = true
          @set 'sets', sets
          @trigger 'change', @, {}
          @trigger "change:set:#{key}", @, val, {}
          @save()

      setDelete: (key, val) ->
        unless @sets[key]
          throw "ERROR: Set '#{key}' not defined"
        sets = @get('sets') || {}
        sets[key] = {} unless sets[key]?
        if typeof sets[key][val] isnt 'undefined'
          delete sets[key][val]
          @set 'sets', sets
          @trigger 'change', @, {}
          @trigger "change:set:#{key}", @, val, {}
          @save()

      setContents: (key) ->
        unless @sets[key]
          throw "ERROR: Set '#{key}' not defined"
        res = []
        sets = @get('sets') || {}
        if sets[key]?
          for k of sets[key]
            res.push k
        return res

      setContains: (key, val) ->
        unless @sets[key]
          throw "ERROR: Set '#{key}' not defined"
        sets = @get('sets') || {}
        return sets? && sets[key]? && sets[key][val]?

module.exports = RedisStore

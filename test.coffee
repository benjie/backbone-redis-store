redisClient = require './redis_client'
Backbone = require 'backbone'
RedisStore = require './backbone-redis-store'
RedisStore.infect Backbone

class Test extends Backbone.Model
  username: null
  uniqueNumber: null

class TestCollection extends Backbone.Collection
  redisStorage: new RedisStore
    key: 'test'
    redisClient: redisClient
    unique: ['username','uniqueNumber']
  model: Test


randstr = (length) ->
  chars = "abcdef"
  out = ""
  for i in [0...length]
    out += chars.substr(Math.random()*chars.length,1)
  return out


testCollection = new TestCollection()
testCollection.getByUnique 'username', 'bob',
  success: (model) ->
    if model
      console.log "Got it: "
      console.dir model
    else
      console.log "Couldn't find model"
    fetchAll()
  error: (err) ->
    console.dir err
fetchAll = ->
  testCollection.fetch
    success: ->
      console.log "Loaded #{testCollection.length} records."

      res = testCollection.get 1
      if res
        console.log "Loaded record 1: "
        console.dir res.toJSON()
      else
        console.error "Record 1 not found."

      testCollection.create {"username":randstr(3),"uniqueNumber":testCollection.length+(parseInt(Math.random()*2))},
        success: (res) ->
          console.log "Created new record: "
          console.dir res.toJSON()
          oldUsername = res.attributes.username
          res.set('username', 'fred')
          res.save null,
            success: ->
              console.log "Set username to 'fred'"
              res.set('username', oldUsername)
              res.save null,
                success: ->
                  console.log "Reverted username"
                error: (model, err) ->
                  console.dir err
            error: (model, err) ->
              console.dir err

        error: (model,err) ->
          console.log "ERROR: "
          console.dir err
          throw err
    error: (e) ->
      console.error e
      process.exit 1


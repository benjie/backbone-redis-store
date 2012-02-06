redis = require 'redis'

connectToRedis = (options) ->
  options.db = 0 unless options.db

  _redisClient = redis.createClient options.port, options.host

  _redisClient.on "error", (err) ->
    console.error "Redis error: "
    console.dir err
    process.exit 1

  if options.pass
    _redisClient.auth options.pass, (err, res) ->
      console.log "Authenticated"

  _redisClient.select options.db, (err,res) ->
    if err
      console.log "ERROR "+err
    else
      console.log 'Redis database selected'
    if options.success
      options.success _redisClient
      options.success = null # Only call this once

  return _redisClient

redisClient = connectToRedis
  host:'127.0.0.1'
  port: 6379
  db: 3

module.exports = redisClient

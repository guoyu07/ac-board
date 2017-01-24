Opt = require 'optimist'
Dgram = require 'dgram'
Http = require 'http'
Cheerio = require 'cheerio'
OS = require 'os'
Fs = require 'fs'

argv = Opt
    .demand ['h']
    .alias 'p', 'port'
    .alias 'f', 'file'
    .alias 'h', 'host'
    .default 'p', 12000
    .default 'f', OS.tmpdir() + '/ac.json'
    .argv


try
    Fs.accessSync argv.f, Fs.R_OK
    data = JSON.parse Fs.readFileSync argv.f
catch e
    data =
        name: null
        passward: no
        status: no
        update: null
        online: 0
        maxOnline: 0
        track: null
        cars: []
        onlines: {}
        records: {}
        players: []
        laps: []


server = Dgram.createSocket 'udp4'
server.on 'error', console.log
queues = []

server.on 'message', (buff, rinfo) ->
    id = buff.readUInt8 0
    console.log "received #{id}"

    if id is 51 or id is 52
        # new connection
        len1 = buff.readUInt8 1
        driverName = buff.toString 2, 2 + len1, 'utf8'
        len2 = buff.readUInt8 2 + len1
        driverGUID = if len2 is 0 then null else buff.toString 2 + len1 + 1, 3 + len1 + len2, 'utf8'
        carId = buff.readUInt8 3 + len1 + len2
        len3 = buff.readUInt8 4 + len1 + len2
        carModel = buff.toString 4 + len1 + len2 + 1, 5 + len1 + len2 + len3, 'ascii'

        if id is 51
            data.onlines[carId] = [driverGUID, driverName, carModel]
        else
            delete data.onlines[carId] if data.onlines[carId]?
        
        queues.push yes
    if id is 73
        carId = buff.readUInt8 1
        lapTime = buff.readUInt32LE 2
        cuts = buff.readUInt8 6

        console.log "#{carId}@#{lapTime}:#{cuts}"
        queues.push [carId, lapTime, cuts]
    

requestServer = (type, cb) ->
    Http.get
        hostname: argv.h
        port: 8081
        path: '/' + type + '|' + Date.now()
        timeout: 5000
    , (res) ->
        if res.statusCode != 200
            data.status = no
            return

        content = ''

        res.on 'data', (chunk) -> content += chunk
        res.on 'end', -> cb content

    .on 'error', (e) ->
        data.status = no


updateLaps = (carId) ->
    return if not data.onlines[carId]?
    player = data.onlines[carId]
    found = no

    for p in data.laps
        if p[0] == player[0] and p[1] == player[1]
            found = yes

            p[3] += 1

            if p[2][data.track]?
                p[2][data.track] += 1
            else
                p[2][data.track] = 1

    if not found
        lap = [player[0], player[1], {}, 1]
        lap[2][data.track] = 1
        data.laps.push lap

    data.laps = data.laps.sort (a, b) -> b[3] - a[3]


updateRecords = (carId, lapTime) ->
    return if not data.onlines[carId]?
    player = data.onlines[carId]
    found = no

    if data.records[data.track]?
        for p in data.records[data.track]
            if p[0] == player[0] and p[1] == player[1] and p[2] == player[2]
                found = yes

                p[3] = lapTime if lapTime < p[3]

    if not found
        data.records[data.track] = [] if not data.records[data.track]?
        data.records[data.track].push [player[0], player[1], player[2], lapTime]

    records = data.records[data.track].sort (a, b) -> a[3] - b[3]
    data.records[data.track] = records.slice 0, 30


updateServerInfo = ->
    requestServer 'INFO', (content) ->
        struct = JSON.parse content

        data.name = struct.name
        data.passward = struct.pass
        data.online = struct.clients
        data.maxOnline = struct.maxclients
        data.track = struct.track
        data.cars = struct.cars
        data.status = yes

        queues.push yes


updateServerPlayers = ->
    requestServer 'ENTRY', (content) ->
        data.players = []
        data.onlines = {}

        $ = Cheerio.load content
        table = ($ 'table').first()
        $ 'tr', table
            .each (index) ->
                return if index is 0

                vals = []

                $ 'td', @
                    .each ->
                        vals.push ($ @).html()

                if vals[4] isnt 'DC'
                    data.players.push vals
                    
                    id = (parseInt vals[0]) - 1
                    guid = if vals[9].length > 0 then vals[9] else null
                    data.onlines[id] = [guid, vals[1], vals[2]]
        
        queues.push yes



count = 0

setInterval ->
    update = no

    if count is 100 or count is 0
        count = 0
        updateServerInfo()
        updateServerPlayers()

    while item = queues.shift()
        if item is yes
            update = yes
            continue

        [carId, lapTime, cuts] = item
        updateLaps carId
        updateRecords carId, lapTime if cuts <= 0
        update = yes

    if update
        Fs.writeFileSync argv.f, JSON.stringify data

    count += 1
, 100


server.bind argv.p
console.log argv.f


#!/usr/bin/env dub
/+ dub.sdl:
   dependency "vibe-d:core" version="~>0.9.0"
   dependency "vibe-d:data" version="~>0.9.0"
   dependency "vibe-d:http" version="~>0.9.0"
+/

import core.thread : Thread;
import core.time;

import std.algorithm : canFind, chunkBy, each, filter, map, splitter;
import std.array : array, split;
import std.conv : to;
import std.format : format;
import std.process : executeShell;
import std.stdio;
import std.string : isNumeric, toLower;

import vibe.data.json;
import vibe.http.client;

import vibe.stream.operations;

static immutable MOD = "increasedrarityofitemsfound";
static immutable IDS = [1, 2, 5, 6];
static immutable LEAGUE = "Standard";
static immutable ONLINE_ONLY = true;
static immutable DELAY = 20.seconds;

struct Jewel
{
    string name;
    string description;

    int modValue;
    string modName;

    int[string][int] sockets;

    bool compareMod(in Jewel other) const
    {
        return modName == other.modName && modValue == other.modValue;
    }

    void joinSockets(in Jewel other)
    {
        assert(compareMod(other));
        foreach (key, value; other.sockets)
            sockets[key] = cast(int[string]) value;
    }

    Json toFilter() const
    {
        Json filter = Json.emptyObject;
        filter["id"] = "explicit.pseudo_timeless_jewel_" ~ modName;
        filter["value"] = Json(["min": Json(modValue), "max": Json(modValue)]);
        filter["disabled"] = false;
        return filter;
    }

    string toString() const
    {
        return format!("(%d, %s)")(modValue, modName);
    }

    int totalModValue(string mod, int id)
    {
        int total = 0;
        if (id in sockets && mod in sockets[id])
            total = sockets[id][mod];
        return total;
    }
}

string getApiUrl()
{
    return "https://www.pathofexile.com/api/trade/search/" ~ LEAGUE;
}

string getUrl(string id)
{
    return "https://www.pathofexile.com/trade/search/" ~ LEAGUE ~ "/" ~ id;
}

void main()
{
    // Each jewel has the passives for 1 socket
    Jewel[] input;
    foreach (line; executeShell("unzip -p database.zip").output.splitter("\n").filter!(a => a != ""))
    {
        Json json = parseJsonString(line);
        Jewel jewel;
        jewel.name = json["name"].get!string;
        jewel.description = json["description"].get!string;

        // Example: "Commissioned 99520 coins to commemorate Chitus"
        jewel.modName = json["description"].get!string.split[$ - 1].toLower;
        jewel.modValue = json["description"].get!string
            .split
            .filter!isNumeric
            .front
            .to!int;

        int id = json["socket_id"]["$numberInt"].to!int;
        foreach (key, value; json["summed_mods"].byKeyValue())
            jewel.sockets[id][key] = json["summed_mods"][key]["$numberInt"].to!int;

        input ~= jewel;
    }

    // Join each jewel's sockets together
    Jewel[] jewels;
    foreach (chunk; input.chunkBy!((a, b) => a.compareMod(b)))
    {
        foreach (Jewel jewel; chunk.array[1 .. $])
            chunk.front.joinSockets(jewel);
        jewels ~= chunk.front;
    }
    input = null;

    // Apply filters
    jewels = jewels.filter!((j) {
        foreach (id, mods; j.sockets)
            if (IDS.canFind(id) && MOD in mods)
                return true;
        return false;
    }).array;

    /*
    writeln("Jewels matching filters:");
    jewels.each!writeln;
    writeln;
    */

    writefln("Searching %d jewels on pathofexile.com/trade with a delay of %s inbetween...",
            jewels.length, DELAY);

    foreach (Jewel jewel; jewels)
    {
        requestHTTP(getApiUrl(), (scope req) {
            req.method = HTTPMethod.POST;
            Json body = parseJsonString(`{"query": {"stats":[{"type":"count","value":{"min":1},"filters":[]}]}}`);
            static if (ONLINE_ONLY)
            {
                body["query"]["status"] = Json.emptyObject;
                body["query"]["status"]["option"] = "online";
            }
            body["query"]["stats"][0]["filters"] ~= jewel.toFilter();
            req.writeJsonBody(body);
        }, (scope res) {
            Json json;
            try
                json = res.readJson();
            catch (Exception e)
            {
                stderr.writeln("Error parsing response (Cloudflare error?)");
                return;
            }
            if (json["error"].type() != Json.Type.undefined)
            {
                stderr.writefln("Server returned an error: \"%s\"", json["error"]["message"].get!string);
                return;
            }

            const int total = json["total"].get!int;
            if (total > 0)
            {
                string url = getUrl(json["id"].get!string);
                writefln("Jewel %s has %d trade listing(s):", jewel, total);
                writefln("  - Name: %s", jewel.name);
                writefln("  - Mod: %s", jewel.description);
                writefln("  - Link: %s", url);
                foreach (id; IDS)
                {
                    writefln("  - Socket %d:", id);
                    writefln("      - Total \"%s\": %d", MOD, jewel.totalModValue(MOD, id));
                }
            }
        });
        Thread.sleep(DELAY);
    }
}

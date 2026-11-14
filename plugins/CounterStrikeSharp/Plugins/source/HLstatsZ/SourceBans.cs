using MySqlConnector;
using System.Globalization;
using CounterStrikeSharp.API;
using CounterStrikeSharp.API.Core;
using CounterStrikeSharp.API.Modules.Utils;
using Microsoft.Extensions.Logging;
using CounterStrikeSharp.API.Modules.Commands;
using CounterStrikeSharp.API.Modules.Timers;
using CounterStrikeSharp.API.Modules.Cvars;
using CounterStrikeSharp.API.Core.Translations;
using GameTimer = CounterStrikeSharp.API.Modules.Timers.Timer;
using CounterStrikeSharp.API.ValveConstants.Protobuf;
using CounterStrikeSharp.API.Modules.Entities.Constants;
using System;
using System.Text.RegularExpressions;
using System.Text;
using System.Collections.Concurrent;

namespace HLstatsZ;

public enum TeamNum : byte
{
    Unassigned       = 0,
    Spectator        = 1,
    Terrorist        = 2,
    CounterTerrorist = 3
}

public enum BanType
{
    None    = 0,
    Mute    = 1,
    Gag     = 2,
    Silence = Mute | Gag,
    Kick    = 4,
    Ban     = 8,
    Banip   = 16,
    Slay    = 32,
}

public enum AdminFlags
{
    None     = 0,
    Generic  = 1 << 0,  // b
    Kick     = 1 << 1,  // c
    Ban      = 1 << 2,  // d
    Unban    = 1 << 3,  // e
    Slay     = 1 << 4,  // f
    Map      = 1 << 5,  // g
    Config   = 1 << 6,  // i
    Cheats   = 1 << 7,  // n
    BanIp    = 1 << 8,  // o
    BanPerm  = 1 << 9,  // p
    UnbanAny = 1 << 10,  // q
    Root     = 1 << 11, // z
}

public static class AdminFlagExtensions
{
    private static readonly Dictionary<char, AdminFlags> _map = new()
    {
        ['b'] = AdminFlags.Generic,
        ['c'] = AdminFlags.Kick,
        ['d'] = AdminFlags.Ban,
        ['e'] = AdminFlags.Unban,
        ['f'] = AdminFlags.Slay,
        ['g'] = AdminFlags.Map,
        ['i'] = AdminFlags.Config, // !refresh
        ['n'] = AdminFlags.Cheats, // !give
        ['o'] = AdminFlags.BanIp,
        ['p'] = AdminFlags.BanPerm,
        ['q'] = AdminFlags.UnbanAny,
        ['z'] = AdminFlags.Root,
    };

    public static AdminFlags ToFlags(this string? flagStr)
    {
        if (string.IsNullOrEmpty(flagStr))
            return AdminFlags.None;

        AdminFlags result = AdminFlags.None;
        foreach (char c in flagStr)
        {
            if (_map.TryGetValue(c, out var flag))
                result |= flag;
        }
        return result;
    }

    public static bool Has(this AdminFlags flags, AdminFlags check)
        => (flags & check) != 0;
}

public class SourceBans
{
    private static string? _cachedDBH;
    private static string? _prefix;
    public static bool _enabled = false;
    public static GameTimer? _cleanupTimer;
    public static GameTimer? _voteTimer;
    public static GameTimer? _DelayedCommand;
    private static ILogger? _logger;
    private static string? DBH => _cachedDBH;
    public static readonly ConcurrentDictionary<ulong, (string PlayerName, bool IsAdmin, int Aid, string? IP, string? Flags, DateTime Updated,
                                              BanType Ban, DateTime ExpiryBan, DateTime ExpiryMute, DateTime ExpiryGag,
                                              int DurationBan, int DurationMute, int DurationGag,
                                              int CountBan, int CountMute, int CountGag, int CountSlay,
                                              int aBan, int aMute, int aGag, int Bid, int Immunity, bool Connected )> _userCache = new();
    private static readonly Regex Ipv4WithPort = new(@"^(?<ip>\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?$", RegexOptions.Compiled);
    private static readonly Regex DecodeVar    = new(@"\{([A-Za-z0-9_\.]+)(?::([^}]+))?\}", RegexOptions.Compiled);

    public static Dictionary<string, (DateTime Created, CCSPlayerController? target, string? Name, string? MapName, int YES, int NO, int Need)> _vote = new();
    public static List<MapEntry> _rtv = new();
    public static Dictionary<string, Dictionary<ulong, int>> _userVote = new();
    public static Dictionary<ulong, string> _userNominate = new();
    private static readonly List<AvertissementState> _avertStates = new();
    public static string serverAddr = "";
    public static string hostName = "";
    public static int serverID = 0;
    public static string VoteKick = "";
    public static string VoteMap = "";
    public static bool Nominate = false;
    public static string NextMap = "";
    public static int[] Durations = new int[6];
    public static bool _canVote = false;
    public static int _mVote = 0;
    public static float KickDelay = 5.0f;

    public static void Init(HLstatsZMainConfig cfg, ILogger logger)
    {
        _logger = logger;

        var sb = cfg.SourceBans;
        VoteKick = sb.VoteKick ?? "private";
        VoteMap = cfg.Maps.VoteMap ?? "private";
        Nominate = cfg.Maps.Nominate;

        if (string.IsNullOrWhiteSpace(sb.Database) || string.IsNullOrWhiteSpace(sb.Host) ||
            string.IsNullOrWhiteSpace(sb.User) || string.IsNullOrWhiteSpace(sb.Prefix) || !cfg.Enable_Sourcebans)
        {
            _enabled = false;
            if (cfg.Enable_Sourcebans)
                _logger?.LogInformation("[HLstatsZ] SourceBans disabled: missing config (host/db/user/prefix).");
            return;
        }
        var builder = new MySqlConnectionStringBuilder
        {
            Server = sb.Host,
            Port = (uint)sb.Port,
            Database = sb.Database,
            UserID = sb.User,
            Password = sb.Password,
            Pooling = true,
            ConnectionReset = true,
            SslMode = Enum.TryParse<MySqlSslMode>(sb.SslMode, true, out var mode) ? mode : MySqlSslMode.None,
            DefaultCommandTimeout = 5
        };
        _cachedDBH = builder.ConnectionString;

        _prefix = sb.Prefix;
        _enabled = true;

    }

    private class AvertissementState
    {
        public string Message = "";
        public string PrintType = "";
        public int EveryMinutes;
        public DateTime NextTime;
    }

    public static void InitAvertissements(HLstatsZMainConfig config)
    {
        _avertStates.Clear();

        var now = DateTime.UtcNow;
        int index = 0;

        foreach (var ads in config.Avertissements ?? Enumerable.Empty<AvertissementEntry>())
        {
            if (string.IsNullOrWhiteSpace(ads.Message)) continue;
            if (ads.EveryMinutes <= 0) continue;

            var offsetMinutes = index;

            _avertStates.Add(new AvertissementState
            {
                Message      = " "+ads.Message,
                PrintType    = ads.PrintType,
                EveryMinutes = ads.EveryMinutes,
                NextTime     = now.AddMinutes(offsetMinutes)
            });

            index++;
        }
    }

    public static string DecodeAd(string message, CCSPlayerController player)
    {
        return DecodeVar.Replace(message, match =>
        {
            string key = match.Groups[1].Value;
            string? arg = match.Groups[2].Success ? match.Groups[2].Value : null;

            // --- PLAYER NAME ---
            if (key.Equals("name", StringComparison.OrdinalIgnoreCase))
            {
                return player.PlayerName ?? "";
            }

            // --- PLAYER COUNT ---
            if (key.Equals("players", StringComparison.OrdinalIgnoreCase))
            {
                return HLstatsZ.GetPlayersList().Count().ToString();
            }

            // --- Hostname ---
            if (key.Equals("hostname", StringComparison.OrdinalIgnoreCase))
            {
                return !string.IsNullOrEmpty(SourceBans.hostName)? SourceBans.hostName :
                        ConVar<string>.Find("hostname")?.ValueAsString ?? "Counter-Strike 2";
            }

            // --- Map ---
            if (key.Equals("map", StringComparison.OrdinalIgnoreCase))
            {
                return Server.MapName ?? "";
            }

            // --- Address ---
            if (key.Equals("address", StringComparison.OrdinalIgnoreCase))
            {
                return SourceBans.serverAddr ?? "";
            }

            // --- DATE ---
            if (key.Equals("date", StringComparison.OrdinalIgnoreCase))
            {
                return arg != null
                    ? DateTime.Now.ToString(arg)
                    : DateTime.Now.ToShortDateString();
            }

            // --- TIME ---
            if (key.Equals("time", StringComparison.OrdinalIgnoreCase))
            {
                return arg != null
                    ? DateTime.Now.ToString(arg)
                    : DateTime.Now.ToShortTimeString();
            }

            return match.Value;
        });
    }

    private static void ShowAds(DateTime now)
    {
        if (_avertStates.Count == 0) return;

        var ads = _avertStates
            .Where(a => a.NextTime <= now)
            .OrderBy(a => a.NextTime)
            .FirstOrDefault();

        if (ads == null)
            return;

        if (ads.PrintType == "html") {
            HLstatsZ.SendHTMLToAll(HLstatsZ.CenterColors(ads.Message),true);
        } else {
            var players = HLstatsZ.GetPlayersList();
            string[] lines = ads.Message.Split(';');
            foreach (var player in players)
            {
                foreach (string line in lines)
                {
                    string message = DecodeAd(line, player);
                    player.PrintToChat(HLstatsZ.Colors(message));
                }
            }
        }
        ads.NextTime = now.AddMinutes(ads.EveryMinutes);
    }

    public static void Rename(CCSPlayerController player, string newName)
    {
        if (player == null || !player.IsValid || string.IsNullOrEmpty(newName))
            return;

        player.PlayerName = newName;
        Utilities.SetStateChanged(player, "CBasePlayerController", "m_iszPlayerName");
       UpdateBanUser(player.SteamID, BanType.None, 0, false, 0, true, null, newName);
    }

    public static async Task<bool> isAdmin(CCSPlayerController? player, bool refresh = false)
    {
        if (player == null || !player.IsValid) return false;

        ulong sid64 = player.SteamID;
        if (sid64 == 0) return false;

        DateTime now = DateTime.UtcNow;

        if (_enabled && !refresh && _userCache.TryGetValue(sid64, out var cached))
            return cached.IsAdmin;

        // Locals
        string playerName = player.PlayerName;
        string? ipAddr    = GetClientIp(player);

        string steam2_v0 = ToSteam2(sid64);
        string steam2_v1 = steam2_v0.Replace("STEAM_0:", "STEAM_1:");
        string sid64Str  = sid64.ToString();

        string adminsTable = $"`{_prefix}_admins`";
        string groupsTable = $"`{_prefix}_srvgroups`";

        bool   isAdmin      = false;
        int    aid          = 0;
        int    immunity     = 0;
        int    aBan         = 0;
        int    aMute        = 0;
        int    aGag         = 0;
        string? flags       = null;
        BanType hasBan      = BanType.None;
        DateTime endBan     = now;
        DateTime endMute    = now;
        DateTime endGag     = now;
        int durationBan     = 0, durationMute = 0, durationGag = 0;
        int countBan        = 0, countMute = 0, countGag = 0, countSlay = 0;
        int bid             = 0;

        // HLstats only
        if (!_enabled)
        {
            _userCache[sid64] = (playerName, false, 0, ipAddr, null, DateTime.UtcNow,
                                 BanType.None, now, now, now,
                                 0, 0, 0,
                                 0, 0, 0, 0,
                                 0, 0, 0, 0, 0, true);
            return false;
        }

        try
        {
            using var dbh = new MySqlConnection(DBH);
            await dbh.OpenAsync().ConfigureAwait(false);

            // === 1. BAN CHECK ===
            using (var banCmd = new MySqlCommand($@"
                SELECT ends, length, RemovedOn, type, aid, bid
                FROM `{_prefix}_bans`
                WHERE (authid IN (@s0, @s1, @s64) OR (type = 1 AND @ip IS NOT NULL AND ip = @ip))
                  AND  (RemovedOn IS NULL OR RemovedOn = 0)
                  AND (length <= 0 OR created = ends OR ends > UNIX_TIMESTAMP())
                ORDER BY ends DESC
                LIMIT 1;", dbh))
            {
                banCmd.Parameters.AddWithValue("@s0",  steam2_v0);
                banCmd.Parameters.AddWithValue("@s1",  steam2_v1);
                banCmd.Parameters.AddWithValue("@s64", sid64Str);
                banCmd.Parameters.AddWithValue("@ip",  (object?)ipAddr ?? DBNull.Value);

                using var banReader = await banCmd.ExecuteReaderAsync().ConfigureAwait(false);
                while (await banReader.ReadAsync().ConfigureAwait(false))
                {
                    aBan             = banReader.GetInt32("aid");
                    bid              = banReader.GetInt32("bid");
                    int type         = banReader.GetByte("type");
                    int endsUnix     = banReader.IsDBNull(banReader.GetOrdinal("ends"))   ? 0 : banReader.GetInt32("ends");
                    int len          = banReader.IsDBNull(banReader.GetOrdinal("length")) ? 0 : banReader.GetInt32("length");

                    durationBan      = len;
                    endBan           = ComputeEnd(endsUnix, len);

                    var banType      = (type == 1) ? BanType.Banip : BanType.Ban;
                    hasBan          |= banType;
                    countBan++;
                }
            }

            // A vote kick only lives in this cache: a fresh check keeps it until it runs out
            if (_userCache.TryGetValue(sid64, out var previous) && (previous.Ban & BanType.Kick) != 0 && previous.ExpiryBan > now)
            {
                hasBan |= BanType.Kick;
                if (previous.ExpiryBan > endBan)
                    endBan = previous.ExpiryBan;
            }

            _userCache[sid64] = (playerName, isAdmin, aid, ipAddr, flags, DateTime.UtcNow,
                                 hasBan, endBan, endMute, endGag,
                                 durationBan, durationMute, durationGag,
                                 countBan, countMute, countGag, countSlay,
                                 aBan, aMute, aGag, bid, immunity, true);

            Server.NextFrame(() =>
            {
                
                if (player != null && player.IsValid && !player.IsBot)
                    Validator(player, steamId: sid64, earlyStage: true);
                else
                    Validator(null,   steamId: sid64, earlyStage: true);
            });

            // === Banlog (blocked (x)) ===
            if (bid > 0) return false;

            // === 2. COMMS CHECK ===
            using (var commsCmd = new MySqlCommand($@"
                SELECT ends, length, RemovedOn, type, aid
                FROM `{_prefix}_comms`
                WHERE authid IN (@s0, @s1, @s64)
                  AND type IN (1, 2)
                  AND (RemovedOn IS NULL OR RemovedOn = 0)
                  AND (length <= 0 OR created = ends OR ends > UNIX_TIMESTAMP())
                ORDER BY ends DESC;", dbh))
            {
                commsCmd.Parameters.AddWithValue("@s0", steam2_v0);
                commsCmd.Parameters.AddWithValue("@s1", steam2_v1);
                commsCmd.Parameters.AddWithValue("@s64", sid64Str);

                using var commReader = await commsCmd.ExecuteReaderAsync().ConfigureAwait(false);
                while (await commReader.ReadAsync().ConfigureAwait(false))
                {
                    int type     = commReader.GetByte("type"); // 1=mute, 2=gag
                    int endsUnix = commReader.IsDBNull(commReader.GetOrdinal("ends")) ? 0 : commReader.GetInt32("ends");
                    int len      = commReader.IsDBNull(commReader.GetOrdinal("length")) ? 0 : commReader.GetInt32("length");

                    if (type == 1)
                    {
                        durationMute = len;
                        endMute      = ComputeEnd(endsUnix, len);
                        aMute        = commReader.GetInt32("aid");
                        hasBan      |= BanType.Mute;
                        countMute++;
                    }
                    else
                    {
                        durationGag = len;
                        endGag      = ComputeEnd(endsUnix, len);
                        aGag        = commReader.GetInt32("aid");
                        hasBan     |= BanType.Gag;
                        countGag++;
                    }
                }
            }

            _userCache[sid64] = (playerName, isAdmin, aid, ipAddr, flags, DateTime.UtcNow,
                                 hasBan, endBan, endMute, endGag,
                                 durationBan, durationMute, durationGag,
                                 countBan, countMute, countGag, countSlay,
                                 aBan, aMute, aGag, bid, immunity, true);

            if (countBan == 0 && (countMute + countGag) > 0)
            {
                Server.NextFrame(() =>
                {
                    if (player != null && player.IsValid && !player.IsBot)
                        Validator(player, steamId: sid64, earlyStage: true);
                    else
                        Validator(null,   steamId: sid64, earlyStage: true);
                });
            }

            // === 3. ADMIN CHECK ===
            using (var adminCmd = new MySqlCommand($@"
                SELECT a.aid, a.immunity, a.srv_group, CONCAT_WS('', TRIM(a.srv_flags), g.flags) AS all_flags
                FROM {adminsTable} AS a
                LEFT JOIN {groupsTable} AS g ON g.name = a.srv_group
                WHERE a.authid IN (@s0, @s1, @s64)
                ORDER BY FIELD(a.authid, @s0, @s1, @s64)
                LIMIT 1;", dbh))
            {
                adminCmd.Parameters.AddWithValue("@s0",  steam2_v0);
                adminCmd.Parameters.AddWithValue("@s1",  steam2_v1);
                adminCmd.Parameters.AddWithValue("@s64", sid64Str);

                using var reader = await adminCmd.ExecuteReaderAsync().ConfigureAwait(false);
                while (await reader.ReadAsync().ConfigureAwait(false))
                {
                    aid      = reader.GetInt32("aid");
                    immunity = reader.GetInt32("immunity");
                    flags    = reader.IsDBNull(reader.GetOrdinal("all_flags")) ? null : reader.GetString("all_flags");
                    isAdmin  = aid > 0 && !(flags is null) && flags.AsSpan().IndexOfAny('b','z') >= 0;
                }
            }

            _userCache[sid64] = (playerName, isAdmin, aid, ipAddr, flags, DateTime.UtcNow,
                                 hasBan, endBan, endMute, endGag,
                                 durationBan, durationMute, durationGag,
                                 countBan, countMute, countGag, countSlay,
                                 aBan, aMute, aGag, bid, immunity, true);

            if (isAdmin)
            {
                Server.NextFrame(() =>
                {
                    if (player != null && player.IsValid && !player.IsBot)
                        Validator(player, steamId: sid64, earlyStage: true);
                    else
                        Validator(null,   steamId: sid64, earlyStage: true);
                });
            }

        } catch (Exception ex) {
            _logger?.LogError(ex, "[HLstatsZ] SourceBans checks failed for {Sid64}", sid64);
        }

        return isAdmin;
    }

    static DateTime ComputeEnd(int endsUnix, int lengthSeconds)
    {
        if (lengthSeconds <= 0) return DateTime.MaxValue; // permanent
        if (endsUnix <= 0)      return DateTime.UtcNow;   // clamp
        var endsUtc = DateTimeOffset.FromUnixTimeSeconds(endsUnix).UtcDateTime;
        return endsUtc > DateTime.UtcNow ? endsUtc : DateTime.UtcNow;
    }

    public static async Task PlayerCheck(CCSPlayerController player)
    {
        await isAdmin(player);

        Server.NextFrame(() =>
        {
            if (player != null && player.IsValid)
            {
                if (_userCache.TryGetValue(player.SteamID, out var cached))
                {
                    Validator(player);
                    UpdateBanUser(player.SteamID, BanType.None, 0, false, 0, true);
                } else {
                    _logger?.LogError("[HLstatsZ] SourceBans admin check failed for {PlayerName} {SteamID}", player.PlayerName, player.SteamID);
                }
            }
        });
    }

    public class MapEntry
    {
        public string DisplayName { get; set; } = "";
        public string MapName { get; set; } = "";
        public string? WorkshopId { get; set; } = null;
        public bool IsSteamWorkshop => WorkshopId != null;
    }

    public static List<MapEntry> GetAvailableMaps(HLstatsZMainConfig config, bool isAdmin)
    {
        var results = new List<MapEntry>();

        MapEntry ParseMap(string raw)
        {
            const string prefix = "workshop/";
            if (raw.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                var rest = raw.Substring(prefix.Length);
                var parts = rest.Split('/', StringSplitOptions.RemoveEmptyEntries);

                var workshopId = parts.Length > 0 ? parts[0] : "";
                var mapName    = parts.Length > 1 ? parts[1] : workshopId;

                return new MapEntry
                {
                    DisplayName = mapName,
                    MapName = mapName,
                    WorkshopId = workshopId
                };
            }
            else
            {
                return new MapEntry
                {
                    DisplayName = raw,
                    MapName = raw
                };
            }
        }

        // Public maps
        results.AddRange(config.Maps.MapCycle.Public.Maps.Select(ParseMap));

        if (isAdmin)
        {
            // Admin maps
            results.AddRange(config.Maps.MapCycle.Admin.Maps.Select(ParseMap));
        }

        return results
            .GroupBy(e => e.DisplayName.ToLowerInvariant())
            .Select(g => g.First())
            .ToList();
    }

    public static async Task<bool> WriteBan(ulong sid64, string PlayerName, int aid, string adminIp, BanType type, int durationSeconds, string reason)
    {

        if (!_userCache.TryGetValue(sid64, out var targetData))
        {
            _logger?.LogWarning("[HLstatsZ] WriteBan: target not found in cache");
            return false;
        }

        string authid   = ToSteam2(sid64);
        string name     = PlayerName;
        int created     = (int)DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        int ends        = durationSeconds == 0 ? created : created + durationSeconds;
        string targetIp = targetData.IP ?? "";
        string ureason  = "";
        string table    = "";
        string sql      = "";
        bool updated = false;
        string checkTable = ((type & (BanType.Ban | BanType.Banip)) != 0) ? $"{_prefix}_bans" : $"{_prefix}_comms";
        int banType = type == BanType.Mute ? 1 : type == BanType.Gag ? 2 : type == BanType.Banip ? 1 : 0;

        string updateSql = $@"
            UPDATE `{checkTable}`
            SET ends = @ends,
                length = @length,
                reason = @reason,
                RemovedOn = 0,
                ureason = '',
                aid = @aid,
                adminIp = @adminip,
                sid = @sid
            WHERE authid = @authid
              AND type = @type
              AND (RemovedOn IS NULL OR RemovedOn = 0)
              AND (length <= 0 OR created = ends OR ends > UNIX_TIMESTAMP())
            ORDER BY ends DESC
            LIMIT 1;";

        await using var dbh = new MySqlConnection(DBH);
        await dbh.OpenAsync();

        using var updateCmd = new MySqlCommand(updateSql, dbh);
        updateCmd.Parameters.AddWithValue("@authid", authid);
        updateCmd.Parameters.AddWithValue("@ends", ends);
        updateCmd.Parameters.AddWithValue("@length", durationSeconds);
        updateCmd.Parameters.AddWithValue("@reason", reason ?? "");
        updateCmd.Parameters.AddWithValue("@aid", aid);
        updateCmd.Parameters.AddWithValue("@adminip", adminIp);
        updateCmd.Parameters.AddWithValue("@sid", serverID);
        updateCmd.Parameters.AddWithValue("@type", banType);

        try
        {
            int rows = await updateCmd.ExecuteNonQueryAsync();
            updated = rows > 0;
        }
        catch (Exception ex)
        {
            _logger?.LogError(ex, "[HLstatsZ] WriteBan update failed for {Target}", PlayerName);
        }
        if (updated)
        {
            Server.NextFrame(() =>
            {
                SourceBans.UpdateBanUser(sid64, type, durationSeconds > 0 ? durationSeconds : int.MaxValue, false, aid);
            });
            return true;
        }

        if ((type & (BanType.Ban | BanType.Banip)) != 0)
        {
             table = $"`{_prefix}_bans`";
             sql = $@"
                 INSERT INTO {table}
                     (ip,authid, name, created, ends, length, reason, aid, adminIp, sid, RemovedOn, ureason, type)
                 VALUES
                     (@ip,@authid, @name, @created, @ends, @length, @reason, @aid, @adminip, @sid, @removedon, @ureason, @type)";
        } else {
             table = $"`{_prefix}_comms`";
             sql = $@"
                 INSERT INTO {table}
                     (authid, name, created, ends, length, reason, aid, adminIp, sid, RemovedOn, ureason, type)
                 VALUES
                     (@authid, @name, @created, @ends, @length, @reason, @aid, @adminip, @sid, @removedon, @ureason, @type)";
        }
        using var cmd = new MySqlCommand(sql, dbh);

        if ((type & (BanType.Ban | BanType.Banip)) != 0)
            cmd.Parameters.AddWithValue("@ip", targetIp);
        cmd.Parameters.AddWithValue("@authid", authid);
        cmd.Parameters.AddWithValue("@name", name);
        cmd.Parameters.AddWithValue("@created", created);
        cmd.Parameters.AddWithValue("@ends", ends);
        cmd.Parameters.AddWithValue("@length", durationSeconds);
        cmd.Parameters.AddWithValue("@reason", reason ?? "");
        cmd.Parameters.AddWithValue("@aid", aid);
        cmd.Parameters.AddWithValue("@adminip", adminIp);
        cmd.Parameters.AddWithValue("@sid", serverID);
        cmd.Parameters.AddWithValue("@removedon", 0);
        cmd.Parameters.AddWithValue("@ureason", ureason);
        cmd.Parameters.AddWithValue("@type", banType);

        try
        {
            await cmd.ExecuteNonQueryAsync();
            int newBid = (int)cmd.LastInsertedId;
            Server.NextFrame(() =>
           {
                SourceBans.UpdateBanUser(sid64, type, durationSeconds > 0 ? durationSeconds : int.MaxValue, false, aid, null, newBid);
           });
            return true;
        }
        catch (Exception ex)
        {
            _logger?.LogError(ex, "[HLstatsZ] WriteBan exception for {Target}", PlayerName);
            return false;
        }
    }

    public static async Task UpdateBlocked(ulong sid64, int bid = 0)
    {
        if (sid64 == 0) return;

        string playerName = "Unknown";
        string? ipAddr = null;

        if (_userCache.TryGetValue(sid64, out var data))
        {
            playerName = data.PlayerName;
            ipAddr     = data.IP;
        }

        // Locals
        string steam2_v0  = ToSteam2(sid64);
        string steam2_v1  = steam2_v0.Replace("STEAM_0:", "STEAM_1:");
        string sid64Str   = sid64.ToString();

        await using var dbh = new MySqlConnection(DBH);
        await dbh.OpenAsync();

        try
        {
            if (bid == 0 )
            {
                using (var banCmd = new MySqlCommand($@"
                    SELECT bid
                    FROM `{_prefix}_bans`
                    WHERE (authid IN (@s0, @s1, @s64) OR (type = 1 AND @ip IS NOT NULL AND ip = @ip))
                      AND RemovedOn = 0
                      AND (length <= 0 OR created = ends OR ends > UNIX_TIMESTAMP())
                    ORDER BY ends DESC
                    LIMIT 1;", dbh))
                {
                    banCmd.Parameters.AddWithValue("@s0",  steam2_v0);
                    banCmd.Parameters.AddWithValue("@s1",  steam2_v1);
                    banCmd.Parameters.AddWithValue("@s64", sid64Str);
                    banCmd.Parameters.AddWithValue("@ip",  (object?)ipAddr ?? DBNull.Value);

                    using var banReader = await banCmd.ExecuteReaderAsync();
                    while (await banReader.ReadAsync())
                    {
                        bid = banReader.GetInt32("bid");
                    }
                }
            }

            if (bid > 0)
            {
                string sql = $@"INSERT IGNORE INTO `{_prefix}_banlog` (`sid`,`time`, `name`, `bid`)
                                VALUES (@sid,@time, @name, @bid)";
                using var cmdLog = new MySqlCommand(sql, dbh);
                cmdLog.Parameters.AddWithValue("@sid",  serverID);
                cmdLog.Parameters.AddWithValue("@time", (int)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                cmdLog.Parameters.AddWithValue("@name", playerName);
                cmdLog.Parameters.AddWithValue("@bid",  bid);
                await cmdLog.ExecuteNonQueryAsync();
            }
        }
        catch (Exception ex)
        {
            _logger?.LogError(ex, "[HLstatsZ] UpdateBlocked {targetName} failed", playerName);
            return;
        }
    }

    public static async Task<bool> WriteUnBan(ulong targetSteamID, CCSPlayerController? admin, BanType typeToRemove, string ureason)
    {
        _userCache.TryGetValue(targetSteamID, out var targetData);
        string removeType = "E";
        int removedBy = 0;
        if (admin != null && _userCache.TryGetValue(admin.SteamID, out var adminData))
        {
            removeType = "U";
            removedBy = adminData.Aid;
        }

        string table = (typeToRemove & BanType.Silence) != 0
            ? $"`{_prefix}_comms`"
            : $"`{_prefix}_bans`";

        int removedOn = (int)DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        await using var dbh = new MySqlConnection(DBH);
        await dbh.OpenAsync();
    
        using var updateCmd = new MySqlCommand($@"
            UPDATE {table}
            SET RemovedBy = @removedBy,
                RemoveType = @removeType,
                RemovedOn = @removedOn,
                ureason = @reason
            WHERE authid = @authid AND (RemovedOn IS NULL OR RemovedOn = 0)
            ORDER BY ends DESC
            LIMIT 1;", dbh);

        updateCmd.Parameters.AddWithValue("@authid", ToSteam2(targetSteamID));
        updateCmd.Parameters.AddWithValue("@removedBy", removedBy);
        updateCmd.Parameters.AddWithValue("@removeType", removeType);
        updateCmd.Parameters.AddWithValue("@removedOn", removedOn);
        updateCmd.Parameters.AddWithValue("@reason", ureason);

        try
        {
            await updateCmd.ExecuteNonQueryAsync();
            return true;
        }
        catch (Exception ex)
        {
            _logger?.LogError(ex, "[HLstatsZ] WriteUnBan exception for {Target}", targetData.PlayerName);
            return false;
        }
    }

    public static bool Validator(CCSPlayerController? player, ulong steamId = 0, bool earlyStage = false)
    {
        ulong sid64 = steamId != 0 ? steamId : (player != null && player.IsValid) ? player.SteamID : 0;
        if (sid64 == 0) return false;
    
        if (!_userCache.TryGetValue(sid64, out var userData))
            return false;
    
        DateTime now = DateTime.UtcNow;

        // --- Kick/Ban ---
        if ((userData.Ban & (BanType.Banip | BanType.Ban | BanType.Kick)) != 0 && userData.ExpiryBan > now)
        {
            var timeleft = FormatTimeLeft(player, userData.ExpiryBan - now);
            var remain   = DateTime.MaxValue > userData.ExpiryBan ? $"{timeleft} remaining" : HLstatsZ.T(player,"sz_menu.permanently");

            if (earlyStage && player == null)
            {
                Server.NextFrame(() => { Server.ExecuteCommand($"kickid {sid64} \"You are banned from this server ({remain})\""); });
            }
            else if (player != null && player.IsValid)
            {
                Server.NextFrame(() => {
                    HLstatsZ.publicChat("sz_chat.join_banned",player.PlayerName,remain);
                    player.Disconnect(NetworkDisconnectionReason.NETWORK_DISCONNECT_KICKED);
                });
            }

            _ = UpdateBlocked(sid64, userData.Bid);
            return true;
        }
    
        // --- Mute/Silence ---
        if (!earlyStage && player != null && player.IsValid)
        {
            if ((userData.Ban & BanType.Mute) != 0 && userData.ExpiryMute > now)
            {
                bool perm = userData.ExpiryMute == DateTime.MaxValue;
                var remain = perm ? HLstatsZ.T(player,"sz_menu.permanently") : $"{FormatTimeLeft(player, userData.ExpiryMute - now)} remaining";
                player.VoiceFlags = VoiceFlags.Muted;
                HLstatsZ.privateChat(player, "sz_chat.join_muted", player.PlayerName, remain);
            }

            if ((userData.Ban & BanType.Gag) != 0 && userData.ExpiryGag > now)
            {
                bool perm = userData.ExpiryGag == DateTime.MaxValue;
                var remain = perm ? HLstatsZ.T(player,"sz_menu.permanently") : $"{FormatTimeLeft(player, userData.ExpiryGag - now)} remaining";
                HLstatsZ.privateChat(player, "sz_chat.join_gagged", player.PlayerName, remain);
            }

            UpdateBanUser(player.SteamID, BanType.None, 0, true, 0, true);
        }

        return true;
    }

    public static void CleanupExpiredUsers()
    {
        DateTime now = DateTime.UtcNow;
        DateTime forever = DateTime.MaxValue;
        var keysToRemove = new List<ulong>();

        foreach (var kvp in _userCache)
        {
            var steamId = kvp.Key;
            var data = kvp.Value;
            bool isOlderThan24Hour = data.Updated < now.AddHours(-24);
            bool isOlderThan15Min = data.Updated < now.AddMinutes(-15);
            bool isExpiredBan = data.ExpiryBan < now && data.ExpiryMute < now && data.ExpiryGag < now;
            bool isPermanentBan = data.ExpiryBan == forever;

            var player = Utilities.GetPlayers().FirstOrDefault(p => p?.IsValid == true && p.SteamID == steamId);

            if ((data.Ban & (BanType.Banip | BanType.Ban | BanType.Mute | BanType.Gag))!=0)
            {
                if (data.ExpiryBan < now && ((data.Ban & BanType.Kick)!=0))
                {
                    SourceBans.UpdateBanUser(steamId, BanType.Kick, 0,true, 0);
                }
                if (data.ExpiryBan < now && ((data.Ban & (BanType.Ban | BanType.Banip)) != 0))
                {
                    _ = DiscordWebhooks.Send(HLstatsZ.Instance!.Config, "unban", null, steamId, "Expired", 0, _logger);
                    SourceBans.UpdateBanUser(steamId, BanType.Ban | BanType.Banip, 0, true, 0);
                }
                if (data.ExpiryMute < now && ((data.Ban & BanType.Mute)!=0))
                {
                    _ = DiscordWebhooks.Send(HLstatsZ.Instance!.Config, "unmute", null, steamId, "Expired", 0, _logger);
                    SourceBans.UpdateBanUser(steamId, BanType.Mute, 0, true, 0);
                    if (player != null)
                    {
                        player.VoiceFlags = VoiceFlags.Normal;
                        HLstatsZ.privateChat(player,"sz_chat.unmuted");
                    }
                }
                if (data.ExpiryGag < now && ((data.Ban & BanType.Gag)!=0))
                {
                    _ = DiscordWebhooks.Send(HLstatsZ.Instance!.Config, "ungag", null, steamId, "Expired", 0, _logger);
                    SourceBans.UpdateBanUser(steamId, BanType.Gag, 0, true, 0);
                    if (player != null)
                        HLstatsZ.privateChat(player,"sz_chat.ungagged");
                }
            }

            // remove offline
            if (player == null && ((isOlderThan15Min && isExpiredBan) || isOlderThan24Hour))
            {
                keysToRemove.Add(steamId);
            }

            // Show Advertissement
            ShowAds(now);
        }

        foreach (var key in keysToRemove)
        {
            _userCache.TryRemove(key, out _);
        }
    }

    public static void UpdateBanUser(ulong sid64, BanType type, int Duration, bool Unban, int aid, bool? Connected = null, int? Bid = null, string? PlayerName = null)
    {
        if (!_userCache.TryGetValue(sid64, out var userData))
            return;


        var newBan = Unban ? userData.Ban & ~type : userData.Ban | type;

        string playerName   = string.IsNullOrEmpty(PlayerName) ? userData.PlayerName : PlayerName;
        DateTime now        = DateTime.UtcNow;
        DateTime expiryBan  = userData.ExpiryBan;
        DateTime expiryMute = userData.ExpiryMute;
        DateTime expiryGag  = userData.ExpiryGag;
        int durationBan     = userData.DurationBan;
        int durationMute    = userData.DurationMute;
        int durationGag     = userData.DurationGag;
        int countBan        = userData.CountBan;
        int countMute       = userData.CountMute;
        int countGag        = userData.CountGag;
        int countSlay       = userData.CountSlay;
        int aBan            = userData.aBan;
        int aMute           = userData.aMute;
        int aGag            = userData.aGag;
        int bid             = Bid.HasValue ? Bid.Value : userData.Bid;
        bool connected      = Connected.HasValue ? Connected.Value : userData.Connected;
        DateTime updated    = connected ? now : userData.Updated;

        if (!Unban)
        {
            if ((type & (BanType.Banip | BanType.Ban | BanType.Kick)) != 0)
            {
                expiryBan = Duration == int.MaxValue ? DateTime.MaxValue : DateTime.UtcNow.AddSeconds(Duration);
                durationBan = Duration;
                aBan = aid;
                countBan++;
            }

            if ((type & BanType.Mute) != 0)
            {
                expiryMute = Duration == int.MaxValue ? DateTime.MaxValue : DateTime.UtcNow.AddSeconds(Duration);
                durationMute = Duration;
                aMute = aid;
                countMute++;
            }

            if ((type & BanType.Gag) != 0)
            {
                expiryGag = Duration == int.MaxValue ? DateTime.MaxValue : DateTime.UtcNow.AddSeconds(Duration);
                durationGag = Duration;
                aGag = aid;
                countGag++;
            }

            if ((type & BanType.Slay) != 0)
            {
                newBan = userData.Ban & ~type;
                countSlay++;
            }
        }

        _userCache[sid64] = (
            playerName,
            userData.IsAdmin,
            userData.Aid,
            userData.IP,
            userData.Flags,
            updated,
            newBan,
            expiryBan,
            expiryMute,
            expiryGag,
            durationBan,
            durationMute,
            durationGag,
            countBan,
            countMute,
            countGag,
            countSlay,
            aBan,
            aMute,
            aGag,
            bid,
            userData.Immunity,
            connected
        );
    }

    public static async Task GetSid()
    {
        if (!_enabled || string.IsNullOrEmpty(_cachedDBH)) return;

        try
        {
            await using var dbh = new MySqlConnection(DBH);
            await dbh.OpenAsync();
    
            var addr = serverAddr.Split(":", 2);
            if (addr.Length < 2) return;

            using var cmd = new MySqlCommand($@"
                SELECT sid
                FROM `{_prefix}_servers`
                WHERE ip = @ip AND port = @port
                LIMIT 1;", dbh);

            cmd.Parameters.AddWithValue("@ip", addr[0]);
            cmd.Parameters.AddWithValue("@port", addr[1]);

            using var reader = await cmd.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                serverID = reader.GetInt32("sid");
            }
            reader.Close();
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex, "[HLstatsZ] SourceBans Get Server ID failed (non-fatal).");
        }
    }

    public static string FormatTimeLeft(CCSPlayerController? player, TimeSpan timeLeft)
    {

        if (timeLeft.TotalDays > 365*20)
        {
            if (player == null)
                return "permanently";
            return HLstatsZ.T(player,"sz_menu.permanently");
        }

        if (timeLeft.TotalSeconds < 1)
        {
            if (player == null)
                return "expired";
            return HLstatsZ.T(player,"sz_menu.expired");
        }

        if (timeLeft.TotalDays > 1)
            return $"{(int)timeLeft.TotalDays}d";

        if (timeLeft.TotalHours >= 1)
            return $"{(int)timeLeft.TotalHours}h";

        if (timeLeft.Minutes > 0)
            return $"{timeLeft.Minutes}m";

        return $"{timeLeft.Seconds}s";
    }

    // Converts a Steam64 ID (ulong) to Steam2 format (STEAM_0:X:Y).
    public static string ToSteam2(ulong steamId64)
    {
        const ulong universeOffset = 76561197960265728UL;

        if (steamId64 <= universeOffset) return steamId64.ToString();

        var accountId = steamId64 - universeOffset;
        var authServer = accountId % 2;
        var authId = accountId / 2;

        return $"STEAM_0:{authServer}:{authId}";
    }

    // Converts a Steam2 to Steam63 format (17 char).
    public static ulong ToSteam64(string steam2)
    {
        if (string.IsNullOrWhiteSpace(steam2))
            return 0;

        var parts = steam2.Split(':');
        if (parts.Length != 3)
            return 0;

        if (!ulong.TryParse(parts[1], out ulong authServer))
            return 0;

        if (!ulong.TryParse(parts[2], out ulong authId))
            return 0;

        const ulong universeOffset = 76561197960265728UL;

        return authId * 2 + authServer + universeOffset;
    }

    public static string? GetClientIp(CCSPlayerController? player)
    {
        var s = player?.IpAddress;
        if (string.IsNullOrWhiteSpace(s))
            return null;
    
        var m4 = Ipv4WithPort.Match(s);
        if (m4.Success) return m4.Groups["ip"].Value;

        return "unknown";
    }

    public static void DelayedCommand(string command, float delaySeconds)
    {
        _DelayedCommand?.Kill();
        _DelayedCommand = new GameTimer(
            MathF.Max(0.01f, delaySeconds),
            () => Server.ExecuteCommand(command)
        );
    }

    public static void StartVoteTimer()
    {
        _voteTimer?.Kill();

        void Tick()
        {
            bool stillActive = CheckVotes();

            if (stillActive) {
                _voteTimer = new GameTimer(1.0f, Tick);
            } else { _voteTimer = null; }
        }

        _voteTimer = new GameTimer(1.0f, Tick);
    }
    
    public static void StopVoteTimer()
    {
        _voteTimer?.Kill();
        _voteTimer = null;
    }

    public static bool CheckVotes()
    {
        bool active = false;

        if (_vote.TryGetValue("kick", out var vk))
            active |= HandleKickVote(vk);

        if (_vote.TryGetValue("map", out var vm))
            active |= HandleMapVote(vm);

        return active;
    }

    private static bool HandleKickVote((DateTime Created, CCSPlayerController? target, string? Name, string? MapName, int YES, int NO, int Need) vote)
    {
        // Target left
        if (vote.target?.SteamID == null)
        {
            HLstatsZ.publicChat("sz_chat.vote_canceled",vote.Name!);
            _vote.Remove("kick");
            _userVote.Remove("kick");
            return false;
        }

        // Passed
        if (vote.YES >= vote.Need)
        {
            vote.target.CommitSuicide(false, true);
            UpdateBanUser(vote.target.SteamID, BanType.Kick, 120, false, 0);
            HLstatsZ.publicChat("sz_chat.vote_kick_passed",vote.Name!, vote.YES);
            _vote.Remove("kick");
            _userVote.Remove("kick");
            _ = DiscordWebhooks.Send(HLstatsZ.Instance!.Config, "kick", null, vote.target.SteamID, "Vote", 120, _logger);
            DelayedCommand($"kickid {vote.target.UserId} \"Kicked {vote.Name} (Vote)\"", KickDelay);
            return false; // vote is done
        }

        // Expired
        if ((DateTime.UtcNow - vote.Created).TotalSeconds > 30)
        {
            HLstatsZ.publicChat("sz_chat.vote_kick_timeout",vote.Name!);
            _vote.Remove("kick");
            _userVote.Remove("kick");
            return false;
        }

        return true;
    }

    private static bool HandleMapVote((DateTime Created, CCSPlayerController? target, string? Name, string? MapName, int YES, int NO, int Need) vote)
    {
        if (_rtv.Count > 0)
            return HandleMultiMapVote(vote);

        return HandleSingleMapVote(vote);
    }

    private static bool HandleSingleMapVote((DateTime Created, CCSPlayerController? target, string? Name, string? MapName, int YES, int NO, int Need) vote)
    {
        // Expired
        if ((DateTime.UtcNow - vote.Created).TotalSeconds > 30)
        {
            HLstatsZ.publicChat("sz_chat.vote_map_timeout",vote.MapName!);
            _vote.Remove("map");
            _userVote.Remove("map");
            return false;
        }

        // Passed
        if (vote.YES >= vote.Need && !_vote.ContainsKey("kick"))
        {
            HLstatsZ.publicChat("sz_chat.vote_map_passed", vote.MapName!, vote.YES);
            _vote.Remove("map");
            _userVote.Remove("map");

            var availableMaps = SourceBans.GetAvailableMaps(HLstatsZ.Instance!.Config, true);
            var match = availableMaps.FirstOrDefault(m =>
                string.Equals(m.DisplayName, vote.MapName, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(m.MapName, vote.MapName, StringComparison.OrdinalIgnoreCase) ||
                (m.WorkshopId != null && string.Equals(m.WorkshopId, vote.MapName, StringComparison.OrdinalIgnoreCase)));

            if (match != null)
            {
                var command = match.IsSteamWorkshop ? $"host_workshop_map {match.WorkshopId}" : $"changelevel {match.MapName}";
                DelayedCommand(command, 5.0f);
            }
            return false;
        }
        return true;
    }

    private static bool HandleMultiMapVote((DateTime Created, CCSPlayerController? target, string? Name, string? MapName, int YES, int NO, int Need) vote)
    {
        // Expired?
        if ((DateTime.UtcNow - vote.Created).TotalSeconds > 30)
        {
            HLstatsZ.publicChat("sz_chat.vote_map_timeout","rtv");
            _vote.Remove("map");
            _userVote.Remove("map");
            _rtv.Clear();
            return false;
        }

        // Count votes
        var tally = _userVote["map"].Values
            .GroupBy(c => c)
            .OrderByDescending(g => g.Count())
            .FirstOrDefault();

        if (tally != null && tally.Count() >= vote.Need && _rtv.Count > 0)
        {
            int winningChoice = tally.Key;

            if (winningChoice < 0 || winningChoice >= _rtv.Count)
            {
                _vote.Remove("map");
                _userVote.Remove("map");
                _rtv.Clear();
                return false;
            }

            var winner = _rtv[winningChoice];

            if (SourceBans._userNominate.Count > 0)
            {
                NextMap = winner.DisplayName;
                HLstatsZ.publicChat("sz_chat.vote_nominate", winner.DisplayName);
                return false;
            }
            HLstatsZ.publicChat("sz_chat.vote_map_passed", winner.DisplayName);
            _vote.Remove("map");
            _userVote.Remove("map");

            var command = winner.IsSteamWorkshop
                ? $"host_workshop_map {winner.WorkshopId}"
                : $"changelevel {winner.MapName}";
            DelayedCommand(command, 5.0f);

            _rtv.Clear();
            return false;
        }

        return true;
    }

    public static async Task Refresh()
    {
        // Start again from the database, but keep the vote kicks: they only live in this cache
        DateTime now = DateTime.UtcNow;
        foreach (var entry in _userCache)
        {
            if ((entry.Value.Ban & BanType.Kick) == 0 || entry.Value.ExpiryBan <= now)
                _userCache.TryRemove(entry.Key, out _);
        }
        var players = Utilities.GetPlayers()
            .Where(p => p?.IsValid == true && p?.IsBot == false)
            .ToList();

        foreach (var player in players)
        {
            bool _ = await isAdmin(player, true);

            Server.NextFrame(() =>
            {
                if (player.IsValid && !player.IsBot)
                    SourceBans.Validator(player);
            });
        }
    }

    public static void CameraCommand(CCSPlayerController? admin, CommandInfo? command, int d = 1)
    {
        string reply = "";
        int count = 0;
        // Group by IP
        var groups = _userCache
            .GroupBy(kvp => kvp.Value.Item4)
            .Where(g => g.Count() > d)
            .ToList();

        if (groups.Count == 0)
        {
            if (admin!= null)
                admin.PrintToConsole(HLstatsZ.T(admin,"sz_console.camera_noip"));
            if (command != null)
                command.ReplyToCommand(HLstatsZ.Instance!.T("sz_console.camera_noip"));
            return;
        }

        if (d == 1)
        {
            if (admin != null)
                admin.PrintToConsole(HLstatsZ.T(admin,"sz_console.camera"));
            if (command != null)
                reply = HLstatsZ.Instance!.T("sz_console.camera");
        } else {
            if (admin != null)
                admin.PrintToConsole(HLstatsZ.T(admin,"sz_console.players"));
            if (command != null)
                reply += HLstatsZ.Instance!.T("sz_console.players");
        }

        foreach (var g in groups)
        {
            var onlinePlayers = g.Where(p => {
                var target = HLstatsZ.FindTarget(p.Key);
                return target != null && target.IsValid;
            }).ToList();

            if (onlinePlayers.Count <= d) continue;

            var c = onlinePlayers.Count > 1 ? $"({onlinePlayers.Count})" : "";
            if (admin != null)
                admin.PrintToConsole($"\n{g.Key} {c}");
            if (command != null)
                command.ReplyToCommand($"\n{g.Key} {c}");

            count++;
            foreach (var (sid64, tuple) in onlinePlayers)
            {
                var target = HLstatsZ.FindTarget(sid64);
                var Name   = "";
                var Steam2 = "";
                var User   = "";
                if ( admin != null)
                {
                    Name = HLstatsZ.T(admin,"sz_console.camera_team_error");
                } else {
                    Name = HLstatsZ.Instance!.T("sz_console.camera_team_error");
                }
                var Team = "None";
                if (target != null && target.IsValid)
                {
                    Name   = HLstatsZ.Instance!.Trunc(target.PlayerName,10);
                    Team   = target.TeamNum switch {1 => "Spec", 2 => "T", 3 => "CT", _ => "NONE"};
                    Steam2 = ToSteam2(sid64);
                } else { continue; }

                var (_, _, aid, ip, _, seen, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, online) = tuple;
                User = aid > 0 ? "A" : "U";
                reply = $"{Name} - {Team} - {Steam2} - {User} - {seen.ToLocalTime():HH:mm}";

                if (admin != null)
                    admin.PrintToConsole(reply);
                if (command != null)
                    command.ReplyToCommand(reply);

            }
        }

        if (count == 0 && d == 1)
        {
            if (admin!= null)
                admin.PrintToConsole(HLstatsZ.T(admin,"sz_console.camera_noip"));
            if (command != null)
                command.ReplyToCommand(HLstatsZ.Instance!.T("sz_console.camera_noip"));
        }

    }

    public static bool TryParseWeapon(string value, out CsItem item)
    {
        item = CsItem.Decoy;

        if (string.IsNullOrWhiteSpace(value))
            return false;

        value = value.Trim();

        if (value.StartsWith("weapon_", StringComparison.OrdinalIgnoreCase))
            value = value.Substring(7);

        return Enum.TryParse(value, ignoreCase: true, out item);
    }

    public static void GiveItems(CCSPlayerController player, string? Item = null)
    {
        if (player == null || !player.IsValid || player.PlayerPawn == null || !player.PlayerPawn.IsValid)
            return;

        var pawn = player.PlayerPawn.Value;
        if (pawn == null || !pawn.IsValid)
            return;

        var itemServices   = pawn.ItemServices;
        var weaponServices = pawn.WeaponServices;

        if (itemServices == null || weaponServices == null)
            return;

        if (!string.IsNullOrEmpty(Item))
        {
            if (TryParseWeapon(Item, out var item))
                player.GiveNamedItem(item);
        }
    }

}

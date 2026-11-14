using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using CounterStrikeSharp.API;
using CounterStrikeSharp.API.Core;
using CounterStrikeSharp.API.Core.Translations;
using CounterStrikeSharp.API.Core.Attributes.Registration;
using CounterStrikeSharp.API.Core.Plugin;
using CounterStrikeSharp.API.Modules.Commands;
using CounterStrikeSharp.API.Modules.Utils;
using CounterStrikeSharp.API.Modules.Menu;
using CounterStrikeSharp.API.Modules.Entities;
using CounterStrikeSharp.API.Modules.Events;
using CounterStrikeSharp.API.Modules.Cvars;
using CounterStrikeSharp.API.Modules.Timers;
using GameTimer = CounterStrikeSharp.API.Modules.Timers.Timer;
using CounterStrikeSharp.API.Modules.Entities.Constants;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Sockets;
using System.Net;
using System.Text;

namespace HLstatsZ;

public class HLstatsZMainConfig : IBasePluginConfig
{
    [JsonPropertyName("Enable_HLstats")] public bool Enable_HLstats { get; set; } = false;
    [JsonPropertyName("Enable_Sourcebans")] public bool Enable_Sourcebans { get; set; } = true;
    [JsonPropertyName("Log_Address")] public string Log_Address { get; set; } = "127.0.0.1";
    [JsonPropertyName("Log_Port")] public int Log_Port { get; set; } = 27500;
    [JsonPropertyName("BroadcastAll")] public int BroadcastAll { get; set; } = 0;
    [JsonPropertyName("ServerAddr")] public string ServerAddr { get; set; } = "";
    [JsonPropertyName("HLZ_Prefix")] public string HLZ_Prefix { get; set; } = "";
    public int Version { get; set; } = 2;

    [JsonPropertyName("SourceBans")] public SourceBansConfig SourceBans { get; set; } = new();

    [JsonPropertyName("Maps")] public MapsConfig Maps { get; set; } = new();

    [JsonPropertyName("Avertissements")] public List<AvertissementEntry> Avertissements { get; set; } = new();

    [JsonPropertyName("Welcomes")] public List<WelcomeEntry>? Welcomes { get; set; } = new();

    [JsonPropertyName("PlayerDeath")] public List<PlayerDeathEntry>? PlayerDeath { get; set; } = new();

    [JsonPropertyName("Discord")] public DiscordConfig Discord { get; set; } = new();
}

public class SourceBansConfig
{
    [JsonPropertyName("Host")] public string Host { get; set; } = "127.0.0.1";
    [JsonPropertyName("Port")] public int Port { get; set; } = 3306;
    [JsonPropertyName("SslMode")] public string SslMode { get; set; } = "None";
    [JsonPropertyName("Database")] public string Database { get; set; } = "";
    [JsonPropertyName("Prefix")] public string Prefix { get; set; } = "sb";
    [JsonPropertyName("User")] public string User { get; set; } = "";
    [JsonPropertyName("Password")] public string Password { get; set; } = "";
    [JsonPropertyName("Website")] public string Website { get; set; } = "";
    [JsonPropertyName("VoteKick")] public string VoteKick { get; set; } = "public";
    [JsonPropertyName("KickDelay")] public int KickDelay { get; set; } = 5;
    [JsonPropertyName("Chat_Ban_Duration_Max")] public int Chat_Ban_Duration_Max { get; set; } = 10080;
    [JsonPropertyName("Menu_Ban1_Duration")] public int Menu_Ban1_Duration { get; set; } = 15;
    [JsonPropertyName("Menu_Ban2_Duration")] public int Menu_Ban2_Duration { get; set; } = 60;
    [JsonPropertyName("Menu_Ban3_Duration")] public int Menu_Ban3_Duration { get; set; } = 1440;
    [JsonPropertyName("Menu_Ban4_Duration")] public int Menu_Ban4_Duration { get; set; } = 10080;
    [JsonPropertyName("Menu_Ban5_Duration")] public int Menu_Ban5_Duration { get; set; } = 0;
}

public class MapsConfig
{
    [JsonPropertyName("VoteMap")] public string VoteMap { get; set; } = "public";
    [JsonPropertyName("Nominate")] public bool Nominate { get; set; } = false;
    [JsonPropertyName("MapCycle")] public MapCycleSection MapCycle { get; set; } = new();
}

public class MapCycleSection
{
    [JsonPropertyName("Admin")] public MapCycleConfig Admin { get; set; } = new();
    [JsonPropertyName("Public")] public MapCycleConfig Public { get; set; } = new();
}

public class MapCycleConfig
{
    [JsonPropertyName("Maps")] public List<string> Maps { get; set; } = new();
}

public class AvertissementEntry
{
    [JsonPropertyName("Message")] public string Message { get; set; } = "";
    [JsonPropertyName("PrintType")] public string PrintType { get; set; } = "say";
    [JsonPropertyName("EveryMinutes")] public int EveryMinutes { get; set; } = 15;
}

public class WelcomeEntry
{
    public string Welcome { get; set; } = "";
    public string PrintType { get; set; } = "say";
    public int Delay { get; set; } = 10;
}

public class PlayerDeathEntry
{
    public string Message { get; set; } = "";
    public string PrintType { get; set; } = "say";
    public int Duration { get; set; } = 5;
}

public sealed class DiscordConfig
{
    public string Username            { get; set; } = "HLstatsZ";
    public string WebhookUrl          { get; set; } = "";
    public string LogsWebhookUrl      { get; set; } = "";
    public string ColorPermanent      { get; set; } = "#FF0000";
    public string ColorWithExpiration { get; set; } = "#FF9900";
    public string ColorUnban          { get; set; } = "#00FF00";
    public bool   ShowAdmin           { get; set; } = true;
}

public class HLstatsZ : BasePlugin, IPluginConfig<HLstatsZMainConfig>
{
    public static HLstatsZ? Instance;
    private static readonly HttpClient httpClient = new();
    public static HttpClient Http => httpClient;
    public HLstatsZMainConfig Config { get; set; } = new();
    public HLZMenuManager _menuManager = null!;
    public static bool _enabled = false;
    public string Trunc(string s, int max=20)
        => s.Length > max ? s.Substring(0, Math.Max(0, max - 3)) + "..." : s;

    public static LogDispatcher? LogQueue;

    private static GameTimer? _centerHTML;

    public static string HLZ_Prefix = "";

    private struct WeaponStats
    {
        public int shots;
        public int hits;
        public int headshots;
        public int damage;
        public int kills;
        public int deaths;
    }

    private struct HitgroupStats
    {
        public int head;
        public int chest;
        public int stomach;
        public int leftarm;
        public int rightarm;
        public int leftleg;
        public int rightleg;
    }

    private static readonly Dictionary<ulong, Dictionary<string, WeaponStats>> _Statsme  = new();
    private static readonly Dictionary<ulong, Dictionary<string, HitgroupStats>> _Statsme2 = new();

    private string? _lastPsayHash;
    public override string ModuleName => "HLstatsZ Classics";
    public override string ModuleVersion => "2.4.2";
    public override string ModuleAuthor => "SnipeZilla";

    public void OnConfigParsed(HLstatsZMainConfig config)
    {
        Config = config;

        if (string.IsNullOrWhiteSpace(Config.Log_Address) || !Config.Enable_HLstats)
        {
            _enabled = false;
            Instance?.Logger.LogInformation("[HLstatsZ] HLstats is disabled: missing config (Enable_HLstats/Log_Address).");
            return;
        }
        _enabled = true;

       SourceBans.Durations[0] = Config.SourceBans.Chat_Ban_Duration_Max *60;
       SourceBans.Durations[1] = Config.SourceBans.Menu_Ban1_Duration    *60;
       SourceBans.Durations[2] = Config.SourceBans.Menu_Ban2_Duration    *60;
       SourceBans.Durations[3] = Config.SourceBans.Menu_Ban3_Duration    *60;
       SourceBans.Durations[4] = Config.SourceBans.Menu_Ban4_Duration    *60;
       SourceBans.Durations[5] = Config.SourceBans.Menu_Ban5_Duration    *60;

       SourceBans.KickDelay = (float)Config.SourceBans.KickDelay;

    }

    public override void Load(bool hotReload)
    {
        Instance = this;

        RegisterListener<Listeners.OnMapStart>(OnMapStart);
        RegisterListener<Listeners.OnClientAuthorized>(OnClientAuthorized);

        RegisterEventHandler<EventPlayerSpawn>(OnPlayerSpawn);
        RegisterEventHandler<EventRoundStart>(OnRoundStart);
        RegisterEventHandler<EventRoundEnd>(OnRoundEnd);
        RegisterEventHandler<EventRoundMvp>(OnRoundMvp);
        RegisterEventHandler<EventBombAbortdefuse>(OnBombAbortdefuse);
        RegisterEventHandler<EventBombDefused>(OnBombDefused);
        RegisterEventHandler<EventPlayerConnectFull>(OnPlayerConnectFull);
        RegisterEventHandler<EventPlayerDisconnect>(OnPlayerDisconnect);
        RegisterEventHandler<EventPlayerDeath>(OnPlayerDeath);
        RegisterEventHandler<EventWeaponFire>(OnWeaponFire);
        RegisterEventHandler<EventPlayerHurt>(OnPlayerHurt);
        RegisterEventHandler<EventCsWinPanelMatch>(OnCsWinPanelMatch);

        AddCommandListener(null, ComamndListenerHandler, HookMode.Pre);

        _menuManager = new HLZMenuManager(this);

        if (!string.IsNullOrWhiteSpace(Config.HLZ_Prefix))
        {
            HLZ_Prefix = Colors(" "+Config.HLZ_Prefix.Trim()+"\x01 ");
        }

        if (string.IsNullOrWhiteSpace(Config.ServerAddr))
        {
            var hostPort = int.TryParse(ConVar<int>.Find("hostport")?.ValueAsString, out var port) ? port : 27015;
            var serverIP = ConVar<string>.Find("ip")?.ValueAsString ?? GetLocalIPAddress();
            Config.ServerAddr = $"{serverIP}:{hostPort}";
        }
        SourceBans.serverAddr = Config.ServerAddr;

        SourceBans.hostName   = ConVar<string>.Find("hostname")?.ValueAsString ?? "";

        SourceBans.Init(Config, Logger);
        _ = SourceBans.GetSid();
        _ = SourceBans.Refresh();

        if (SourceBans._enabled) {
            Instance?.Logger.LogInformation($"[HLstatsZ] Sourcebans is enabled for server: {SourceBans.serverAddr} (hotReload={hotReload})");
        } else {
            Instance?.Logger.LogInformation($"[HLstatsZ] Sourcebans is disabled for server: {SourceBans.serverAddr} (hotReload={hotReload})");
        }
        SourceBans._canVote = true;
        SourceBans.InitAvertissements(Config);

        SourceBans._cleanupTimer?.Kill();
        SourceBans._cleanupTimer = new GameTimer(60.0f,
                                        () => SourceBans.CleanupExpiredUsers(),
                                        TimerFlags.REPEAT
        );

        LogQueue = new LogDispatcher(Config.Log_Address, Config.Log_Port, Config.ServerAddr);

    }

    public override void Unload(bool hotReload)
    {

        RemoveListener<Listeners.OnMapStart>(OnMapStart);
        RemoveListener<Listeners.OnClientAuthorized>(OnClientAuthorized);

        DeregisterEventHandler<EventPlayerSpawn>(OnPlayerSpawn);
        DeregisterEventHandler<EventRoundStart>(OnRoundStart);
        DeregisterEventHandler<EventRoundEnd>(OnRoundEnd);
        DeregisterEventHandler<EventRoundMvp>(OnRoundMvp);
        DeregisterEventHandler<EventBombAbortdefuse>(OnBombAbortdefuse);
        DeregisterEventHandler<EventBombDefused>(OnBombDefused);
        DeregisterEventHandler<EventPlayerConnectFull>(OnPlayerConnectFull);
        DeregisterEventHandler<EventPlayerDisconnect>(OnPlayerDisconnect);
        DeregisterEventHandler<EventPlayerDeath>(OnPlayerDeath);
        DeregisterEventHandler<EventWeaponFire>(OnWeaponFire);
        DeregisterEventHandler<EventPlayerHurt>(OnPlayerHurt);
        DeregisterEventHandler<EventCsWinPanelMatch>(OnCsWinPanelMatch);

        RemoveCommandListener(null!, ComamndListenerHandler, HookMode.Pre);

        SourceBans._cleanupTimer?.Kill();
        SourceBans._cleanupTimer = null;
        SourceBans._voteTimer?.Kill();
        SourceBans._voteTimer = null;
        SourceBans._DelayedCommand?.Kill();
        SourceBans._DelayedCommand = null;

        LogQueue?.Dispose();

    }

    // ------------------ Core Logic ------------------
    public static string GetLocalIPAddress()
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, 0);
        socket.Connect("8.8.8.8", 65530); // Google's DNS
        var endPoint = socket.LocalEndPoint as IPEndPoint;
        return endPoint?.Address.ToString() ?? "127.0.0.1";
    }

    private static readonly Dictionary<string, char> ColorCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["default"]     = '\x01',
        ["white"]       = '\x01',
        ["darkred"]     = '\x02',
        ["green"]       = '\x04',
        ["lightyellow"] = '\x09',
        ["yellow"]      = '\x09',
        ["lightblue"]   = '\x0B',
        ["blue"]        = '\x0B',
        ["darkblue"]    = '\x0C',
        ["olive"]       = '\x05',
        ["lime"]        = '\x06',
        ["red"]         = '\x07',
        ["lightpurple"] = '\x03',
        ["purple"]      = '\x0E',
        ["magenta"]     = '\x0E',
        ["grey"]        = '\x08',
        ["orange"]      = '\x10',
        ["gold"]        = '\x10',
        ["silver"]      = '\x0A',
        ["bluegrey"]    = '\x0A',
        ["lightred"]    = '\x0F',
    };

    private static readonly Dictionary<string, string> CenterColorCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["default"]     = "</font>",
        ["white"]       = "<font color='#FFFFFF'>",
        ["darkred"]     = "<font color='#FF0000'>",
        ["green"]       = "<font color='#00FF00'>",
        ["lightyellow"] = "<font color='#FFECA1'>",
        ["yellow"]      = "<font color='#FFFF00'>",
        ["blue"]        = "<font color='#007BFF'>",
        ["lightblue"]   = "<font color='#ADD8E6'>",
        ["darkblue"]    = "<font color='#00008B'>",
        ["olive"]       = "<font color='#808000'>",
        ["lime"]        = "<font color='#32CD32'>",
        ["red"]         = "<font color='#FF0000'>",
        ["lightpurple"] = "<font color='#E7DDFF'>",
        ["purple"]      = "<font color='#800080'>",
        ["magenta"]     = "<font color='#FF00FF'>",
        ["grey"]        = "<font color='#CCCCCC'>",
        ["orange"]      = "<font color='#FFA500'>",
        ["gold"]        = "<font color='#FFD700'>",
        ["silver"]      = "<font color='#C0C0C0'>",
        ["bluegrey"]    = "<font color='#E2EAF4'>",
        ["lightred"]    = "<font color='#EFC3CA'>",
    };

    private static readonly Dictionary<string, string> WeaponCode = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ak47"]          = "ak47",
        ["aug"]           = "aug",
        ["awp"]           = "awp",
        ["famas"]         = "famas",
        ["g3sg1"]         = "g3sg1",
        ["galilar"]       = "galilar",
        ["m4a1_silencer"] = "m4a1_silencer",
        ["m4a1"]          = "m4a1",
        ["scar20"]        = "scar20",
        ["sg556"]         = "sg556",
        ["ssg08"]         = "ssg08",

        ["mac10"]         = "mac10",
        ["mp5sd"]         = "mp5sd",
        ["mp7"]           = "mp7",
        ["mp9"]           = "mp9",
        ["bizon"]         = "bizon",
        ["p90"]           = "p90",
        ["ump45"]         = "ump45",

        ["mag7"]          = "mag7",
        ["nova"]          = "nova",
        ["sawedoff"]      = "sawedoff",
        ["xm1014"]        = "xm1014",
        ["m249"]          = "m249",
        ["negev"]         = "negev",

        ["cz75a"]         = "cz75a",
        ["deagle"]        = "deagle",
        ["elite"]         = "elite",
        ["fiveseven"]     = "fiveseven",
        ["glock"]         = "glock",
        ["hkp2000"]       = "hkp2000",
        ["p250"]          = "p250",
        ["revolver"]      = "revolver",
        ["tec9"]          = "tec9",
        ["usp_silencer"]  = "usp_silencer",
        ["usp"]           = "usp",
    };

    private static Dictionary<string, WeaponStats> GetStatsme(ulong steamId)
    {
        if (!_Statsme.TryGetValue(steamId, out var dict))
        {
            dict = new Dictionary<string, WeaponStats>(8);
            _Statsme[steamId] = dict;
        }
        return dict;
    }

    private static Dictionary<string, HitgroupStats> GetStatsme2(ulong steamId)
    {
        if (!_Statsme2.TryGetValue(steamId, out var dict))
        {
            dict = new Dictionary<string, HitgroupStats>(8);
            _Statsme2[steamId] = dict;
        }
        return dict;
    }

    private static ref WeaponStats GetWeaponStats(Dictionary<string, WeaponStats> dict, string weaponCode)
    {
        return ref CollectionsMarshal.GetValueRefOrAddDefault(dict, weaponCode, out _);
    }

    private static ref HitgroupStats GetHitgroupStats(Dictionary<string, HitgroupStats> dict, string weaponCode)
    {
        return ref CollectionsMarshal.GetValueRefOrAddDefault(dict, weaponCode, out _);
    }

    private void SendStatsme(CCSPlayerController player, string statsVerb, Dictionary<string, string> props)
    {
        var sb = new StringBuilder();
        sb.Append(statsVerb);
        sb.Append('"');

        foreach (var kv in props)
        {
            sb.Append(" (");
            sb.Append(kv.Key);
            sb.Append(" \"");
            sb.Append(kv.Value);
            sb.Append("\")");
        }

        SendLog(player, sb.ToString(), "triggered");
    }

    private void FlushPlayerWeaponStats(CCSPlayerController player)
    {
        if (player == null || !player.IsValid || player.IsBot)
            return;

        var steamId = player.SteamID;

        if (_Statsme.TryGetValue(steamId, out var dict))
        {
            foreach (var kv in dict)
            {
                var weaponCode = kv.Key;
                var s = kv.Value;

                var props = new Dictionary<string, string>
                {
                    ["weapon"]    = weaponCode,
                    ["shots"]     = s.shots.ToString(),
                    ["hits"]      = s.hits.ToString(),
                    ["headshots"] = s.headshots.ToString(),
                    ["damage"]    = s.damage.ToString(),
                    ["kills"]     = s.kills.ToString(),
                    ["deaths"]    = s.deaths.ToString()
                };

                SendStatsme(player, "weaponstats", props);
            }
            _Statsme.Remove(steamId);
        }

        if (_Statsme2.TryGetValue(steamId, out var hdict))
        {
            foreach (var kv in hdict)
            {
                var weaponCode = kv.Key;
                var hs = kv.Value;

                var props2 = new Dictionary<string, string>
                {
                    ["weapon"]   = weaponCode,
                    ["head"]     = hs.head.ToString(),
                    ["chest"]    = hs.chest.ToString(),
                    ["stomach"]  = hs.stomach.ToString(),
                    ["leftarm"]  = hs.leftarm.ToString(),
                    ["rightarm"] = hs.rightarm.ToString(),
                    ["leftleg"]  = hs.leftleg.ToString(),
                    ["rightleg"] = hs.rightleg.ToString()
                };

                SendStatsme(player, "weaponstats2", props2);
            }
            _Statsme2.Remove(steamId);
        }
    }

    public string T(string key, params object[] args)
        => Colors(Localizer[key, args]);
    
    public static string T(CCSPlayerController? p, string key, params object[] args)
    {
        if (p == null) return Instance!.T(key, args);
        return Colors(Instance!.Localizer.ForPlayer(p, key, args));
    }

    public static void privateChat(CCSPlayerController? player, string key, params object[] args)
    {
        if (player == null)
            Console.WriteLine(Instance!.T(key, args));
        else
            player.PrintToChat(T(player, "sz_chat.prefix") + " " + T(player, key, args)); 
    }

    public static void publicChat(string key, params object[] args)
    {
        var players = GetPlayersList();

        foreach (var player in players)
            player.PrintToChat(T(player, "sz_chat.prefix") + " " + T(player, key, args));
    }

    private static readonly Regex ColorRegex = new(@"\{([a-zA-Z]+)\}", RegexOptions.Compiled);

    public static string Colors(string input)
    {
        return ColorRegex.Replace(input, m =>
        {
            var key = m.Groups[1].Value;
            return ColorCodes.TryGetValue(key, out var code) ? code.ToString() : m.Value;
        });
    }

    public static string CenterColors(string input)
    {
        return ColorRegex.Replace(input, m =>
        {
            var key = m.Groups[1].Value;
            return CenterColorCodes.TryGetValue(key, out var html) ? html : m.Value;
        });
    }

    public sealed class LogDispatcher : IDisposable
    {
        private readonly ConcurrentQueue<string> _queue = new();
        private readonly CancellationTokenSource _cts = new();
        private readonly Task _worker;
        private readonly HttpClient _http;

        private readonly string _url;
        private readonly string _serverAddr;

        // --- Adaptive parameters ---
        private int _batchSize = 10;
        private int _delayMs = 10;
        private const int MaxBatchSize = 200;
        private const int MinBatchSize = 1;
        private const int MaxDelayMs = 200;
        private const int MinDelayMs = 1;

        // --- Thresholds ---
        private const int HighLatencyMs = 250;
        private const int CriticalLatencyMs = 500;
        private const int LowLatencyMs = 80;

        private const int HighQueueDepth = 5000;
        private const int CriticalQueueDepth = 20000;

        public LogDispatcher(string logAddress, int logPort, string serverAddr)
        {
            _url = $"http://{logAddress}:{logPort}";
            _serverAddr = serverAddr;

            _http = new HttpClient
            {
                Timeout = TimeSpan.FromSeconds(10)
            };

            _worker = Task.Run(ProcessQueueAsync);
        }

        public void Enqueue(string line)
        {
            _queue.Enqueue(line);
        }

        private async Task ProcessQueueAsync()
        {
            while (!_cts.IsCancellationRequested)
            {
                try
                {
                    if (_queue.IsEmpty)
                    {
                        await Task.Delay(5, _cts.Token);
                        continue;
                    }

                    var batch = new List<string>(_batchSize);

                    while (batch.Count < _batchSize && _queue.TryDequeue(out var line))
                        batch.Add(line);

                    var latency = await SendBatchAsync(batch);

                    AdjustBehavior(latency, _queue.Count);

                    await Task.Delay(_delayMs, _cts.Token);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    Instance?.Logger.LogInformation($"[HLstatsZ] Log dispatcher error: {ex.Message}");
                }
            }
        }

        private static bool IsRetryable(Exception ex)
        {
            if (ex is HttpRequestException hre && hre.InnerException is HttpIOException ioex &&
                ioex.Message.Contains("response ended prematurely", StringComparison.OrdinalIgnoreCase))
                return true;

            if (ex is HttpRequestException hre2 && hre2.InnerException is IOException)
                return true;

            // A timeout is not retried: the request was sent and the daemon queues the lines before it answers, so
            // sending them again would count every kill of the batch twice

            return false;
        }

        private async Task<HttpResponseMessage?> SendOnceAsync(HttpRequestMessage request, CancellationToken token)
        {
            return await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token)
                             .ConfigureAwait(false);
        }

        private async Task<long> SendBatchAsync(List<string> batch)
        {
            if (batch.Count == 0) return 0;

            var payload = string.Join("\n", batch);

            var sw = Stopwatch.StartNew();
            try
            {
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    _cts.Token.ThrowIfCancellationRequested();

                    using var request = new HttpRequestMessage(HttpMethod.Post, _url);
                    request.Headers.TryAddWithoutValidation("X-Server-Addr", _serverAddr);
                    request.Content = new StringContent(payload, Encoding.UTF8, "text/plain");

                    try
                    {
                        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, _cts.Token).ConfigureAwait(false);

                        _ = await response.Content.ReadAsByteArrayAsync(_cts.Token).ConfigureAwait(false);

                        sw.Stop();

                        if (!response.IsSuccessStatusCode)
                            Instance?.Logger.LogInformation($"[HLstatsZ] Log Batch send failed: {response.StatusCode}");

                        return sw.ElapsedMilliseconds;
                    }
                    catch (Exception ex) when (attempt < 2 && IsRetryable(ex))
                    {
                        var backoffMs = (int)(50 * Math.Pow(2, attempt)) + Random.Shared.Next(0, 50);
                        await Task.Delay(backoffMs, _cts.Token).ConfigureAwait(false);
                    }
                }
            }
            catch (Exception ex)
            {
                sw.Stop();
                Instance?.Logger.LogInformation($"[HLstatsZ] Log Batch send exception: {ex}");
            }

            return sw.ElapsedMilliseconds;
        }

        private void AdjustBehavior(long latencyMs, int queueDepth)
        {
            // --- Latency-based ---
            if (latencyMs > CriticalLatencyMs)
            {
                _batchSize = Math.Max(MinBatchSize, _batchSize / 2);
                _delayMs = Math.Min(MaxDelayMs, _delayMs + 20);
            }
            else if (latencyMs > HighLatencyMs)
            {
                _batchSize = Math.Max(MinBatchSize, _batchSize - 2);
                _delayMs = Math.Min(MaxDelayMs, _delayMs + 5);
            }
            else if (latencyMs < LowLatencyMs)
            {
                _batchSize = Math.Min(MaxBatchSize, _batchSize + 2);
                _delayMs = Math.Max(MinDelayMs, _delayMs - 2);
            }

            // --- Queue-depth  ---
            if (queueDepth > CriticalQueueDepth)
            {
                _batchSize = Math.Min(MaxBatchSize, _batchSize + 20);
                _delayMs = Math.Min(MaxDelayMs, _delayMs + 20);
            }
            else if (queueDepth > HighQueueDepth)
            {
                _batchSize = Math.Min(MaxBatchSize, _batchSize + 10);
                _delayMs = Math.Min(MaxDelayMs, _delayMs + 10);
            }

        }

        public void Dispose()
        {
            _cts.Cancel();
            _worker.Wait(2000);
            _cts.Dispose();
            _http.Dispose();
        }
    }

    public void SendLog(CCSPlayerController? player, string message, string? verb)
    {
        string logLine;

        if (player?.IsValid == true && !string.IsNullOrWhiteSpace(verb))
        {

            var name    = player.PlayerName;
            var userid  = player.UserId;
            var steamid = (uint)(player.SteamID - 76561197960265728);
            var team    = player.TeamNum switch {2 => "TERRORIST", 3 => "CT", _ => "UNASSIGNED"};

            logLine = $"L {DateTime.Now:MM/dd/yyyy - HH:mm:ss}: \"{name}<{userid}><[U:1:{steamid}]><{team}>\" {verb} \"{message}\"";

        } else if (string.IsNullOrWhiteSpace(verb)) {

            logLine = $"L {DateTime.Now:MM/dd/yyyy - HH:mm:ss}: {message}";

        } else { return; }

        LogQueue?.Enqueue(logLine);

    }

    private static string NormalizeName(string name)
    {
        var normalized = name.ToLowerInvariant();
        normalized = new string(normalized
            .Where(c => !char.IsControl(c) && c != '\u200B' && c != '\u200C' && c != '\u200D')
            .ToArray());
        normalized = new string(normalized.Where(c => c <= 127).ToArray());
        return normalized.Trim();
    }

    public static CCSPlayerController? FindTarget(object pl)
    {
        string? token = pl as string ?? pl?.ToString();
        if (string.IsNullOrWhiteSpace(token)) return null;

        // userid - hlstats
        if (int.TryParse(token, out var uid))
            return Utilities.GetPlayers().FirstOrDefault(p => p?.IsValid == true && p.UserId == uid);

        // #userid - sb
        if (token[0] == '#' && int.TryParse(token.AsSpan(1), out var uid2))
            return Utilities.GetPlayers().FirstOrDefault(p => p?.IsValid == true && p.UserId == uid2);

        // SteamID64
        if (ulong.TryParse(token, out var sid64) && token.Length >= 17)
            return Utilities.GetPlayers().FirstOrDefault(p => p?.IsValid == true && p.SteamID == sid64);

        // Name
        var name = NormalizeName(token);

        var players = Utilities.GetPlayers().Where(p => p?.IsValid == true).ToList();

        // 1. Exact match
        var exactMatches = players.Where(p => NormalizeName(p.PlayerName) == name).ToList();
        if (exactMatches.Count == 1) return exactMatches[0];
        if (exactMatches.Count > 1) return null;

        // 2. Unique "starts with"
        var prefixMatches = players.Where(p => NormalizeName(p.PlayerName).StartsWith(name)).ToList();
        if (prefixMatches.Count == 1) return prefixMatches[0];
        if (prefixMatches.Count > 1) return null;

        // 3. Unique "contains"
        var containsMatches = players.Where(p => NormalizeName(p.PlayerName).Contains(name)).ToList();
        if (containsMatches.Count == 1) return containsMatches[0];
        if (containsMatches.Count > 1) return null;

        // Steam2
        var steam64 = SourceBans.ToSteam64(token);
        if (steam64 > 0)
            return Utilities.GetPlayers().FirstOrDefault(p => p?.IsValid == true && p.SteamID == steam64);

    return null;
    }

    public static ulong FindTargetCached(object pl)
    {
        string? token = pl as string ?? pl?.ToString();
        if (string.IsNullOrWhiteSpace(token)) return 0;

        var name = NormalizeName(token);

        var cachedPlayers = SourceBans._userCache
            .Select(kvp => new { SteamId = kvp.Key, kvp.Value.PlayerName })
            .ToList();

        // 1. Exact match
        var exactMatches = cachedPlayers.Where(v => NormalizeName(v.PlayerName) == name).ToList();
        if (exactMatches.Count == 1) return exactMatches[0].SteamId;
        if (exactMatches.Count > 1) return 0;

        // 2. Unique "starts with"
        var prefixMatches = cachedPlayers.Where(v => NormalizeName(v.PlayerName).StartsWith(name)).ToList();
        if (prefixMatches.Count == 1) return prefixMatches[0].SteamId;
        if (prefixMatches.Count > 1) return 0;

        // 3. Unique "contains"
        var containsMatches = cachedPlayers.Where(v => NormalizeName(v.PlayerName).Contains(name)).ToList();
        if (containsMatches.Count == 1) return containsMatches[0].SteamId;
        if (containsMatches.Count > 1) return 0;

        // #userid
        if (token[0] == '#' && int.TryParse(token.AsSpan(1), out var uid))
        {
            var live = Utilities.GetPlayerFromUserid(uid);
            return live == null ? 0 : live.SteamID;
        }

        // userid
        if (int.TryParse(token, out var uid2))
        {
            var live = Utilities.GetPlayerFromUserid(uid2);
            return live == null ? 0 : live.SteamID;
        }

        // SteamID64
        if (ulong.TryParse(token, out var sid64) && token.Length >= 17)
        {
            if (SourceBans._userCache.ContainsKey(sid64))
                return sid64;
        }

        // Steam2 → convert to Steam64
        var steam64 = SourceBans.ToSteam64(token);
        if (steam64 > 0 && SourceBans._userCache.ContainsKey(steam64))
            return steam64;

        return 0;
    }

    private bool HandleAtCommand(CCSPlayerController player, string raw, bool isAdmin)
    {
        var text = raw.Length > 1 ? raw.Substring(1) : string.Empty;
        if (string.IsNullOrWhiteSpace(text)) return false;

        var msg = "";
        string local = isAdmin ? "sz_chat.admin_say" : "sz_chat.player_say";
        var firstSpace = text.IndexOf(' ');
        if (firstSpace == -1) return false;

        // @ or @all <message>  -> to admins
        if (text.StartsWith(" "))
        {

            var report = text.Trim();
            if (report.Length == 0) return false;
            if (isAdmin)
            {
                SendChatToAdmin(T(player, "sz_chat.prefix") + " " + T(player, local, player.PlayerName, Colors(report)));
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        player,
                                                        "@",
                                                        Colors(report),
                                                        isAdmin
                                                    );
                return true;
            } else {
                return false;
            }
        }

        if (isAdmin && text.StartsWith("s ", StringComparison.OrdinalIgnoreCase))
        {
            msg = text.Substring(2).Trim();
            if (msg.Length == 0) return false;
            SendChatToTeam(CsTeam.Spectator,T(player, "sz_chat.prefix") + " " +  T(player,"sz_chat.admin_say",player.PlayerName,Colors($"{msg}")));
            return true;
        }
        if (isAdmin && text.StartsWith("ct ", StringComparison.OrdinalIgnoreCase))
        {
            msg = text.Substring(3).Trim();
            if (msg.Length == 0) return false;
            SendChatToTeam(CsTeam.CounterTerrorist,T(player, "sz_chat.prefix") + " " +  T(player,"sz_chat.admin_say",player.PlayerName,Colors($"{msg}")));
            return true;
        }
        if (isAdmin && text.StartsWith("t ", StringComparison.OrdinalIgnoreCase) || text.StartsWith("tt ", StringComparison.OrdinalIgnoreCase) || text.StartsWith("ts ", StringComparison.OrdinalIgnoreCase))
        {
            msg = text.Substring(2).Trim();
            if (msg.Length == 0) return false;
            SendChatToTeam(CsTeam.Terrorist, T(player, "sz_chat.prefix") + " " + T(player,"sz_chat.admin_say",player.PlayerName,Colors($"{msg}")));
            return true;
        }

        var who = text.Substring(0, firstSpace).Trim();
        msg     = text.Substring(firstSpace + 1).Trim();
        if (msg.Length == 0) return false;

        if (who.Equals("all", StringComparison.OrdinalIgnoreCase))
        {
            SendChatToAdmin(T(player, "sz_chat.prefix") + " " + T(player,local,player.PlayerName,Colors(msg)));
            _ = DiscordWebhooks.LogAdminCommand(
                                                    Instance!.Config,
                                                    player,
                                                    "@",
                                                    Colors(msg),
                                                    isAdmin
                                                );
            return true;
        }

        // player
        if (!isAdmin) return false;
        var target = FindTarget(who);
        if (target != null && target.IsValid && !target.IsBot)
        {
            SendPrivateChat(target, T(player, "sz_chat.prefix") + " " +  T(player,"sz_chat.admin_say",player.PlayerName,Colors($"{msg}")));
            return true;
        } else {
            privateChat(player, "sz_chat.target_notfound",who);
        }

        return false;
    }

    public static IEnumerable<CCSPlayerController> GetPlayersList()
    {
        return Utilities.GetPlayers().Where(p => p?.IsValid == true && !p.IsBot).ToList();
    }

    public static void SendPrivateChat(CCSPlayerController player, string message)
    {
        player.PrintToChat(message);
    }

    public static void SendChatToAll(string message)
    {
        var players = GetPlayersList();

        foreach (var player in players)
            player.PrintToChat(message);

    }

    public static void SendHTMLToAll(string message, bool ads = false)
    {
        if (_centerHTML != null) return;

        var players = GetPlayersList();

        int ticks = 2;
        float interval = ticks / 64f;
        int repeats = (int)Math.Ceiling(5 / interval);
        int count = 0;

        _centerHTML = Instance?.AddTickTimer(ticks, () =>
        {
            if (++count > repeats)
            {
                _centerHTML?.Kill();
                _centerHTML = null;
                return;
            }

            foreach (var player in players)
            {
                if (player?.IsValid == true)
                {
                    if (ads == true)
                        message = SourceBans.DecodeAd(message, player);
                    player.PrintToCenterHtml(message,5);
                }
            }

        }, TimerFlags.REPEAT | TimerFlags.STOP_ON_MAPCHANGE);
    }


    public static void SendPrivateHTML(CCSPlayerController player, string message, float duration = 5.0f)
    {
        int ticks = 2;
        float interval = ticks / 64f;
        int repeats = (int)Math.Ceiling(duration / interval);
        int count = 0;

        if (_centerHTML != null)
        {
            _centerHTML?.Kill();
            _centerHTML = null;
        }

        Instance!._menuManager.DestroyMenu(player);

        _centerHTML = Instance?.AddTickTimer(ticks, () =>
        {
            if (++count > repeats)
            {
                _centerHTML?.Kill();
                _centerHTML = null;
                return;
            }

            if (player?.IsValid == true && !player.IsBot)
                    player.PrintToCenterHtml(message,5);

        }, TimerFlags.REPEAT | TimerFlags.STOP_ON_MAPCHANGE);

    }

    public static void SendChatToAdmin(string message)
    {
        var players = GetPlayersList();

        foreach (var player in players)
        {
            if (!SourceBans._userCache.TryGetValue(player.SteamID, out var userData) || !userData.IsAdmin) continue;
            player.PrintToChat(message);
        }
    }

    public static void SendChatToTeam(CsTeam team, string message)
    {
        var players = GetPlayersList();

        foreach (var player in players)
        {
            if (player.Team == team)
                player.PrintToChat(message);
        }
    }

    public void BroadcastCenterMessage(string message, int duration = 5)
    {
        string messageHTML = message.Replace("HLstatsZ","<font color='#FFFFFF'>HLstats</font><font color='#FF2A2A'>Z</font>");
        string htmlContent = $"<font color='#FFFFFF'>{messageHTML}</font>";
        SendHTMLToAll(htmlContent);
    }

    public static void ShowHintMessage(CCSPlayerController player, string message)
    {
        player.PrintToCenter(message);
    }

    public static void SendWelcome(CCSPlayerController player)
    {
        if (Instance!.Config.Welcomes == null || player.IsBot)
            return;

        var entries = Instance!.Config.Welcomes?
            .Where(e => !string.IsNullOrWhiteSpace(e.Welcome))
            .ToList();
        if (entries == null || entries.Count == 0)
            return;

        var entry = entries[Random.Shared.Next(entries.Count)];

        new GameTimer(MathF.Max(0.01f,entry.Delay), () =>
        {
            string msg = SourceBans.DecodeAd(entry.Welcome, player);

            if (entry.PrintType == "html")
            {
                SendPrivateHTML(player, CenterColors(msg),5.0f);
            }
            else
            {
                if (player.IsValid == true && !player.IsBot)
                    player.PrintToChat(Colors(msg));
            }
        });

    }

    public static string DeathVariables(string msg, CCSPlayerController victim, CCSPlayerController? killer, string weapon, bool headshot)
    {
        if (victim == null || victim.IsValid != true)
            return msg;
    
        string victimName = victim.PlayerName ?? "Unknown";
        string killerName = (killer?.IsValid == true) ? killer.PlayerName : "World";
    
        msg = msg.Replace("{victim}", victimName);
        msg = msg.Replace("{killer}", killerName);
        msg = msg.Replace("{weapon}", weapon);
        msg = msg.Replace("{headshot}", headshot ? "Yes" : "No");
    
        return msg;
    }


    public static void SendDeathMsg(CCSPlayerController victim, CCSPlayerController? killer, EventPlayerDeath ev)
    {
        var entries = Instance!.Config.PlayerDeath?
            .Where(e => !string.IsNullOrWhiteSpace(e.Message))
            .ToList();

        if (entries == null || entries.Count == 0)
            return;

        var entry = entries[Random.Shared.Next(entries.Count)];

        string safeWeapon = ev?.Weapon ?? "unknown";
        bool safeHeadshot = ev?.Headshot == true;

        new GameTimer(0.01f, () =>
        {
            if (victim?.IsValid != true)
                return;

            string msg = DeathVariables(entry.Message, victim, killer, safeWeapon, safeHeadshot);
            msg = SourceBans.DecodeAd(msg, victim);

            if (entry.PrintType.Equals("html", StringComparison.OrdinalIgnoreCase))
                SendPrivateHTML(victim, CenterColors(msg), entry.Duration);
            else
                victim.PrintToChat(Colors(msg));
        });
    }

    private HookResult ComamndListenerHandler(CCSPlayerController? player, CommandInfo info)
    {
        if (player == null || !player.IsValid)
            return HookResult.Continue;

        if (!SourceBans._userCache.TryGetValue(player.SteamID, out var userData))
            return HookResult.Continue;

        // ----- Handle Kick/Ban -----
        if ((userData.Ban & (BanType.Banip | BanType.Ban | BanType.Kick))!=0)
            return HookResult.Handled;

        bool MenuIsOpen = _menuManager._activeMenus.ContainsKey(player.SteamID);
        var command = info.ArgByIndex(0).ToLower().Trim();

        if (MenuIsOpen && command == "single_player_pause")
            Instance!._menuManager.DestroyMenu(player);

        if (!command.StartsWith("say") && !command.StartsWith("!"))
            return HookResult.Continue;

        var raw = info.ArgCount == 1 ? info.GetArg(0) :
                  info.ArgCount == 2 ? info.GetArg(1) :
                  info.ArgCount > 2 ? info.GetCommandString : string.Empty;

        raw = raw.Trim();
        if (raw.Length >= 2 && raw[0] == '"' && raw[^1] == '"')
            raw = raw.Substring(1, raw.Length - 2);

        bool silenced = raw.StartsWith("/");
        bool prefixed = raw.StartsWith("!") || silenced;
        string text = prefixed ? raw.Substring(1) : raw;

        if (raw.StartsWith("@", StringComparison.Ordinal))
        {
            if (HandleAtCommand(player, raw, userData.IsAdmin) || userData.IsAdmin)
                return HookResult.Handled;

            return HookResult.Continue;
        }

        var parts = text.Split(' ', 4, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return HookResult.Continue;

        var cmd = parts[0].ToLowerInvariant();

        bool votekick = (SourceBans.VoteKick == "public" || (SourceBans.VoteKick == "admin" && userData.IsAdmin));
        bool votemap  = (SourceBans.VoteMap == "public"  || (SourceBans.VoteMap == "admin" && userData.IsAdmin));

        // ----- HLstatsZ -> Daemon -----
        if (silenced && parts.Length == 1)
        {
            switch (cmd)
            {
                case "rank":
                case "next":
                case "top10":
                case "top20":
                case "top30":
                case "session":
                SendLog(player, cmd, "say");
                return HookResult.Handled;
                default:
                break;
            }
        }

        // ----- Handle Gag -----
        if ((userData.Ban & BanType.Gag)!=0)
            return HookResult.Handled;

        // ---- Handle Menu Command ----
        if ((cmd == "menu" || cmd == "hlx_menu") && parts.Length == 1)
        {
            if (MenuIsOpen)
                Instance!._menuManager.DestroyMenu(player);

            var builder = new HLZMenuBuilder("Main Menu");
            if (HLstatsZ._enabled)
            {
                builder.Add("Rank", p => SendLog(p, "rank", "say"));
                builder.Add("Next Rank", p => SendLog(p, "next", "say"));
                builder.Add("TOP 10", p => SendLog(p, "top10", "say"));
            }
            if ((SourceBans._enabled && votekick) || votemap)
                builder.Add(T(player,"sz_menu.vote"), p => VoteMenu(p));

            if (userData.IsAdmin)
                builder.Add(T(player,"sz_menu.admin"), p => AdminMenu(p));

            builder.Open(player, Instance!._menuManager);

            return HookResult.Handled;
        }

        // ----- Public Commands -----
        if (!prefixed) return HookResult.Continue;

        switch (cmd)
        {
            case "next":
            case "nextmap":
            if (string.IsNullOrWhiteSpace(SourceBans.NextMap))
            {
                privateChat(player, "sz_chat.nominate_none");
                return HookResult.Handled;
            }
            if ((SourceBans._userNominate.ContainsKey(player.SteamID) && SourceBans._userNominate[player.SteamID] == SourceBans.NextMap) || userData.IsAdmin)
            {
                AdminAction(player, "next", player, SourceBans.NextMap, null);
            } else {
                privateChat(player, "sz_chat.permission");
            }
            return HookResult.Handled;
            case "rtv":
            case "votemap":
                if (!votemap)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Continue;
                }
                if (SourceBans._mVote > 1 || !string.IsNullOrWhiteSpace(SourceBans.NextMap))
                {
                    privateChat(player, "sz_chat.vote_map_enough");
                    return HookResult.Handled;
                }
                if (SourceBans._vote.ContainsKey("map") || SourceBans._vote.ContainsKey("kick"))
                {
                    privateChat(player,"sz_chat.vote_inprogress");
                    return HookResult.Handled;
                }
                if (!SourceBans._canVote)
                {
                    privateChat(player, "sz_chat.vote_map_early");
                    return HookResult.Continue;
                }
                if (cmd == "rtv")
                {
                    AdminAction(player, cmd, player, null, null);
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    VoteMap(player,"vote");
                    return HookResult.Handled;
                }
                var map = string.Join(' ', parts.Skip(1)).Trim();
                AdminAction(player, cmd, player, map, null);
            return HookResult.Handled;
            case "votekick":
                if (!SourceBans._enabled)
                    return HookResult.Continue;
                if (!votekick)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Continue;
                }
                if (SourceBans._vote.ContainsKey("map") || SourceBans._vote.ContainsKey("kick"))
                {
                    privateChat(player,"sz_chat.vote_inprogress");
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    VotePlayer(player);
                    return HookResult.Handled;
                }
                var who    = parts.Length > 1 ? parts[1].Trim() : "";
                var reason = parts.Length > 2 ? string.Join(' ', parts.Skip(2)).Trim() : "";

                if (string.IsNullOrWhiteSpace(who) || string.IsNullOrWhiteSpace(reason)) 
                {
                    privateChat(player, "sz_chat.generic_usage",cmd);
                    return HookResult.Handled;
                }
                if (reason.Length < 3)
                {
                    privateChat(player, "sz_chat.short_reason");
                    return HookResult.Handled;
                }
                var target = FindTarget(who);
                if (target != null)
                {
                    AdminAction(player, "votekick", target, reason, null);
                }
                else
                {
                    privateChat(player, "sz_chat.target_notfound",who);
                }
            return HookResult.Handled;
            case "nominate":
                if (!SourceBans.Nominate)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Continue;
                }
                if (!SourceBans._canVote)
                {
                    privateChat(player, "sz_chat.vote_map_early");
                    return HookResult.Continue;
                }
                if (SourceBans._userNominate.ContainsKey(player.SteamID))
                {
                    privateChat(player, "sz_chat.nominate_already");
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    VoteMap(player, "nominate");
                    return HookResult.Handled;
                }
                var mapNom = string.Join(' ', parts.Skip(1)).Trim();
                AdminAction(player, cmd, player, mapNom, null);
            return HookResult.Handled;
        }

        // ----- SourceBans -----
        if (!SourceBans._enabled)
            return HookResult.Continue;

        // ---- Handle Admin command ----
        var adminFlags = userData.Flags.ToFlags();

        switch (cmd)
        {
            case "say":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                var reason = parts.Length > 1 ? string.Join(' ', parts.Skip(1)).Trim() : "";
                if (!string.IsNullOrWhiteSpace(reason))
                {
                    SendChatToAll(T(player,"sz_chat.admin_say",player.PlayerName,Colors($"{reason}")));
                    return HookResult.Handled;
                }
            return HookResult.Continue;

            case "hsay":
            case "psay":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (parts.Length < 2) 
                {
                    privateChat(player, "sz_chat.generic_usage",cmd);
                    return HookResult.Handled;
                }
                var who = parts.Length > 1 ? parts[1].Trim() : "";
                reason  = parts.Length > 2 ? string.Join(' ', parts.Skip(2)).Trim() : "";
                if (string.IsNullOrWhiteSpace(reason))
                {
                    privateChat(player, "sz_chat.generic_usage", cmd);
                    return HookResult.Handled;
                }
                var target = FindTarget(who);
                if (target != null)
                {
                   if (cmd == "psay")
                       SendPrivateChat(target, T(player,"sz_chat.admin_say",player.PlayerName,Colors($"{reason}")));
                   else ShowHintMessage(player, T(player,"sz_chat.admin_say",player.PlayerName,Colors($"{reason}")));
                }
                else
                {
                    privateChat(player, "sz_chat.target_notfound", who);
                }
            return HookResult.Handled;

            case "admin":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    AdminMenu(player);
                    return HookResult.Handled;
                }
            return HookResult.Continue;

            case "kick":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (!adminFlags.Has(AdminFlags.Root | AdminFlags.Kick))
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    AdminPlayer(player);
                    return HookResult.Handled;
                }
                if (parts.Length < 3) 
                {
                    privateChat(player, "sz_chat.generic_usage", cmd);
                    return HookResult.Handled;
                }
                who    = parts.Length > 1 ? parts[1].Trim() : "";
                reason = parts.Length > 2 ? string.Join(' ', parts.Skip(2)).Trim() : "";
                if (reason.Length < 3)
                {
                    privateChat(player, "sz_chat.short_reason");
                    return HookResult.Handled;
                }
                target = FindTarget(who);
                if (target != null)
                {
                    AdminAction(player, "kick", target, reason, null);
                }
                else
                {
                    privateChat(player, "sz_chat.target_notfound", who);
                }
            return HookResult.Handled;

            case "map":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (!adminFlags.Has(AdminFlags.Root | AdminFlags.Map))
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    MapMenu(player);
                    return HookResult.Handled;
                }
                var map = string.Join(' ', parts.Skip(1)).Trim();
                AdminAction(player, cmd, player, map, null);
            return HookResult.Handled;

            case "ban":
            case "banip":
            case "gag":
            case "mute":
            case "silence":
            case "slay":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if ((cmd == "ban" && !adminFlags.Has(AdminFlags.Root | AdminFlags.Ban)) ||
                    (cmd == "banip" && !adminFlags.Has(AdminFlags.Root | AdminFlags.BanIp)) ||
                    (cmd == "slay" && !adminFlags.Has(AdminFlags.Root | AdminFlags.Slay)))
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                who = parts.Length > 1 ? parts[1].Trim() : "";
                target = FindTarget(who);
                if (target == null || !target.IsValid)
                {
                    privateChat(player, "sz_chat.target_notfound", who);
                    return HookResult.Handled;
                }
                var duration = parts.Length > 2 ? parts[2].Trim() : "1";
                reason  = parts.Length > 3 ? string.Join(' ', parts.Skip(3)).Trim() : "";
                if (cmd == "slay")
                {
                    if (parts.Length == 1)
                    {
                        privateChat(player, "sz_chat.generic_usage", cmd);
                        return HookResult.Handled;
                    }
                    reason = parts.Length > 2 ? string.Join(' ', parts.Skip(2)).Trim() : "";
                    AdminAction(player, "slay", target, reason, null, 0);
                    return HookResult.Handled;
                }
                if (parts.Length < 3 || !(int.TryParse(duration, out int min) && min >= 0)) 
                {
                    privateChat(player, "sz_chat.banning_usage", cmd);
                    return HookResult.Handled;
                }
                if (min > SourceBans.Durations[0]) 
                {
                    privateChat(player, "sz_chat.ban_exceeds", cmd, min);
                    return HookResult.Handled;
                }
                if (!adminFlags.Has(AdminFlags.Root | AdminFlags.BanPerm) && min == 0)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (reason.Length < 3)
                {
                    privateChat(player, "sz_chat.short_reason");
                    return HookResult.Handled;
                }
                AdminAction(player, cmd, target, reason, null, int.Parse(duration)*60);
            return HookResult.Handled;

            case "unban":
            case "ungag":
            case "unmute":
            case "unsilence":
                if (!userData.IsAdmin || !adminFlags.Has(AdminFlags.Root | AdminFlags.Unban))
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                reason  = parts.Length > 2 ? string.Join(' ', parts.Skip(2)).Trim() : "";
                if (parts.Length < 3) 
                {
                    privateChat(player, "sz_chat.generic_usage", cmd);
                    return HookResult.Handled;
                }
                if (reason.Length < 3)
                {
                    privateChat(player, "sz_chat.short_reason");
                    return HookResult.Handled;
                }
                who    = parts.Length > 1 ? parts[1].Trim() : "";
                target = FindTarget(who);
                if (target == null)
                {
                    ulong target64 = FindTargetCached(who);
                    if (target64 == 0)
                    {
                        privateChat(player, "sz_chat.target_notfound", who);
                        return HookResult.Handled;
                    } else {
                        AdminAction(player, cmd, null, reason, null, 0, false, target64);
                        return HookResult.Handled;
                    }
                }
                AdminAction(player, cmd, target, reason, null);
            return HookResult.Handled;

            case "give":
                if (!userData.IsAdmin || !adminFlags.Has(AdminFlags.Root | AdminFlags.Cheats))
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    privateChat(player, "sz_chat.generic_usage", cmd);
                    return HookResult.Handled;
                }
                who    = parts.Length > 1 ? parts[1].Trim() : "";
                target = FindTarget(who);
                if (target == null)
                {
                    privateChat(player, "sz_chat.target_notfound", who);
                    return HookResult.Handled;
                }
                AdminAction(player, cmd, target, parts[2].Trim(), null);
            return HookResult.Handled;
            case "rename":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (parts.Length == 1)
                {
                    privateChat(player, "sz_chat.generic_usage", cmd);
                    return HookResult.Handled;
                }
                who    = parts.Length > 1 ? parts[1].Trim() : "";
                target = FindTarget(who);
                if (target == null)
                {
                    privateChat(player, "sz_chat.target_notfound", who);
                    return HookResult.Handled;
                }
                AdminAction(player, cmd, target, parts[2].Trim(), null);
            return HookResult.Handled;
            case "team":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if (parts.Length < 3)
                {
                    privateChat(player, "sz_chat.team_usage", cmd);
                    return HookResult.Handled;
                }
                var name = parts[2].ToLowerInvariant();
                var team  = 0;
                switch (name)
                {
                    case "1":
                    case "s":
                    case "spec":
                    case "spectator":
                        team = 1;
                        name = "Spectator";
                    break;
                    case "2":
                    case "t":
                    case "tt":
                    case "terrorist":
                        team = 2;
                        name = "Terrorist";
                    break;
                    case "3":
                    case "ct":
                    case "counter-terrorist":
                    case "counterterrorist":
                        team = 3;
                        name = "Counter-Terrorist";
                    break;
                    default:
                        privateChat(player, "sz_chat.team_usage", cmd);
                    return HookResult.Handled;
                }
                who    = parts[1].Trim();
                target = FindTarget(who);
                if (target != null && target.IsValid)
                {
                    AdminAction(player,cmd,target,name,null,team);
                } else {
                    privateChat(player, "sz_chat.target_notfound", who);
                }
            return HookResult.Handled;

            case "players":
            case "camera":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                SourceBans.CameraCommand(player, null, cmd == "camera" ? 1 : 0);
            return HookResult.Handled;

            case "refresh":
                if (!userData.IsAdmin)
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                if(!adminFlags.Has(AdminFlags.Root | AdminFlags.Config))
                {
                    privateChat(player, "sz_chat.permission");
                    return HookResult.Handled;
                }
                _ = SourceBans.Refresh();
            return HookResult.Handled;

            default:
            return HookResult.Continue;
        }
    }

    // --------------------- Console ---------------------
    [ConsoleCommand("hlx_sm_psay")]
    public void OnHlxSmPsayCommand(CCSPlayerController? _, CommandInfo command)
    {
        if (command.ArgCount < 2) return; // hlx_sm_psay "1" 1 "message"

        var arg = command.ArgByIndex(1);
        var message = command.ArgByIndex(command.ArgCount - 1);

        string[] privateOnlyPatterns =
        {
            "kills to get regular points",
            "You have been banned"
        };
        bool isPrivateOnly = privateOnlyPatterns.Any(p => message?.IndexOf(p, StringComparison.OrdinalIgnoreCase) >= 0);
        // Broadcast to all
        if (Config.BroadcastAll == 1 && !isPrivateOnly)
        {
            var hash = $"ALL:{message}";
            if (_lastPsayHash == hash) return;

            _lastPsayHash = hash;
            SendChatToAll(HLZ_Prefix + message);
            return;
        }

        // users?
        var userIds = new List<int>();
        foreach (var idStr in arg.Split(','))
        {
            if (int.TryParse(idStr, out var id)) userIds.Add(id);
        }

        // Broadcast to user
        foreach (var userid in userIds)
        {
            var target = FindTarget(userid);
            if (target == null || !target.IsValid) continue;

            var hash = $"{userid}:{message}";
            if (_lastPsayHash == hash) continue;
            _lastPsayHash = hash;
            SendPrivateChat(target, HLZ_Prefix + message);
        }
    }

    [ConsoleCommand("hlx_sm_csay")]
    public void OnHlxSmCsayCommand(CCSPlayerController? _, CommandInfo command)
    {
        var message = command.ArgByIndex(1);
        Instance?.BroadcastCenterMessage(message);
    }

    [ConsoleCommand("hlx_sm_hint")]
    public void OnHlxSmHintCommand(CCSPlayerController? _, CommandInfo command)
    {
        if (!int.TryParse(command.ArgByIndex(1), out var userid)) return;

        var message = command.ArgByIndex(command.ArgCount - 1);
        var target  = FindTarget(userid);
        if (target == null || !target.IsValid) return;
        ShowHintMessage(target, message);
    }

    [ConsoleCommand("hlx_sm_msay")]
    public void OnHlxSmMsayCommand(CCSPlayerController? _, CommandInfo command)
    {
        if (!int.TryParse(command.ArgByIndex(2), out var userid)) return;

        var message = command.ArgByIndex(command.ArgCount - 1);
        var target  = FindTarget(userid);
        if (target == null || !target.IsValid) return;
        _menuManager.Open(target,message);
    }

    [ConsoleCommand("kick")]
    [ConsoleCommand("slay")]
    [ConsoleCommand("camera")]
    [ConsoleCommand("refresh")]
    [ConsoleCommand("players")]
    [ConsoleCommand("team")]
    [ConsoleCommand("ban")]
    [ConsoleCommand("banip")]
    [ConsoleCommand("gag")]
    [ConsoleCommand("mute")]
    [ConsoleCommand("silence")]
    [ConsoleCommand("ungag")]
    [ConsoleCommand("unmute")]
    [ConsoleCommand("unsilence")]
    [ConsoleCommand("unban")]
    [ConsoleCommand("rename")]
    [ConsoleCommand("sm_rehash")]   // sent by the SourceBans web panel after admin and group changes
    public void OnCssCommand(CCSPlayerController? player, CommandInfo command)
    {
        if (player != null) return;

        var cmdLine = command.GetCommandString; 
        var parts   = cmdLine.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        var cmd = parts[0].ToLowerInvariant();

        CCSPlayerController? target = null;
        ulong target64 = 0;
        int number = -1;
        string? args = null;

        string? who = parts.Length > 1 ? parts[1].Trim() : null;

        if (!string.IsNullOrEmpty(who))
        {

            target = FindTarget(who);
            if (target == null)
            {
                target64 = FindTargetCached(who);
                if (target64 == 0 || !cmd.StartsWith("un")) // only online but can unban offline
                {
                    command.ReplyToCommand(T("sz_chat.target_notfound",who));
                    return;
                }
            }
        }
        if (parts.Length > 2)
        {
            var tail = parts[2].Trim();
            var tailParts = tail.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);

            if (tailParts.Length > 0 && int.TryParse(tailParts[0], out int min) && min >= 0)
            {
                number = min * 60;
                args = tailParts.Length > 1 ? tailParts[1] : string.Empty;
            } else {
                args = tail; // no duration, only reason
            }
            if (string.IsNullOrWhiteSpace(args) || args.Length < 3)
            {
                command.ReplyToCommand(T("sz_chat.short_reason"));
                return;
            }
        }
        if ( cmd == "camera" || cmd == "players")
        {
            SourceBans.CameraCommand(null, command, cmd == "camera" ? 1 : 0);
        } else if (cmd == "refresh" || cmd == "sm_rehash") {
            _ = SourceBans.Refresh();
            command.ReplyToCommand(T("sz_console.refresh"));
        } else {
            AdminAction(null, cmd, target, args, command, number, true, target64);
        }
    }

    // SourceComms commands the SourceBans web panel sends by RCON when it blocks a player, or lifts a block:
    //   sc_fw_block <1 mute | 2 gag | 3 both> <minutes, 0 = permanent> <steamid>
    //   sc_fw_unmute <steamid>, sc_fw_ungag <steamid>
    [ConsoleCommand("sc_fw_block")]
    [ConsoleCommand("sc_fw_unmute")]
    [ConsoleCommand("sc_fw_ungag")]
    public void OnSourceCommsCommand(CCSPlayerController? player, CommandInfo command)
    {
        if (player != null) return;

        var parts = command.GetCommandString.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var cmd   = parts[0].ToLowerInvariant();
        bool block = cmd == "sc_fw_block";
        if (parts.Length < (block ? 4 : 2)) return;

        ulong sid64 = SourceBans.ToSteam64(parts[block ? 3 : 1].Trim('"'));
        var target  = Utilities.GetPlayers().FirstOrDefault(p => p?.IsValid == true && !p.IsBot && p.SteamID == sid64);
        if (sid64 == 0 || target == null || !SourceBans._userCache.ContainsKey(sid64)) return;

        if (block)
        {
            if (!int.TryParse(parts[1], out var kind) || !int.TryParse(parts[2], out var minutes)) return;
            var type = kind == 1 ? BanType.Mute : kind == 2 ? BanType.Gag : kind == 3 ? BanType.Silence : BanType.None;
            if (type == BanType.None) return;

            SourceBans.UpdateBanUser(sid64, type, minutes > 0 ? minutes * 60 : int.MaxValue, false, 0);
            var remain = minutes > 0 ? SourceBans.FormatTimeLeft(target, TimeSpan.FromMinutes(minutes)) + " remaining" : T(target, "sz_menu.permanently");
            if ((type & BanType.Mute) != 0)
            {
                target.VoiceFlags = VoiceFlags.Muted;
                privateChat(target, "sz_chat.join_muted", target.PlayerName, remain);
            }
            if ((type & BanType.Gag) != 0)
                privateChat(target, "sz_chat.join_gagged", target.PlayerName, remain);
        }
        else if (cmd == "sc_fw_unmute")
        {
            SourceBans.UpdateBanUser(sid64, BanType.Mute, 0, true, 0);
            target.VoiceFlags = VoiceFlags.Normal;
            privateChat(target, "sz_chat.unmuted");
        }
        else
        {
            SourceBans.UpdateBanUser(sid64, BanType.Gag, 0, true, 0);
            privateChat(target, "sz_chat.ungagged");
        }
        command.ReplyToCommand($"[HLstatsZ] {cmd}: {target.PlayerName}");
    }

    [ConsoleCommand("hlx_sm_swap")]
    public void OnHlxSmSwapCommand(CCSPlayerController? _, CommandInfo command)
    {
        if (!int.TryParse(command.ArgByIndex(1), out var userid)) return;
        var target  = FindTarget(userid);
        if (target == null || !target.IsValid) return;
        target.ChangeTeam((CsTeam)target.TeamNum == CsTeam.Terrorist ? CsTeam.CounterTerrorist : CsTeam.Terrorist);
    }

    public static void AdminMenu(CCSPlayerController player)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid)
            return;

        SourceBans._userCache.TryGetValue(player.SteamID, out var userData);
        var adminFlags = userData.Flags.ToFlags();

        var builder = new HLZMenuBuilder("Admin Menu")
                     .Add(T(player,"sz_menu.players"), _ => AdminPlayer(player))
                     .Add(T(player,"sz_menu.remove_ban"), _ => AdminPlayer(player,1));

        if (adminFlags.Has(AdminFlags.Root | AdminFlags.Map))
            builder.Add(T(player,"sz_menu.map_change"), _ => MapMenu(player));

        builder.Add(T(player,"sz_menu.history"), _ => AdminHistory(player));

        builder.Open(player, Instance!._menuManager);

    }

    public static void VoteMenu(CCSPlayerController player)
    {
        if (player == null || !player.IsValid) return;

        SourceBans._userCache.TryGetValue(player.SteamID, out var userData);
        bool votekick = (SourceBans.VoteKick == "public" || (SourceBans.VoteKick == "admin" && userData.IsAdmin)) && SourceBans._enabled;
        bool votemap = (SourceBans.VoteMap == "public" || (SourceBans.VoteMap == "admin" && userData.IsAdmin));

        var builder = new HLZMenuBuilder("Vote Menu");
        if (!SourceBans._vote.ContainsKey("kick") && !SourceBans._vote.ContainsKey("map") && votekick)
        {
            builder.Add(T(player,"sz_menu.player_kick"), _ => VotePlayer(player));
        } else {
            if (votekick)
                builder.AddNoOp(T(player,"sz_menu.player_kick"));
        }
        if (SourceBans.Nominate && !SourceBans._userNominate.ContainsKey(player.SteamID) && SourceBans._canVote)
        {
            builder.Add("Nominate", _ => VoteMap(player, "nominate"));
        } else {
            if (SourceBans.Nominate)
                builder.AddNoOp("Nominate");
        }

        if (!SourceBans._vote.ContainsKey("kick") && !SourceBans._vote.ContainsKey("map") && SourceBans._canVote && SourceBans._mVote < 2 && votemap)
        {
            builder.Add(T(player,"sz_menu.map_change"), _ => VoteMap(player, "vote"));
        } else {
            if (votemap)
                builder.AddNoOp(T(player,"sz_menu.map_change"));
        }
        if (!SourceBans._vote.ContainsKey("kick") && !SourceBans._vote.ContainsKey("map") && SourceBans._canVote && SourceBans._mVote < 2 && votemap)
        {
            builder.Add(T(player,"sz_menu.map_rtv"), _ => AdminConfirm(player,player,"rtv"));
        } else {
            if (votemap)
                builder.AddNoOp(T(player,"sz_menu.map_rtv"));
        }
        builder.Add(T(player,"sz_menu.active_vote"), _ => VoteActive("check",player,null,null));

        builder.Open(player, Instance!._menuManager);
    }

    public static void VotePlayer(CCSPlayerController player)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid) return;

        var name = "";
        var builder = new HLZMenuBuilder("Vote Kick");
        foreach (var target in Utilities.GetPlayers())
        {
            name = Instance?.Trunc(target.PlayerName, 20);
            builder.Add($"{name}", _ => AdminConfirm(player, target, "votekick"));
        }

        builder.Open(player, Instance!._menuManager);
    }

    public static void VoteMap(CCSPlayerController player, string type)
    {
        if (player == null || !player.IsValid)
            return;

        var title = type == "vote"? "Vote Map" : "Nominate";
        var action = type == "vote"? "votemap" : "nominate";

        var maps = SourceBans.GetAvailableMaps(Instance!.Config, false);

        var builder = new HLZMenuBuilder($"{title}");
        foreach (var entry in maps)
        {
            string label = entry.IsSteamWorkshop ? $"[WS] {entry.DisplayName}" : entry.DisplayName;
            builder.Add(label, _ => AdminConfirm(player, player, $"{action} 1 {entry.DisplayName}"));
        }

        builder.Open(player, Instance!._menuManager);
    }

    public static void AddVote(string type, CCSPlayerController player, bool yes, string? mapName = null, int? choiceIndex = null)
    {
        if (!SourceBans._vote.ContainsKey(type))
        {
            Instance!._menuManager.DestroyMenu(player);
            return;
        }

        if (!SourceBans._userVote.ContainsKey(type))
            SourceBans._userVote[type] = new();

        var vote = SourceBans._vote[type];
        var userVotes = SourceBans._userVote[type];
        ulong sid = player.SteamID;
        bool isRtv = SourceBans._rtv.Count > 0;

        if (isRtv)
        {
            if (choiceIndex == null || choiceIndex < 0 || choiceIndex >= SourceBans._rtv.Count)
            {
                player.PrintToChat("[HLstats\x07Z\x01] Invalid map choice");
                return;
            }
            userVotes[sid] = choiceIndex.Value;
            vote.MapName = SourceBans._rtv[choiceIndex.Value].MapName;
        }
        else
        {
            if (userVotes.TryGetValue(sid, out int previous))
            {
                if (previous == 1) vote.YES--;
                else vote.NO--;
            }
    
            userVotes[sid] = yes ? 1 : 0;
            if (yes) vote.YES++;
            else vote.NO++;
        }

        SourceBans._vote[type] = vote;
        Instance!._menuManager.DestroyMenu(player);
    }

    public static void VoteActive(string type, CCSPlayerController player, CCSPlayerController? target, string? mapname)
    {
        if (player == null || !player.IsValid)
            return;
        string title = type == "check" ? "Vote Menu" : "Cast Vote";
        var builder = new HLZMenuBuilder(title).NoNumber();

        if (type == "kick" || (SourceBans._vote.ContainsKey("kick") && type == "check"))
            BuildVoteKickMenu(builder, player, target);

        if (type == "map" || (SourceBans._vote.ContainsKey("map") && type == "check" && SourceBans._rtv.Count == 0))
            BuildVoteMapMenu(builder, player, mapname);

        if (type == "rtv" || (SourceBans._vote.ContainsKey("map") && type == "check" && SourceBans._rtv.Count > 0))
            BuildVoteRtvMenu(builder, player);

        if (!SourceBans._vote.ContainsKey("kick") && !SourceBans._vote.ContainsKey("map"))
            builder.AddNoOp(T(player,"sz_menu.no_active_vote"));

        if (type != "check")
             Instance!._menuManager.DestroyMenu(player);

        builder.Open(player, Instance!._menuManager);
    }

    private static void BuildVoteKickMenu(HLZMenuBuilder builder, CCSPlayerController player, CCSPlayerController? target)
    {
        string playerName = SourceBans._vote.TryGetValue("kick", out var vote) ? vote.target?.PlayerName ?? "?" : target?.PlayerName ?? "?";

        builder.AddNoOp(T(player,"sz_menu.vote_kick",playerName));
        builder.Add(T(player,"sz_menu.vote_yes"), _ => AddVote("kick", player, true));
        builder.Add(T(player,"sz_menu.vote_no"), _ => AddVote("kick", player, false));

        if (SourceBans._vote.TryGetValue("kick", out var result))
            builder.AddNoOp(T(player,"sz_menu.vote_result",result.YES, result.NO));
    }

    private static void BuildVoteMapMenu(HLZMenuBuilder builder, CCSPlayerController player, string? mapname)
    {
        string displayMap = SourceBans._vote.TryGetValue("map", out var vote) ? vote.MapName ?? mapname ?? "?" : mapname ?? "?";

        builder.AddNoOp(T(player,"sz_menu.vote_map", Instance!.Trunc(displayMap,16)));
        builder.Add(T(player,"sz_menu.vote_yes"), _ => AddVote("map", player, true));
        builder.Add(T(player,"sz_menu.vote_no"), _ => AddVote("map", player, false));

        if (SourceBans._vote.TryGetValue("map", out var result))
            builder.AddNoOp(T(player,"sz_menu.vote_result",result.YES, result.NO));
    }

    private static void BuildVoteRtvMenu(HLZMenuBuilder builder, CCSPlayerController player)
    {
        if (!SourceBans._userVote.TryGetValue("map", out var userVotes))
        {
            SourceBans._userVote["map"] = new();
            userVotes = SourceBans._userVote["map"];
        }

        var tally = userVotes.Values
                             .GroupBy(c => c)
                             .ToDictionary(g => g.Key, g => g.Count());

        var nominatedSet = new HashSet<string>(
            SourceBans._userNominate.Values.Select(v => v.ToLowerInvariant())
        );

        for (int i = 0; i < SourceBans._rtv.Count; i++)
        {
            int choiceIndex = i;
            var mapEntry = SourceBans._rtv[choiceIndex];

            int count = tally.TryGetValue(i, out var c) ? c : 0;

            bool isNominated = nominatedSet.Contains(mapEntry.DisplayName.ToLowerInvariant()) ||
                               nominatedSet.Contains(mapEntry.MapName.ToLowerInvariant()) ||
                               (mapEntry.WorkshopId != null && nominatedSet.Contains(mapEntry.WorkshopId.ToLowerInvariant()));

            string prefix  = mapEntry.IsSteamWorkshop ? "[WS]" : "";
            string nomTag  = isNominated ? "[NOM]" : "";
            string mapName = Instance!.Trunc(prefix +""+ nomTag +""+ mapEntry.DisplayName, 21);
            string label   = $"{mapName} → {count}";

            builder.Add(label, _ => AddVote("map", player, true, mapEntry.DisplayName, choiceIndex));
        }
    }

    public static void MapMenu(CCSPlayerController player)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid)
            return;
        SourceBans._userCache.TryGetValue(player.SteamID, out var userData);

        var maps = SourceBans.GetAvailableMaps(Instance!.Config, userData.IsAdmin);
        string currentMap = Server.MapName;
        var builder = new HLZMenuBuilder("Map Menu");

        foreach (var entry in maps)
       {
            string label = entry.IsSteamWorkshop ? $"[WS] {entry.DisplayName}" : entry.DisplayName;
            if (string.Equals(entry.DisplayName, currentMap, StringComparison.OrdinalIgnoreCase))
            {
                builder.AddNoOp(Instance!.Trunc(label,16));
            } else {
                builder.Add(Instance!.Trunc(label,16), _ => AdminConfirm(player, player, $"map 1 {entry.DisplayName}"));
            }
        }

        builder.Open(player, Instance!._menuManager);
    }

    public static void AdminPlayer(CCSPlayerController admin, int type = 0)
    {
        if (!SourceBans._enabled || admin == null || !admin.IsValid)
            return;

        var title = type == 0 ? "Players" : "Unban";
        var builder = new HLZMenuBuilder($"{title}").NoNumber();
        var count =0;
        var name = "";
        var label = "";

        switch (type)
        {
            case 0:
                foreach (var target in Utilities.GetPlayers())
                {
                    if (target == null || target?.IsValid != true) continue;
                    SourceBans._userCache.TryGetValue(target.SteamID, out var userData);
                    if ((userData.Ban & (BanType.Kick | BanType.Ban | BanType.Banip))>0 && userData.ExpiryBan > DateTime.UtcNow) continue;
                    name = Instance?.Trunc(target.PlayerName, 20);
                    label = $"#{target.Slot} - {name}";
                    //if (admin != target)
                    builder.Add(label, _ => AdminCMD(admin, target));
                    //else
                      // builder.AddNoOp(label);
                }
            break;
            case 1:
                foreach (var kvp in SourceBans._userCache)
                {
                    var steamId = kvp.Key;
                    var data = kvp.Value;
                    var offline = data.Connected == false ? " (offline)" : "";
                    if (data.Ban == BanType.None) continue;
                    count++;
                    name = Instance?.Trunc(data.PlayerName, 20);
                    label = $"{name}{offline}";
                    builder.Add(label, _ => AdminCMD2(admin, steamId));
                }
            break;
            default: break;

        }
        if (count == 0 && type == 1)
           builder.AddNoOp(T(admin,"sz_menu.noban"));

        builder.Open(admin, Instance!._menuManager);

    }

    public static void AdminCMD(CCSPlayerController player,CCSPlayerController target)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid)
            return;

        var name = Instance?.Trunc(target.PlayerName,10);
        var builder = new HLZMenuBuilder($"{name}");
        SourceBans._userCache.TryGetValue(player.SteamID, out var userData);
        var adminFlags = userData.Flags.ToFlags();

        if (!target.IsBot) {
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Kick | AdminFlags.Ban))
                builder.Add(T(player,"sz_menu.kick_ban"), _ => AdminCMD1(player,target,"Ban"));
            builder.Add(T(player,"sz_menu.gag"), _ => AdminCMD1(player,target,"Gag"));
            builder.Add(T(player,"sz_menu.mute"), _ => AdminCMD1(player,target,"Mute"));
            builder.Add(T(player,"sz_menu.silence"), _ => AdminCMD1(player,target,"Silence"));
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Slay))
                builder.Add(T(player,"sz_menu.slay"), _ => AdminConfirm(player,target,"Slay"));
            if (target.TeamNum > 0)
                builder.Add(T(player,"sz_menu.team"), _ => AdminCMD1(player,target,"team"));
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Cheats))
                builder.Add(T(player,"sz_menu.give_items"), _ => AdminCMDitem(player,target));
        } else {
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Kick | AdminFlags.Ban))
                builder.Add(T(player,"sz_menu.kick"), _ => AdminConfirm(player,target,"kick"));
        }
        builder.Open(player, Instance!._menuManager);

    }

    public static void AdminHistory(CCSPlayerController player)
    {
        var builder = new HLZMenuBuilder("Server");
        foreach (var kvp in SourceBans._userCache)
        {
            var steamId = kvp.Key;
            var data = kvp.Value;
            var name = Instance?.Trunc(data.PlayerName,10);
            builder.Add($"{data.Updated.ToLocalTime():dd HH:mm} - {name}", _ => AdminDetails(player, steamId));
        }
        builder.Open(player, Instance!._menuManager);
    }

    public static void AdminDetails(CCSPlayerController player, ulong SteamId)
    {
        var userData = SourceBans._userCache[SteamId];
        var name = Instance?.Trunc(userData.PlayerName,20);
        var steam2 = SourceBans.ToSteam2(SteamId);
        var status = userData.Connected ? "Online" : "Offline";
        var builder = new HLZMenuBuilder("Details").NoNumber()
                     .AddNoOp($"{name} ({status})")
                     .AddNoOp($"IP: {userData.IP}")
                     .AddNoOp($"Steam64: {SteamId}")
                     .AddNoOp($"Steam2: {steam2}");
        if (SourceBans._userCache[SteamId].IsAdmin)
        {
            var adminFlags = SourceBans._userCache[SteamId].Flags.ToFlags();
            if (adminFlags.Has(AdminFlags.Root))
            {
                builder.AddNoOp("SuperAdmin");
            } else if (adminFlags.Has(AdminFlags.Generic)) {
                var flags = new List<string>();
                flags.Add("Admin");
                if (adminFlags.Has(AdminFlags.Kick))
                   flags.Add("Kick");
                if (adminFlags.Has(AdminFlags.Ban))
                   flags.Add("Ban");
                if (adminFlags.Has(AdminFlags.Unban))
                   flags.Add("Unban");
                if (adminFlags.Has(AdminFlags.Slay))
                   flags.Add("Slay");
                if (adminFlags.Has(AdminFlags.Map))
                   flags.Add("Map");
                if (adminFlags.Has(AdminFlags.Config))
                   flags.Add("Config");
                if (adminFlags.Has(AdminFlags.BanIp))
                   flags.Add("BanIp");
                if (adminFlags.Has(AdminFlags.BanPerm))
                   flags.Add("BanPerm");
                if (adminFlags.Has(AdminFlags.UnbanAny))
                   flags.Add("UnbanAny");
                string Flags = string.Join(", ", flags);
                builder.AddNoOp($"{Flags}");
           }
        }
        DateTime now = DateTime.UtcNow;
        if (userData.CountBan > 0)
        {
            var active = (userData.Ban & BanType.Ban) == 0 ? T(player,"sz_menu.expired") : SourceBans.FormatTimeLeft(player, userData.ExpiryBan-now);
            builder.AddNoOp($"Ban: {userData.CountBan} ({SourceBans.FormatTimeLeft(player, TimeSpan.FromSeconds(userData.DurationBan))})({active})");
        }
        if (userData.CountMute > 0)
        {
            var active = (userData.Ban & BanType.Mute) == 0 ? T(player,"sz_menu.expired") : SourceBans.FormatTimeLeft(player, userData.ExpiryMute-now);
            builder.AddNoOp($"Mute: {userData.CountMute} ({SourceBans.FormatTimeLeft(player, TimeSpan.FromSeconds(userData.DurationMute))})({active})");
        }
        if (userData.CountGag > 0)
        {
            var active = (userData.Ban & BanType.Gag) == 0 ? T(player,"sz_menu.expired") : SourceBans.FormatTimeLeft(player, userData.ExpiryGag-now);
            builder.AddNoOp($"Gag: {userData.CountGag} ({SourceBans.FormatTimeLeft(player, TimeSpan.FromSeconds(userData.DurationGag))})({active})");
        }
        if (userData.CountSlay > 0)
        {
            builder.AddNoOp($"Slay: {userData.CountSlay}");

        }
        builder.Open(player, Instance!._menuManager);
    }

    public static void AdminCMDitem(CCSPlayerController player,CCSPlayerController? target)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid || target == null)
            return;
        var builder = new HLZMenuBuilder("Give Items").NoNumber();
        builder.Add("[Pistol] CZ75-Auto", _ => AdminConfirm(player,target,"give 1 CZ"));
        builder.Add("[Pistol] Desert Eagle", _ => AdminConfirm(player,target,"give 1 Deagle"));
        builder.Add("[Pistol] Dual Berettas", _ => AdminConfirm(player,target,"give 1 Elite"));
        builder.Add("[Pistol] Five-SeveN", _ => AdminConfirm(player,target,"give 1 FiveSeven"));
        builder.Add("[Pistol] Glock-18", _ => AdminConfirm(player,target,"give 1 Glock"));
        builder.Add("[Pistol] P2000", _ => AdminConfirm(player,target,"give 1 HKP2000"));
        builder.Add("[Pistol] P250", _ => AdminConfirm(player,target,"give 1 P250"));
        builder.Add("[Pistol] R8 Revolver", _ => AdminConfirm(player,target,"give 1 Revolver"));
        builder.Add("[Pistol] Tec-9", _ => AdminConfirm(player,target,"give 1 Tec9"));
        builder.Add("[Pistol] USP-S", _ => AdminConfirm(player,target,"give 1 USPS"));
        builder.Add("[Rifle] AK47", _ => AdminConfirm(player,target,"give 1 AK47"));
        builder.Add("[Rifle] AUG", _ => AdminConfirm(player,target,"give 1 AUG"));
        builder.Add("[Rifle] AWP", _ => AdminConfirm(player,target,"give 1 AWP"));
        builder.Add("[Rifle] FAMAS", _ => AdminConfirm(player,target,"give 1 Famas"));
        builder.Add("[Rifle] G3SG1", _ => AdminConfirm(player,target,"give 1 G3SG1"));
        builder.Add("[Rifle] Galil AR", _ => AdminConfirm(player,target,"give 1 GalilAR"));
        builder.Add("[Rifle] M4A1-S", _ => AdminConfirm(player,target,"give 1 M4A1S"));
        builder.Add("[Rifle] SCAR-20", _ => AdminConfirm(player,target,"give 1 SCAR20"));
        builder.Add("[Rifle] SG 556", _ => AdminConfirm(player,target,"give 1 SG556"));
        builder.Add("[Rifle] SSG 08", _ => AdminConfirm(player,target,"give 1 SSG08"));
        builder.Add("[SMG] MAC-10", _ => AdminConfirm(player,target,"give 1 Mac10"));
        builder.Add("[SMG] MP5-SD", _ => AdminConfirm(player,target,"give 1 MP5SD"));
        builder.Add("[SMG] MP7", _ => AdminConfirm(player,target,"give 1 MP7"));
        builder.Add("[SMG] MP9", _ => AdminConfirm(player,target,"give 1 MP9"));
        builder.Add("[SMG] PP-Bizon", _ => AdminConfirm(player,target,"give 1 Bizon"));
        builder.Add("[SMG] P90", _ => AdminConfirm(player,target,"give 1 P90"));
        builder.Add("[SMG] UMP-45", _ => AdminConfirm(player,target,"give 1 UMP45"));
        builder.Add("[Heavy] MAG-7", _ => AdminConfirm(player,target,"give 1 MAG7"));
        builder.Add("[Heavy] Nova", _ => AdminConfirm(player,target,"give 1 Nova"));
        builder.Add("[Heavy] Sawed-Off", _ => AdminConfirm(player,target,"give 1 SawedOff"));
        builder.Add("[Heavy] XM1014", _ => AdminConfirm(player,target,"give 1 XM1014"));
        builder.Add("[Heavy] M249", _ => AdminConfirm(player,target,"give 1 M249"));
        builder.Add("[Heavy] Negev", _ => AdminConfirm(player,target,"give 1 Negev"));
        builder.Add("[Taser] Zeus x27", _ => AdminConfirm(player,target,"give 1 Taser"));
        builder.Add("[Grenade] Smoke", _ => AdminConfirm(player,target,"give 1 Smoke"));
        builder.Add("[Grenade] Molotov", _ => AdminConfirm(player,target,"give 1 Molotov"));
        builder.Add("[Grenade] Flashbang", _ => AdminConfirm(player,target,"give 1 Flashbang"));
        builder.Add("[Grenade] HE", _ => AdminConfirm(player,target,"give 1 HighExplosive"));
        builder.Add("[Grenade] Decoy", _ => AdminConfirm(player,target,"give 1 Decoy"));
        builder.Add("[Armor] Kevlar", _ => AdminConfirm(player,target,"give 1 Kevlar"));
        builder.Add("[Armor] KevlarHelmet", _ => AdminConfirm(player,target,"give 1 KevlarHelmet"));
        builder.Add("[Health] HealthShot", _ => AdminConfirm(player,target,"give 1 Healthshot"));
        builder.Add("[Bomb] C4", _ => AdminConfirm(player,target,"give 1 C4"));
        builder.Open(player, Instance!._menuManager);
   }

    public static void AdminCMD1(CCSPlayerController player,CCSPlayerController? target, string cmd)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid || target == null)
            return;

        var name = Instance?.Trunc(target.PlayerName,10);
        var builder = new HLZMenuBuilder($"{name}");
        SourceBans._userCache.TryGetValue(player.SteamID, out var userData);
        var adminFlags = userData.Flags.ToFlags();
        bool superAdmin = adminFlags.Has(AdminFlags.Root | AdminFlags.BanPerm);

        if (cmd == "team")
        {
            if (target.TeamNum != 2)
                builder.Add(T(player,"sz_menu.team2"), _ => AdminConfirm(player,target,$"team 2"));
            if (target.TeamNum != 3)
                builder.Add(T(player,"sz_menu.team3"), _ => AdminConfirm(player,target,$"team 3"));
            if (target.TeamNum != 1)
                builder.Add(T(player,"sz_menu.team1"), _ => AdminConfirm(player,target,$"team 1"));

        } else {
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Kick) && cmd == "Ban")
                builder.Add("Kick", _ => AdminCMD3(player,target, "kick", 2, "kick"));
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Ban))
            {
                if (SourceBans.Durations[1] > 0 || superAdmin)
                    builder.Add(T(player,"sz_menu.ban_duration_1",cmd), _ => AdminCMD3(player,target, cmd == "Ban"? "ban" : "comm", SourceBans.Durations[1], cmd));
                if (SourceBans.Durations[1] > 0 || superAdmin)
                    builder.Add(T(player,"sz_menu.ban_duration_2",cmd), _ => AdminCMD3(player,target, cmd == "Ban"? "ban" : "comm", SourceBans.Durations[2], cmd));
                if (SourceBans.Durations[1] > 0 || superAdmin)
                    builder.Add(T(player,"sz_menu.ban_duration_3",cmd), _ => AdminCMD3(player,target, cmd == "Ban"? "ban" : "comm", SourceBans.Durations[3], cmd));
                if (SourceBans.Durations[1] > 0 || superAdmin)
                    builder.Add(T(player,"sz_menu.ban_duration_4",cmd), _ => AdminCMD3(player,target, cmd == "Ban"? "ban" : "comm", SourceBans.Durations[4], cmd));
                if (SourceBans.Durations[1] > 0 || superAdmin)
                    builder.Add(T(player,"sz_menu.ban_duration_5",cmd), _ => AdminCMD3(player,target, cmd == "Ban"? "ban" : "comm", SourceBans.Durations[5], cmd));
            }
        }
        builder.Open(player, Instance!._menuManager);
    }

    public static void AdminCMD2(CCSPlayerController player,ulong targetSid64)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid)
            return;

        SourceBans._userCache.TryGetValue(targetSid64, out var targetData);
        SourceBans._userCache.TryGetValue(player.SteamID, out var userData);
        var name = Instance?.Trunc(targetData.PlayerName,10);
        var builder = new HLZMenuBuilder($"{name}");
        var adminFlags = userData.Flags.ToFlags();
        bool superAdmin = adminFlags.Has(AdminFlags.Root | AdminFlags.BanPerm);
        DateTime now = DateTime.UtcNow;

        if ((targetData.Ban & BanType.Kick)>0) {
            bool _temp = targetData.ExpiryBan < DateTime.MaxValue;
            var remaining = !_temp ? T(player,"sz_menu.permanently") : SourceBans.FormatTimeLeft(player, targetData.ExpiryBan-now);
            var label = T(player,"sz_menu.unkick", remaining);
            builder.AddNoOp(label);
        }
        if ((targetData.Ban & (BanType.Banip | BanType.Ban))>0) {
            bool _temp = targetData.ExpiryBan < DateTime.MaxValue;
            var remaining = !_temp ? T(player,"sz_menu.permanently") : SourceBans.FormatTimeLeft(player, targetData.ExpiryBan-now);
            var label = T(player,"sz_menu.unban", remaining);
            if ((adminFlags.Has(AdminFlags.Root | AdminFlags.Unban) && _temp) || adminFlags.Has(AdminFlags.Root | AdminFlags.BanPerm))
            {
                builder.Add(label, _ => AdminCMD3(player,null, "unban", 0, "unban", targetSid64));
            } else {
                builder.AddNoOp(label);
            }
        }
        if ((targetData.Ban & BanType.Gag)>0) {
            bool _temp = targetData.ExpiryGag < DateTime.MaxValue;
            var remaining = targetData.ExpiryGag == DateTime.MaxValue ? T(player,"sz_menu.permanently") : SourceBans.FormatTimeLeft(player, targetData.ExpiryGag - now);
            var label = T(player,"sz_menu.ungag", remaining);
             if (adminFlags.Has(AdminFlags.Root | AdminFlags.Unban) || superAdmin)
            {
                builder.Add(label, _ => AdminCMD3(player, null, "unban", 0, "ungag",targetSid64));
            } else {
                builder.AddNoOp(label);
            }
        }
        if ((targetData.Ban & BanType.Mute)>0) {
            bool _temp = targetData.ExpiryMute < DateTime.MaxValue;
            var remaining = !_temp ? T(player,"sz_menu.permanently") : SourceBans.FormatTimeLeft(player, targetData.ExpiryMute-now);
            var label = T(player,"sz_menu.unmute", remaining);
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Unban) || superAdmin)
            {
                builder.Add(label, _ => AdminCMD3(player,null, "unban", 0, "unmute", targetSid64));
            } else {
                builder.AddNoOp(label);
            }
        }
        if ((targetData.Ban & BanType.Gag)>0 && (targetData.Ban & BanType.Mute)>0 && targetData.ExpiryGag == targetData.ExpiryMute) {
            bool _temp = targetData.ExpiryGag < DateTime.MaxValue;
            var remaining = targetData.ExpiryBan == DateTime.MaxValue ? T(player,"sz_menu.permanently") : SourceBans.FormatTimeLeft(player, targetData.ExpiryGag-now);
            var label = T(player,"sz_menu.unsilence", remaining);
            if (adminFlags.Has(AdminFlags.Root | AdminFlags.Unban) || superAdmin)
            {
                builder.Add(label, _ => AdminCMD3(player,null, "unban", 0, "unsilence", targetSid64));
            } else {
                builder.AddNoOp(label);
            }
        }
 
        builder.Open(player, Instance!._menuManager);

    }

    public static void AdminCMD3(CCSPlayerController player,CCSPlayerController? target, string type, int duration, string cmd, ulong targetSid64 = 0)
    {
        if (!SourceBans._enabled || player == null || !player.IsValid)
            return;

        var name = "";
        if (SourceBans._userCache.TryGetValue(targetSid64, out var targetData))
        {
            name = Instance?.Trunc(targetData.PlayerName,10);
        } else if (target != null) {
            name = Instance?.Trunc(target.PlayerName,10);
        }
        var builder = new HLZMenuBuilder($"{name}");
        switch (type)
        {
            case "kick":
            case "ban":
                if (target == null) return;
                for (int i = 1; i < 6; i++)
                {
                    var reason = T(player,$"sz_menu.ban_reason_{i}");
                    if (!string.IsNullOrEmpty(reason))
                    {
                        builder.Add(reason, _ => AdminAction(player, cmd, target, reason, null, duration));
                    }
                }
            break;
            case "comm":
                if (target == null) return;
                for (int i = 1; i < 6; i++)
                {
                    var reason = T(player,$"sz_menu.comm_reason_{i}");
                    if (!string.IsNullOrEmpty(reason))
                    {
                        builder.Add(reason, _ => AdminAction(player, cmd, target, reason, null, duration));
                    }
                }
            break;
            case "unban":
                for (int i = 1; i < 6; i++)
                {
                    var reason = T(player,$"sz_menu.unban_reason_{i}");
                    if (!string.IsNullOrEmpty(reason))
                    {
                        builder.Add(reason, _ => AdminAction(player, cmd, null, reason, null, duration, false, targetSid64));
                    }
                }
            break;
            default:
            break;
        }
        builder.Open(player, Instance!._menuManager);

    }

    public static void AdminConfirm(CCSPlayerController player,CCSPlayerController target, string cmd)
    {
        if (player == null || !player.IsValid)
            return;

        var name = Instance?.Trunc(target.PlayerName,10);
        var builder = new HLZMenuBuilder($"{name}");
        var parts  = cmd.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        int length = parts.Length > 1 ?  int.Parse(parts[1]) : 0;
        string? level = parts.Length > 2 ? parts[2] : null;

        builder.Add(T(player,"sz_menu.confirm"), _ => AdminAction(player,parts[0],target,level,null,length));

        builder.Open(player, Instance!._menuManager);

    }

    public static void AdminAction(CCSPlayerController? admin,string action, CCSPlayerController? target, string? args, CommandInfo? command, int number = 0, bool console = false, ulong target64 = 0)
    {
        var Name = "";
        bool isAdmin = false;
        int Aid = 0;
        var adminFlags = AdminFlags.None;
        var Ip = "";
        var Immunity = 0;

        if (admin != null && admin?.IsValid == true && SourceBans._userCache.TryGetValue(admin.SteamID, out var userData))
        {

            Name       = admin.PlayerName;
            isAdmin    = userData.IsAdmin;
            Aid        = userData.Aid;
            Ip         = userData.IP;
            adminFlags = userData.Flags.ToFlags();
            Immunity   = userData.Immunity;

        } else if (command != null && console == true) {
            Name       = "Console";
            isAdmin    = true;
            Ip         = GetLocalIPAddress();
            adminFlags = AdminFlags.Root;
            Immunity   = int.MaxValue;

        } else { return; }

        var cmd     = action.Trim().ToLowerInvariant();
        var reason = string.IsNullOrWhiteSpace(args) ? "Admin Action" : args.Trim();

        var message = "";
        var type    = BanType.None;
        var page    = 0;
        int min     = 1;

        switch (cmd)
        {
            case "kick": {
                if (target == null || !target.IsValid) return;
                if(!adminFlags.Has(AdminFlags.Root | AdminFlags.Kick))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                if (SourceBans._userCache.TryGetValue(target.SteamID, out var targetData))
                {
                    if ( targetData.Immunity > Immunity )
                    {
                        privateChat(admin, "sz_chat.permission");
                        return;
                    }
                    message  = CenterColors(Instance!.Localizer.ForPlayer(target, "sz_html.you_are_kicked",reason));
                    SendPrivateHTML(target, message, SourceBans.KickDelay);
                    SourceBans.UpdateBanUser(target.SteamID, BanType.Kick, 120, false, Aid);
                    _ = DiscordWebhooks.Send(Instance!.Config, cmd, admin, target.SteamID, reason, 120, Instance?.Logger);
                    _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{target.PlayerName} {reason}"
                                                        );
                }
                publicChat("sz_chat.admin_kicked", Name,target.PlayerName,reason);
                SourceBans.DelayedCommand($"kickid {target.UserId} \"Kicked {target.PlayerName} ({reason})\"", SourceBans.KickDelay);
                target.CommitSuicide(false, true);
                if (admin == null)
                    command?.ReplyToCommand(Instance!.T("sz_chat.admin_kicked", Name,target.PlayerName,reason));
            break; }
            case "votekick": {
                if (target == null || !target.IsValid) return;
                if (SourceBans._vote.ContainsKey("kick") || SourceBans._vote.ContainsKey("map"))
                {
                    privateChat(admin, "sz_chat.vote_inprogress");
                    return;
                }
                min = (int)Math.Ceiling(Utilities.GetPlayers().Count(p => p != null && p.IsValid && !p.IsBot) * 0.6);
                SourceBans._vote["kick"] = (DateTime.UtcNow, target, target.PlayerName, null, 0, 0, Math.Max(1,min));
                foreach (var p in Utilities.GetPlayers())
                {
                    if (p?.IsValid == true && p?.IsBot == false)
                        VoteActive("kick", p, target, null);
                }
                SourceBans.StartVoteTimer();
            return; }
            case "ban":
            case "banip":
            case "gag":
            case "mute":
            case "silence": {
                if (target == null || !target.IsValid) return;
                if((cmd == "banip" && !adminFlags.Has(AdminFlags.Root | AdminFlags.BanIp)) ||
                   (!adminFlags.Has(AdminFlags.Root | AdminFlags.Ban)))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                type = cmd == "ban" ? BanType.Ban :
                       cmd == "banip" ? BanType.Banip :
                       cmd == "gag" ? BanType.Gag :
                       cmd == "mute" ? BanType.Mute : BanType.Silence;
                message = cmd switch
                {
                    "ban"         => "sz_chat.admin_banned",
                    "banip"       => "sz_chat.admin_banned",
                    "gag"         => "sz_chat.admin_gagged",
                    "mute"        => "sz_chat.admin_muted",
                    "silence"     => "sz_chat.admin_silenced",
                    _             => "SnipeZilla Error"
                };
                var content = cmd switch
                {
                    "ban"         => "sz_html.you_are_banned",
                    "banip"       => "sz_html.you_are_banned",
                    "gag"         => "sz_html.you_are_gagged",
                    "mute"        => "sz_html.you_are_muted",
                    "silence"     => "sz_html.you_are_silenced",
                    _             => "SnipeZilla Error"
                };
                if (!SourceBans._userCache.TryGetValue(target.SteamID, out var targetData))
                {
                    if (admin != null)
                        privateChat(admin, "sz_chat.player_record",target.PlayerName);
                    else
                        command?.ReplyToCommand(Instance!.T("sz_chat.player_record",target.PlayerName));
                    return;
                }
                if ( number < 0 )
                {
                    if (admin != null)
                        privateChat(admin, "sz_chat.banning_usage", cmd);
                    else
                        command?.ReplyToCommand(Instance!.T("sz_chat.banning_usage", cmd));
                    return;
                }
                if ((((cmd == "ban" && targetData.ExpiryBan == DateTime.MaxValue) ||
                    (cmd == "silence" && (targetData.ExpiryMute == DateTime.MaxValue || targetData.ExpiryGag == DateTime.MaxValue)) ||
                    (cmd == "mute" && targetData.ExpiryMute == DateTime.MaxValue) ||
                    (cmd == "gag" && targetData.ExpiryGag == DateTime.MaxValue)) &&
                    !adminFlags.Has(AdminFlags.Root | AdminFlags.BanPerm)) || ( targetData.Immunity > Immunity ))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }

                if (((cmd == "ban" && (targetData.Ban & BanType.Ban)!=0 && targetData.aBan != Aid) ||
                    (cmd == "gag" && (targetData.Ban & BanType.Gag)!=0 && targetData.aGag != Aid) ||
                    (cmd == "mute" && (targetData.Ban & BanType.Mute)!=0 && targetData.aMute != Aid) ||
                    (cmd == "silence" && (targetData.Ban & BanType.Silence)!=0  && (targetData.aMute != Aid || targetData.aGag != Aid))) &&
                     !adminFlags.Has(AdminFlags.Root | AdminFlags.UnbanAny))
                {
                    privateChat(admin, "sz_chat.admin_rights");
                    return;
                }
                if (cmd == "mute" || cmd == "silence")
                    target.VoiceFlags = VoiceFlags.Muted;
                if (cmd == "silence")
                {
                    _ = SourceBans.WriteBan(target.SteamID, target.PlayerName, Aid, Ip ?? "", BanType.Mute, number, reason);
                    _ = SourceBans.WriteBan(target.SteamID, target.PlayerName,  Aid, Ip ?? "", BanType.Gag, number, reason);
                } else {
                    _ = SourceBans.WriteBan(target.SteamID, target.PlayerName,  Aid, Ip ?? "", type, number, reason);
                }

                DateTime now = DateTime.UtcNow.AddMinutes(-1);
                var _expiry   = number > 0 ? number : int.MaxValue;
                var remaining = _expiry == int.MaxValue ? T(admin,"sz_menu.permanently") : SourceBans.FormatTimeLeft(admin, TimeSpan.FromSeconds(_expiry));

                _ = DiscordWebhooks.Send(Instance!.Config, cmd, admin, target.SteamID, reason, _expiry, Instance?.Logger);
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{target.PlayerName} {remaining} {reason}"
                                                    );
                if (admin == null)
                    command?.ReplyToCommand(Instance!.T(message, Name,target.PlayerName, remaining, reason));
                publicChat(message, Name,target.PlayerName,remaining,reason);
                message = CenterColors(Instance!.Localizer.ForPlayer(target, content, reason, remaining, Instance!.Config.SourceBans.Website));
                privateChat(target,"sz_chat.sourcebans_website",Instance!.Config.SourceBans.Website);
                if (cmd == "ban" || cmd == "banip")
                {
                    target.CommitSuicide(false, true);
                    target.Freeze();
                    SendPrivateHTML(target, message, SourceBans.KickDelay);
                    SourceBans.DelayedCommand($"kickid {target.UserId} \"Banned {target.PlayerName} ({reason})\"", SourceBans.KickDelay);
                } else {
                    SendPrivateHTML(target, message, 5.0f);
                }
            break; }
            case "ungag":
            case "unmute":
            case "unsilence":
            case "unban": {
                page=1;
                if ((target == null || !target.IsValid) && target64 ==0) return;
                ulong targetID64 = target != null ? target.SteamID : target64;
                if(!adminFlags.Has(AdminFlags.Root | AdminFlags.Unban))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                type = cmd == "ungag" ? BanType.Gag :
                       cmd == "unmute" ? BanType.Mute :
                       cmd == "unsilence" ? BanType.Silence : BanType.Ban;
                if (!SourceBans._userCache.TryGetValue(targetID64, out var targetData))
                {
                    if (admin == null)
                        Server.PrintToConsole(T(null,"sz_chat.player_record",targetID64));
                    else
                        privateChat(admin, "sz_chat.player_record",targetID64);
                    return;
                }
                if ((cmd == "unban" && (targetData.Ban & BanType.Ban)==0) ||
                    (cmd == "ungag" && (targetData.Ban & BanType.Gag)==0) ||
                    (cmd == "unmute" && (targetData.Ban & BanType.Mute)==0) ||
                    (cmd == "unsilence" && (targetData.Ban & BanType.Silence)==0))
                {
                    privateChat(admin, "sz_chat.player_noban",targetData.PlayerName);
                    return;
                }
                if (((cmd == "unban" && targetData.aBan != Aid) ||
                    (cmd == "unsilence" && (targetData.aMute != Aid || targetData.aGag != Aid)) ||
                    (cmd == "unmute" && targetData.aMute != Aid) ||
                    (cmd == "ungag" && targetData.aGag != Aid)) &&
                    !adminFlags.Has(AdminFlags.Root | AdminFlags.UnbanAny))
                {
                    privateChat(admin, "sz_chat.admin_rights");
                    return;
                }
                if ((cmd == "unmute" || cmd == "unsilence") && target != null)
                    target.VoiceFlags = VoiceFlags.Normal;
                if (cmd == "unsilence")
                {
                    _ = SourceBans.WriteUnBan(targetID64, admin, BanType.Mute, reason);
                    _ = SourceBans.WriteUnBan(targetID64, admin, BanType.Gag, reason);
                } else {
                    _ = SourceBans.WriteUnBan(targetID64, admin, type, reason);
                }
                SourceBans.UpdateBanUser(targetID64, type, 0,true, Aid);
                message = cmd switch
                {
                    "ungag"       => "sz_chat.admin_ungagged",
                    "unmute"      => "sz_chat.admin_unmuted",
                    "unsilence"   => "sz_chat.admin_unsilenced",
                    "unban"       => "sz_chat.admin_unbanned",
                    _             => "SnipeZilla Error"
                };
                _ = DiscordWebhooks.Send(Instance!.Config, cmd, admin, targetID64, reason, 0, Instance?.Logger);
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{targetData.PlayerName} {reason}"
                                                    );
                if (admin == null)
                    command?.ReplyToCommand(Instance!.T(message, Name,targetData.PlayerName, reason));
                publicChat(message, Name,targetData.PlayerName,reason);
            break; }
            case "next":
            case "map": 
            case "votemap": {
                page = 2;
                if (args == null) return;
                if (cmd == "votemap" && (SourceBans._vote.ContainsKey("map") || SourceBans._vote.ContainsKey("kick")))
                {
                    privateChat(admin,"sz_chat.vote_inprogress");
                    return;
                }
                var availableMaps = SourceBans.GetAvailableMaps(Instance!.Config, isAdmin);
                var match = availableMaps.FirstOrDefault(m =>
                    string.Equals(m.DisplayName, args, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(m.MapName, args, StringComparison.OrdinalIgnoreCase) ||
                    (m.WorkshopId != null && string.Equals(m.WorkshopId, args, StringComparison.OrdinalIgnoreCase)));
                if (match == null)
                {
                    privateChat(admin, "sz_chat.map_notfound",args);
                    return;
                }
                if (cmd == "votemap") {
                    min = (int)Math.Ceiling(Utilities.GetPlayers().Count(p => p != null && p.IsValid && !p.IsBot) * 0.6);
                    SourceBans._vote["map"] = (DateTime.UtcNow, null, null, args, 0, 0, Math.Max(1,min));
                    foreach (var p in Utilities.GetPlayers())
                    {
                        if (p?.IsValid == true && p?.IsBot == false)
                            VoteActive("map",p,null,args);
                    }
                    SourceBans._mVote++;
                    SourceBans.StartVoteTimer();
                    return;
                }
                if(cmd == "map" && !adminFlags.Has(AdminFlags.Root | AdminFlags.Map))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{match.MapName}"
                                                    );
                privateChat(admin, "sz_chat.admin_change_map", Name, match.MapName);
                var change = match.IsSteamWorkshop ? $"host_workshop_map {match.WorkshopId}" : $"changelevel {match.MapName}";
                SourceBans.DelayedCommand(change,5.0f);
            break; }
            case "give":
                if (target == null || !target.IsValid) return;
                if(!adminFlags.Has(AdminFlags.Root | AdminFlags.Cheats))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                if (!SourceBans.TryParseWeapon(reason, out var item))
                {
                    if (admin == null)
                        command?.ReplyToCommand(Instance!.T("sz_chat.no_items"));
                    else
                        privateChat(admin, "sz_chat.no_items");
                    return;
                }


                if (admin == null)
                    command?.ReplyToCommand(Instance!.T("sz_chat.admin_renamed", Name,target.PlayerName, reason));
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{reason} → {target.PlayerName}"
                                                    );
                publicChat("sz_chat.give_items", Name,reason,target.PlayerName);
                SourceBans.GiveItems(target, reason);
            break;
            case "rename":
                if (target == null || !target.IsValid) return;
                if(!adminFlags.Has(AdminFlags.Root | AdminFlags.Generic))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                if (admin == null)
                    command?.ReplyToCommand(Instance!.T("sz_chat.admin_renamed", Name,target.PlayerName, reason));
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{target.PlayerName} → {reason}"
                                                    );
                publicChat("sz_chat.admin_renamed", Name,target.PlayerName,reason);
                SourceBans.Rename(target,reason);
            break;
            case "slay":
                if (target == null || !target.IsValid) return;
                if(!adminFlags.Has(AdminFlags.Root | AdminFlags.Slay))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                target.CommitSuicide(false, true);
                SourceBans.UpdateBanUser(target.SteamID, BanType.Slay, 0, false, Aid);
                if (admin == null)
                    command?.ReplyToCommand(Instance!.T("sz_chat.admin_slayed", Name, target.PlayerName, reason));
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{target.PlayerName}"
                                                    );
                publicChat("sz_chat.admin_slayed", Name, target.PlayerName, reason);
            break;
            case "team": {
                if (target == null || !target.IsValid) return;
                if(!adminFlags.Has(AdminFlags.Root | AdminFlags.Generic))
                {
                    privateChat(admin, "sz_chat.permission");
                    return;
                }
                CsTeam csTeam;
                var team = "";
                switch ((TeamNum)number)
                {
                    case TeamNum.Spectator:
                        csTeam = CsTeam.Spectator;
                        team = T(admin,"sz_menu.team1");
                        break;
                    case TeamNum.Terrorist:
                        csTeam = CsTeam.Terrorist;
                        team = T(admin,"sz_menu.team2");
                        break;
                    case TeamNum.CounterTerrorist:
                        csTeam = CsTeam.CounterTerrorist;
                        team = T(admin,"sz_menu.team3");
                        break;
                    default:
                        if (admin == null)
                            command?.ReplyToCommand($"Invalid team ID {number}");
                        else
                            SendPrivateChat(admin, $"[HLstats\x07Z\x01] Invalid team ID {number}");
                        return;
                }
                target.ChangeTeam(csTeam);
                if (admin == null)
                    command?.ReplyToCommand(Instance!.T("sz_chat.admin_change_team", Name,target.PlayerName,team));
                _ = DiscordWebhooks.LogAdminCommand(
                                                        Instance!.Config,
                                                        admin,
                                                        cmd,
                                                        $"{target.PlayerName} → {team}"
                                                    );
                publicChat("sz_chat.admin_change_team", Name,target.PlayerName,team);
            break; }
            case "rtv": {
                var allMaps = SourceBans.GetAvailableMaps(Instance!.Config, false);
                string currentMap = Server.MapName;

                var candidates = allMaps
                    .Where(m => !string.Equals(m.MapName, currentMap, StringComparison.OrdinalIgnoreCase))
                    .ToList();

                if (candidates.Count == 0) {
                    privateChat(admin, "sz_chat.no_maps");
                    return;
                }

                var nominatedMaps = new List<SourceBans.MapEntry>();
                foreach (var nomination in SourceBans._userNominate.Values) {
                    var match = candidates.FirstOrDefault(m =>
                        string.Equals(m.DisplayName, nomination, StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(m.MapName, nomination, StringComparison.OrdinalIgnoreCase) ||
                        (m.WorkshopId != null && string.Equals(m.WorkshopId, nomination, StringComparison.OrdinalIgnoreCase))
                    );
                    if (match != null && !nominatedMaps.Contains(match)) {
                        nominatedMaps.Add(match);
                    }
                }

                var rng = new Random();
                var randomMaps = candidates
                    .Where(m => !nominatedMaps.Contains(m))
                    .OrderBy(_ => rng.Next())
                    .Take(Math.Max(0, 5 - nominatedMaps.Count))
                    .ToList();

                SourceBans._rtv = nominatedMaps.Concat(randomMaps).ToList();

                min = Utilities.GetPlayers().Count(p => p != null && p.IsValid && !p.IsBot);
                SourceBans._vote["map"] = (DateTime.UtcNow, null, Name, null, 0, 0, Math.Max(1, min));

                foreach (var p in Utilities.GetPlayers()) {
                    if (p?.IsValid == true && p?.IsBot == false)
                        VoteActive("rtv", p, null, args);
                }

                SourceBans._mVote++;
                SourceBans.StartVoteTimer();
                return;
            }

            case "nominate": {
                page = 2;
                if (args == null || admin == null) return;
                ulong steamId = admin.SteamID;

                var availableMaps = SourceBans.GetAvailableMaps(Instance!.Config, false);
                var match = availableMaps.FirstOrDefault(m =>
                    string.Equals(m.DisplayName, args, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(m.MapName, args, StringComparison.OrdinalIgnoreCase) ||
                    (m.WorkshopId != null && string.Equals(m.WorkshopId, args, StringComparison.OrdinalIgnoreCase)));

                if (match == null)
                {
                    privateChat(admin, "sz_chat.map_notfound",args);
                    return;
                }
                publicChat("sz_chat.nominate", Name,args);
                SourceBans._userNominate[steamId] = args.ToLowerInvariant();
            break; }
            default:
            break;
        }

        if (admin != null && Instance!._menuManager._activeMenus.ContainsKey(admin.SteamID))
        {
            if (page == 0) { Instance!._menuManager.RewindToLabel(admin, "Players"); AdminPlayer(admin, page); }
            else if (page == 1) { Instance!._menuManager.RewindToLabel(admin, "Unban"); AdminPlayer(admin, page); }
            else if (page == 2) { Instance!._menuManager.DestroyMenu(admin); }
        }
        return;
    }

    // ------------------ Event Handler ------------------
    public HookResult OnRoundStart(EventRoundStart @event, GameEventInfo info)
    {
        SourceBans._canVote = SourceBans._mVote < 2;
        SendLog(null, "World triggered \"Round_Start\"", null);
        return HookResult.Continue;
    }

    public HookResult OnRoundEnd(EventRoundEnd @event, GameEventInfo info)
    {
        SourceBans._canVote = false;
        var players = GetPlayersList();

        foreach (var player in players)
        {
            FlushPlayerWeaponStats(player);
            _menuManager.DestroyMenu(player);
        }

        return HookResult.Continue;

    }

    public HookResult OnRoundMvp(EventRoundMvp @event, GameEventInfo info)
    {
        CCSPlayerController? player;
        int reason;
        try
        {
            player = @event.Userid;
            reason = @event.Reason;
        }
        catch (NativeException) { return HookResult.Continue; }

        if (player == null || !player.IsValid) return HookResult.Continue;

        string reasonText = reason switch
        {
            1  => "with most eliminations",
            2  => "with bomb planted",
            3  => "with bomb defused",
            4  => "with hostage rescued",
            11 => "with HE grenade",
            14 => "with a clutch defuse",
            15 => "with most kills",
            _  => $"with best overall"
        };

        SendLog(player, $"round_mvp {reasonText}", "triggered");
        return HookResult.Continue;
    }

    public HookResult OnBombAbortdefuse(EventBombAbortdefuse @event, GameEventInfo info)
    {
        var player = @event.Userid;
        if (player == null || !player.IsValid) return HookResult.Continue;

        SendLog(player, "Defuse_Aborted", "triggered");
        return HookResult.Continue;
    }

    public HookResult OnBombDefused(EventBombDefused @event, GameEventInfo info)
    {
        var player = @event.Userid;
        if (player == null || !player.IsValid) return HookResult.Continue;

        SendLog(player, "Defused_The_Bomb", "triggered");
        return HookResult.Continue;
    }

    private void OnClientAuthorized(int slot, SteamID steamId)
    {
        ulong sid64 = steamId.SteamId64;

        // A player coming back (disconnected since) is checked against the database again, so bans, unbans
        // and blocks made meanwhile (web panel, other servers) apply as they join; the cache only saves
        // queries while they stay connected.
        var hasCache = SourceBans._userCache.TryGetValue(sid64, out var cached);
        bool refresh = !hasCache || !cached.Connected || cached.Updated <= DateTime.UtcNow - TimeSpan.FromMinutes(2);

        var player = Utilities.GetPlayerFromSlot(slot);

        // A fresh check validates the player itself once the database answered; the old entry is not trusted
        if (!refresh || player == null || !player.IsValid)
        {
            Server.NextFrame(() =>
            {
                if (player != null && player.IsValid && !player.IsBot)
                    SourceBans.Validator(player, sid64, earlyStage: true);
                else
                    SourceBans.Validator(null, sid64, earlyStage: true);
            });
        }

        _ = SourceBans.isAdmin(player ?? null, refresh);
    }

    public HookResult OnPlayerConnectFull(EventPlayerConnectFull @event, GameEventInfo info)
    {
        var player = @event.Userid;
        if (player == null || !player.IsValid || player.IsBot)
            return HookResult.Continue;

        bool isValid = false;
        bool wasOffline = false;

        if (SourceBans._userCache.TryGetValue(player.SteamID, out var userCached))
        {
            isValid = SourceBans.Validator(player);
            if ( !string.Equals(userCached.PlayerName, player.PlayerName, StringComparison.OrdinalIgnoreCase) )
                SourceBans.Rename(player, userCached.PlayerName);
            wasOffline = !userCached.Connected;
        }

        if (!isValid || wasOffline)
            _ = SourceBans.isAdmin(player, wasOffline);

        SendWelcome(player);

        return HookResult.Continue;
    }

    public HookResult OnPlayerDisconnect(EventPlayerDisconnect @event, GameEventInfo info)
    {
        var player = @event.Userid;

        if (player != null && player.IsValid) {

            _menuManager.DestroyMenu(player);

            if (SourceBans._userNominate.ContainsKey(player.SteamID))
                SourceBans._userNominate.Remove(player.SteamID);

           if (!SourceBans._enabled) {
               SourceBans._userCache.TryRemove(player.SteamID, out _);
            } else {
                SourceBans.UpdateBanUser(player.SteamID, BanType.None, 0, true, 0, false);
            }

           FlushPlayerWeaponStats(player);

        }
        return HookResult.Continue;
    }

    public HookResult OnWeaponFire(EventWeaponFire @event, GameEventInfo info)
    {
        var attacker = @event.Userid;
        if (attacker == null || !attacker.IsValid || attacker.IsBot)
            return HookResult.Continue;

        var steamId = attacker.SteamID;

        var weapon = @event.Weapon;

        if (string.IsNullOrEmpty(weapon))
            return HookResult.Continue;

        if (weapon.StartsWith("weapon_"))
            weapon = weapon.Substring(7);

        if (!WeaponCode.TryGetValue(weapon, out var wCode))
            return HookResult.Continue;

        var dict = GetStatsme(steamId);
        ref var stats = ref GetWeaponStats(dict, wCode);
        stats.shots++;

        return HookResult.Continue;
    }

    public HookResult OnPlayerHurt(EventPlayerHurt @event, GameEventInfo info)
    {
        var attacker = @event.Attacker;
        var victim   = @event.Userid;

        if (attacker == null || !attacker.IsValid || attacker.IsBot)
            return HookResult.Continue;
        if (victim == null || !victim.IsValid)
            return HookResult.Continue;

        var steamId = attacker.SteamID;
        var weapon  = @event.Weapon;

        if (string.IsNullOrEmpty(weapon))
            return HookResult.Continue;

        if (weapon.StartsWith("weapon_"))
            weapon = weapon.Substring(7);

        if (!WeaponCode.TryGetValue(weapon, out var wCode))
            return HookResult.Continue;

        var dmg = @event.DmgHealth;
        var hg  = @event.Hitgroup;

        // ---- STATSME ----
        var dict = GetStatsme(steamId);
        ref var stats = ref GetWeaponStats(dict, wCode);
        stats.hits++;
        stats.damage += dmg;
        if (hg == 1)
            stats.headshots++;

        // ---- STATSME2 ----
        var hdict = GetStatsme2(steamId);
        ref var hstats = ref GetHitgroupStats(hdict, wCode);

        switch (hg)
        {
            case 1: hstats.head++;     break;
            case 2: hstats.chest++;    break;
            case 3: hstats.stomach++;  break;
            case 4: hstats.leftarm++;  break;
            case 5: hstats.rightarm++; break;
            case 6: hstats.leftleg++;  break;
            case 7: hstats.rightleg++; break;
        }

        return HookResult.Continue;
    }

    public HookResult OnPlayerDeath(EventPlayerDeath @event, GameEventInfo info)
    {
        var attacker = @event.Attacker;
        var victim   = @event.Userid;
        var weapon  = @event.Weapon;

        if (victim != null && victim.IsValid)
            _menuManager.DestroyMenu(victim);

        if (string.IsNullOrEmpty(weapon))
            return HookResult.Continue;

        if (weapon.StartsWith("weapon_"))
            weapon = weapon.Substring(7);

        if (!WeaponCode.TryGetValue(weapon, out var wCode))
            return HookResult.Continue;

        if (attacker != null && attacker.IsValid && !attacker.IsBot)
        {
            var steamId = attacker.SteamID;
            var dict = GetStatsme(steamId);
            ref var stats = ref GetWeaponStats(dict, wCode);
            stats.kills++;
        }

        if (victim != null && victim.IsValid && !victim.IsBot)
        {
            var steamId = victim.SteamID;
            var dict = GetStatsme(steamId);
            ref var stats = ref GetWeaponStats(dict, wCode);
            stats.deaths++;
            FlushPlayerWeaponStats(victim);
        }

        if (victim != null && victim.IsValid && !victim.IsBot)
        {
            SendDeathMsg(victim, attacker, @event);
        }

        return HookResult.Continue;
    }

    public HookResult OnCsWinPanelMatch(EventCsWinPanelMatch @event, GameEventInfo info)
    {
        if (!SourceBans._enabled) return HookResult.Continue;

        SourceBans._mVote   = 0;
        SourceBans._canVote = false;
        SourceBans._vote.Clear();
        SourceBans._rtv.Clear();
        SourceBans.StopVoteTimer();
        SourceBans._userNominate.Clear();

        if (!string.IsNullOrWhiteSpace(SourceBans.NextMap))
        {

            var availableMaps = SourceBans.GetAvailableMaps(HLstatsZ.Instance!.Config, true);
            var match = availableMaps.FirstOrDefault(m =>
                string.Equals(m.DisplayName, SourceBans.NextMap, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(m.MapName, SourceBans.NextMap, StringComparison.OrdinalIgnoreCase) ||
                (m.WorkshopId != null && string.Equals(m.WorkshopId, SourceBans.NextMap, StringComparison.OrdinalIgnoreCase)));
            SourceBans.NextMap = "";

            if (match != null)
            {
                publicChat("sz_chat.nominate_validation",match.MapName);
                var command = match.IsSteamWorkshop ? $"host_workshop_map {match.WorkshopId}" : $"changelevel {match.MapName}";
                SourceBans.DelayedCommand(command, 5.0f);
            }

        }

        return HookResult.Continue;
    }

   public HookResult OnPlayerSpawn(EventPlayerSpawn @event, GameEventInfo info)
   {
        var player = @event.Userid;
        if (player == null || !player.IsValid)
           return HookResult.Continue;

        Server.NextFrame(() => {
            if (SourceBans._userCache.TryGetValue(player.SteamID, out var userCached))
            {
                if ( !string.Equals(userCached.PlayerName, player.PlayerName, StringComparison.OrdinalIgnoreCase) )
                    SourceBans.Rename(player, userCached.PlayerName);

                if ((userCached.Ban & (BanType.Banip | BanType.Ban | BanType.Kick)) != 0) {
                    player.Freeze();
                    player.RemoveWeapons();
                }
            }
        });

       return HookResult.Continue;
   }

    private void OnMapStart(string name)
    {
        if (!SourceBans._enabled) return;
        SourceBans.NextMap = "";
        SourceBans._mVote   = 0;
        SourceBans._canVote = true;
        SourceBans._userNominate.Clear();
        SourceBans._vote.Clear();
        SourceBans._rtv.Clear();
        SourceBans.StopVoteTimer();
    }
}

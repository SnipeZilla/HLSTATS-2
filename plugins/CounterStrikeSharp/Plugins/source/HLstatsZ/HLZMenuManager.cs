using System.Text.RegularExpressions;
using CounterStrikeSharp.API;
using CounterStrikeSharp.API.Core;
using CounterStrikeSharp.API.Core.Plugin;
using CounterStrikeSharp.API.Modules.Menu;
using CounterStrikeSharp.API.Modules.Utils;
using CounterStrikeSharp.API.Modules.Entities.Constants;
using CounterStrikeSharp.API.Modules.Memory;
using CounterStrikeSharp.API.Modules.Timers;
using GameTickTimer = CounterStrikeSharp.API.Modules.Timers.Timer;
namespace HLstatsZ;

public class HLZMenuManager
{
    private readonly BasePlugin _plugin;

    private readonly Dictionary<ulong, int> _menuPages = new();
    private readonly Dictionary<ulong, int> _selectedIndex = new();
    private GameTickTimer? _menuTimer;
    public readonly Dictionary<ulong, PlayerButtons> _lastButtons = new();
    private const int MenuPollTicks = 6;
    public readonly Dictionary<ulong, (CCSPlayerController Player, CenterHtmlMenu Menu)> _activeMenus = new();
    private readonly Dictionary<ulong, List<(string Text, Action<CCSPlayerController> Callback)>> _pageOptions = new();
    private readonly Dictionary<ulong, Stack<(string Content, int Page, Dictionary<string, Action<CCSPlayerController>>? Callbacks)>> _menuHistory = new();

    public int MaxLines = 6;  // 6+2 with title and [Close]
    public string Nbsp(int n) => new string('\u00A0', n);


    public HLZMenuManager(BasePlugin plugin)
    {
        _plugin = plugin;
    }

    private void StartMenuInputTimer(CCSPlayerController player)
    {


        if (_menuTimer != null) return;

        _menuTimer = _plugin.AddTickTimer(MenuPollTicks, () =>
        {

            if (_activeMenus.Count == 0 && _menuTimer != null)
            {
                _menuTimer.Kill();
                _menuTimer = null;
                return;
            }

            foreach (var kvp in _activeMenus.ToList())
            {
                var steamId = kvp.Key;
                var (player, menu) = kvp.Value;

                if (player == null || !player.IsValid)
                {
                    DestroyMenu(player!);
                    return;
                }

                var current = player.Buttons;
                var last = _lastButtons.TryGetValue(steamId, out var prev) ? prev : 0;

                if (current.HasFlag(PlayerButtons.Forward)  && !last.HasFlag(PlayerButtons.Forward))
                    HandleWasdPress(player, "W");
                if (current.HasFlag(PlayerButtons.Back)     && !last.HasFlag(PlayerButtons.Back))
                    HandleWasdPress(player, "S");
                if (current.HasFlag(PlayerButtons.Moveleft) && !last.HasFlag(PlayerButtons.Moveleft))
                    HandleWasdPress(player, "A");
                if (current.HasFlag(PlayerButtons.Moveright)&& !last.HasFlag(PlayerButtons.Moveright))
                    HandleWasdPress(player, "D");
                if (current.HasFlag(PlayerButtons.Use)      && !last.HasFlag(PlayerButtons.Use))
                    HandleWasdPress(player, "E");

                _lastButtons[steamId] = current;

            }

        }, TimerFlags.REPEAT);

    }

    public void HandleWasdPress(CCSPlayerController player, string key)
    {
        switch (key)
        {
            case "W": HandleNavigation(player,-1); break;
            case "S": HandleNavigation(player,+1); break;
            case "A": HandleBack(player); break;
            case "D": HandlePage(player,+1); break;
            case "E": HandleSelect(player); break;
        }
    }

    private static string NormalizeHeading(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return "Stats";

        var s = raw.Trim();

        if (s.Length > 3 && s[0] == '-' && s[1] == '>' && char.IsDigit(s[2]))
        {
            int dashIndex = s.IndexOf('-', 3);
            if (dashIndex >= 0 && dashIndex + 1 < s.Length)
                s = s.Substring(dashIndex + 1).Trim();
        }

        return string.IsNullOrWhiteSpace(s) ? "Stats" : s;
    }

    private static List<string[]> PartitionPages(string[] lines)
    {
        var pages = new List<List<string>>();
        List<string>? current = null;

        foreach (var line in lines)
        {
            if (line.Length > 2 && line[0] == '-' && line[1] == '>' && char.IsDigit(line[2]))
            {
                current = new List<string>();
                pages.Add(current);
            }

            current ??= new List<string>();
            current.Add(line);
        }

        return pages.Select(p => p.ToArray()).ToList();
    }

    private static List<string> NormalizeContent(string content, int maxLinesPerPage = 6)
    {
        var lines = content.Replace("\r\n", "\n").Replace("\r", "\n").Replace("\\n", "\n")
                           .Split('\n')
                           .Select(l => l.Trim())
                           .Where(l => !string.IsNullOrWhiteSpace(l))
                           .ToArray();

        var output = new List<string>();
        int page = 1;
        int lineCount = 0;
        string Heading = "Stats";

        foreach (var line in lines)
        {
            if (line.StartsWith("->") && line.Length > 3 && char.IsDigit(line[2]))
            {
                output.Add(line);
                lineCount = 0;
                int dashIndex = line.IndexOf('-', 3);
                if (dashIndex >= 0 && dashIndex + 1 < line.Length)
                    Heading = line.Substring(dashIndex + 1).Trim();
                continue;
            }

            if (lineCount == 0 && Heading == "Stats")
                output.Add($"->{page} - {Heading}");

            if (lineCount >= maxLinesPerPage)
            {
                page++;
                output.Add($"->{page} - {Heading}");
                lineCount = 0;
            }

            output.Add(line);
            lineCount++;
        }
        return output;

     }

    public void Open(CCSPlayerController player, string content, int page = 0,
                     Dictionary<string, Action<CCSPlayerController>>? callbacks = null, bool pushHistory = true)
    {
        var steamId = player.SteamID;
        if (!_menuHistory.TryGetValue(steamId, out var stack))
        {
            stack = new Stack<(string, int, Dictionary<string, Action<CCSPlayerController>>?)>();
            _menuHistory[steamId] = stack;
        }

        var rawLines = NormalizeContent(content,MaxLines);
        var _lastPages = PartitionPages(rawLines.ToArray());

        var pages = _lastPages!;
        var totalPages = pages.Count;

        if (totalPages == 0)
        {
            DestroyMenu(player);
            return;
        }

        page = Math.Clamp(page, 0, totalPages - 1);

        if (pushHistory && (stack.Count == 0 || stack.Peek().Content != content || stack.Peek().Page != page))
        {
            _selectedIndex[steamId] = 0;
            stack.Push((content, page, callbacks));
        }

        var pageLines = pages[page];
        var heading = NormalizeHeading(pageLines.FirstOrDefault());
        var displayLines = pageLines.Skip(1).ToArray();

        _menuPages[steamId] = page;
        if (!_selectedIndex.ContainsKey(steamId))
            _selectedIndex[steamId] = 0;

        if (displayLines.Length == 0)
            _selectedIndex[steamId] = 0;

        string main = $"<font color='#FFFFFF'><b>HLstats</b></font><font color='#FF2A2A'><b>Z</b></font>" +
                      $"<font color='#F0E68C'> - {heading}</font>"+
                      $"<font color='#FFFACD'> (Page {page + 1}/{totalPages})</font><br>";

        var options = new List<(string, Action<CCSPlayerController>)>();

        for (int i = 0; i < displayLines.Length; i++)
        {
            var cleanLine = displayLines[i].Trim();
            if (heading == "Top Players" || heading == "Next Players")
            {
                var match = Regex.Match(cleanLine, @"^(?<num>\d{2})\s+(?<rest>.+)$");
                if (match.Success)
                {
                    if (int.TryParse(match.Groups["num"].Value, out int n))
                    {
                        cleanLine = $"{n}. {match.Groups["rest"].Value}";
                    }
                }
            }

            if (callbacks != null && callbacks.TryGetValue(cleanLine, out var cb))
            {
                options.Add((cleanLine, cb));
                if (cb == HLZMenuBuilder.NoOpCallback && i == _selectedIndex[player.SteamID])
                   _selectedIndex[player.SteamID]++;
            }
            else
            {
                options.Add((cleanLine, HLZMenuBuilder.NoOpCallback));
                if (i == _selectedIndex[player.SteamID])
                   _selectedIndex[player.SteamID]++;
            }

            main += (i == _selectedIndex[steamId]
                ? $"<font color='#00FF00'>⫸ {cleanLine} ⫷</font><br>"
                : $"<font color='#DCDCDC'>{cleanLine}</font><br>");

        }

        var spaces = 6-displayLines.Length;
        for (int i = 0; i < spaces; i++)
        {
            main += "<br>";
        }

        var closeLabel = "[ Close ]";
        var closeIndex = displayLines.Length;

        var maxIndex = closeIndex;
        _selectedIndex[steamId] = Math.Clamp(_selectedIndex[steamId], 0, maxIndex);

        if (displayLines.Length == 0)
            _selectedIndex[steamId] = closeIndex;

        main += (_selectedIndex[steamId] == closeIndex
            ? $"<font color='#FFFACD' class='fontSize-sm'>WASD Nav</font>{Nbsp(3)}<font color='#00FF00'>⫸ {closeLabel} ⫷</font>{Nbsp(3)}<font color='#FFFACD' class='fontSize-sm'>E Select</font>{Nbsp(3)}<br>"
            : $"<font color='#FFFACD' class='fontSize-sm'>WASD Nav</font>{Nbsp(8)}<font color='#FF2A2A'>{closeLabel}</font>{Nbsp(8)}<font color='#FFFACD' class='fontSize-sm'>E Select</font>{Nbsp(3)}<br>");

        options.Add((closeLabel, p => DestroyMenu(p)));

        _pageOptions[steamId] = options;

        var menu = new CenterHtmlMenu(main, _plugin) { ExitButton = false };
        _activeMenus[steamId] = (player, menu);

        menu.Open(player);
        StartMenuInputTimer(player);

        if (heading.Contains("Cast Vote", StringComparison.OrdinalIgnoreCase))
        {
            player.UnFreeze();
        } else {
            player.Freeze();
        }
    }

    public void DestroyMenu(CCSPlayerController player)
    {
        if (player == null || !player.IsValid) return;

        player.UnFreeze();

        if (_activeMenus.TryGetValue(player.SteamID, out var menu))
        {
            MenuManager.CloseActiveMenu(player);
            _lastButtons.Remove(player.SteamID);
            _activeMenus.Remove(player.SteamID);
            _pageOptions.Remove(player.SteamID);
            _menuPages.Remove(player.SteamID);
            _selectedIndex.Remove(player.SteamID);
            _menuHistory.Remove(player.SteamID);
        }
    }

    public void RewindToLabel(CCSPlayerController player, string label, bool open = false)
    {
        var steamId = player.SteamID;
        if (!_menuHistory.TryGetValue(steamId, out var stack) || stack.Count == 0)
            return;

        while (stack.Count > 0)
        {
            var (content, page, callbacks) = stack.Peek();
            var heading = NormalizeHeading(content.Split('\n').FirstOrDefault());

            if (heading.Contains(label, StringComparison.OrdinalIgnoreCase))
            {
                stack.Pop();
                break;
            }
            stack.Pop();
        }

        if (open && stack.Count > 0)
        {
            var (prevContent, prevPage, prevCallbacks) = stack.Peek();
            Open(player, prevContent, prevPage, prevCallbacks, pushHistory: false);
        }
    }

    public void HandleBack(CCSPlayerController player, bool open = true)
    {
        var steamId = player.SteamID;
        if (!_menuHistory.TryGetValue(steamId, out var stack) || stack.Count <= 1)
            return;

        stack.Pop(); // remove current
        _selectedIndex[steamId] = 0;
        var (prevContent, prevPage, prevCallbacks) = stack.Peek();
        if (open)
            Open(player, prevContent, prevPage, prevCallbacks, pushHistory: false);
    }

    public void HandlePage(CCSPlayerController player, int delta)
    {
        var steamId = player.SteamID;
        if (!_menuPages.TryGetValue(steamId, out var currentPage))
            currentPage = 0;

        var newPage = Math.Max(0, currentPage + delta);

        if (_menuHistory.TryGetValue(steamId, out var stack))
        {
            var (content, _, callbacks) = stack.Peek();
            Open(player, content, newPage, callbacks);
        }
    }

    public void HandleNavigation(CCSPlayerController player, int delta)
    {
        var steamId = player.SteamID;

        if (!_selectedIndex.TryGetValue(steamId, out var index))
            index = 0;

        if (!_pageOptions.TryGetValue(steamId, out var opts) || opts.Count == 0)
            return;

        var count = opts.Count;
        var startIndex = index;

        for (int i = 0; i < count; i++)
        {
            index = (index + delta + count) % count;

            var (_, cb) = opts[index];
            if (cb != HLZMenuBuilder.NoOpCallback)
                break;
        }

        _selectedIndex[steamId] = index;

        var page = _menuPages.TryGetValue(steamId, out var p) ? p : 0;

        if (_menuHistory.TryGetValue(steamId, out var stack))
        {
            var (content, _, callbacks) = stack.Peek();
            Open(player, content, page, callbacks, pushHistory: false);
        }
    }


    public void HandleSelect(CCSPlayerController player)
    {
        var steamId = player.SteamID;
        if (!_selectedIndex.TryGetValue(steamId, out var index)) return;
        if (!_pageOptions.TryGetValue(steamId, out var options)) return;

        if (index >= 0 && index < options.Count)
        {
            var (_, cb) = options[index];
            cb(player);
        }
    }
}

public class HLZMenuBuilder
{
    private readonly string _title;
    public readonly List<(string Label, Action<CCSPlayerController> Callback)> _items = new();
    public static readonly Action<CCSPlayerController> NoOpCallback = _ => { };
    private bool _Numbered = true;

    public HLZMenuBuilder(string title)
    {
        _title = title;
    }

    public HLZMenuBuilder Add(string label, Action<CCSPlayerController> callback)
    {
        _items.Add((label, callback));
        return this;
    }

    public HLZMenuBuilder AddNoOp(string label)
    {
        _items.Add((label, NoOpCallback));
        return this;
    }

    public HLZMenuBuilder NoNumber()
    {
        _Numbered = false;
        return this;
    }

    public void Open(CCSPlayerController player, HLZMenuManager menuManager)
    {
        int MaxLines = menuManager.MaxLines;
        var page = 0;
        var index = 1;
        var content = $"->{page + 1} - {_title}";
        var callbacks = new Dictionary<string, Action<CCSPlayerController>>(StringComparer.OrdinalIgnoreCase);

        for (int i = 0; i < _items.Count; i++)
        {
            if (i > 0 && i % MaxLines == 0)
            {
                page++;
                content += $"\n->{page + 1} - {_title}";
            }

            var (label, cb) = _items[i];
            var line = _Numbered? $"{index}. {label}" : $"{label}";
            content += $"\n{line}";
            callbacks.Add(line, cb);
            index++;
        }
        menuManager.Open(player, content, 0, callbacks, true);
    }

}

public static class CCSPlayerControllerExtensions
{
    public static void Freeze(this CCSPlayerController player, int mode = 1)
    {
        var pawn = player.PlayerPawn.Value;
        if (pawn == null) return;

        switch (mode)
        {
            case 1: pawn.ChangeMovetype(MoveType_t.MOVETYPE_OBSOLETE); break;
            case 2: pawn.ChangeMovetype(MoveType_t.MOVETYPE_NONE); break;
            case 3: pawn.ChangeMovetype(MoveType_t.MOVETYPE_INVALID); break;
            default: pawn.ChangeMovetype(MoveType_t.MOVETYPE_NONE); break;
        }
    }

    public static void UnFreeze(this CCSPlayerController player)
    {
        var pawn = player.PlayerPawn.Value;
        if (pawn == null) return;

        pawn.ChangeMovetype(MoveType_t.MOVETYPE_WALK);
    }

    private static void ChangeMovetype(this CBasePlayerPawn pawn, MoveType_t movetype)
    {
        pawn.MoveType = movetype;
        Schema.SetSchemaValue(
            pawn.Handle, "CBaseEntity", "m_nActualMoveType", movetype
        );
        Utilities.SetStateChanged(pawn, "CBaseEntity", "m_MoveType");
    }
}
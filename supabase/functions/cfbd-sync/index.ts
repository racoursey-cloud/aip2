// AI Pickens weekly CFBD sync. Invoked by pg_cron (Mondays 09:00 UTC) or manually.
// Body: {"job":"weekly"} | {"job":"<domain>","season":2026}
//
// CARRIED VERBATIM FROM THE PREVIOUS PROJECT AT GENESIS. IT DOES NOT WORK — see README.md
// in this directory. stageFlush() writes to public.stage_json and calls public.flush_json /
// public.flush_drives, none of which exist in either project. The live weekly sync is
// cfb.enqueue_weekly_sync() + cfb.process_sync_responses(), driven by pg_cron and pg_net.
// This file is here so the code lives in the repository rather than only in a deployment,
// and so the decision to repair or retire it is made deliberately.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

const API = "https://api.collegefootballdata.com";
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
let CALLS = 0;
let CFBD_KEY = "";

async function fetchApi(path: string, params: Record<string, unknown> = {}): Promise<any[]> {
  const qs = new URLSearchParams(Object.entries(params).filter(([, v]) => v != null).map(([k, v]) => [k, String(v)]));
  const url = `${API}${path}${qs.toString() ? "?" + qs : ""}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch(url, { headers: { Authorization: `Bearer ${CFBD_KEY}`, Accept: "application/json" } });
      CALLS++;
      if (r.status === 400) { await r.body?.cancel(); return []; }
      if (!r.ok) { await r.body?.cancel(); throw new Error(`HTTP ${r.status}`); }
      const data = await r.json();
      await new Promise((res) => setTimeout(res, 250));
      return Array.isArray(data) ? data : [];
    } catch (e) {
      if (attempt === 2) throw e;
      await new Promise((res) => setTimeout(res, 5000 * (attempt + 1)));
    }
  }
  return [];
}

async function stageFlush(domain: string, recs: unknown[], flushFn = "flush_json"): Promise<number> {
  if (!recs.length) return 0;
  let moved = 0;
  for (let i = 0; i < recs.length; i += 5000) {
    const chunk = recs.slice(i, i + 5000);
    await sql`insert into public.stage_json (domain, payload) select ${domain}, jsonb_array_elements(${sql.json(chunk)})`;
    const res = flushFn === "flush_drives"
      ? await sql`select public.flush_drives() as n`
      : await sql`select public.flush_json(${domain}) as n`;
    moved += Number(res[0].n);
  }
  return moved;
}

const g = (d: any, ...keys: string[]) => { for (const k of keys) if (d && d[k] != null) return d[k]; return null; };
const dedupe = (recs: any[], ...keys: string[]) => {
  const m = new Map<string, any>();
  for (const r of recs) m.set(keys.map((k) => r[k]).join("|"), r);
  return [...m.values()];
};

async function logRun(job: string, season: number | null, status: string, rows: number, calls: number, detail: unknown = null) {
  await sql`insert into cfb.sync_log (job, season, status, rows_affected, api_calls, finished_at, detail)
            values (${job}, ${season}, ${status}, ${rows}, ${calls}, now(), ${detail ? JSON.stringify(detail) : null})`;
}

// ---- domain transforms (mirror the backfill contracts) ----
const tGame = (r: any) => ({
  game_id: g(r, "id"), season: g(r, "season"), week: g(r, "week"), season_type: g(r, "seasonType"),
  start_date: g(r, "startDate"), start_time_tbd: g(r, "startTimeTBD", "startTimeTbd"), completed: g(r, "completed"),
  neutral_site: g(r, "neutralSite"), conference_game: g(r, "conferenceGame"), attendance: g(r, "attendance"),
  venue_id: g(r, "venueId"), venue: g(r, "venue"),
  home_id: g(r, "homeId"), home_team: g(r, "homeTeam"), home_division: g(r, "homeClassification", "homeDivision"),
  home_conference: g(r, "homeConference"), home_points: g(r, "homePoints"), home_line_scores: g(r, "homeLineScores"),
  home_post_win_prob: g(r, "homePostgameWinProbability"), home_pregame_elo: g(r, "homePregameElo"), home_postgame_elo: g(r, "homePostgameElo"),
  away_id: g(r, "awayId"), away_team: g(r, "awayTeam"), away_division: g(r, "awayClassification", "awayDivision"),
  away_conference: g(r, "awayConference"), away_points: g(r, "awayPoints"), away_line_scores: g(r, "awayLineScores"),
  away_post_win_prob: g(r, "awayPostgameWinProbability"), away_pregame_elo: g(r, "awayPregameElo"), away_postgame_elo: g(r, "awayPostgameElo"),
  excitement_index: g(r, "excitementIndex"), highlights: g(r, "highlights"), notes: g(r, "notes"),
});

const tPlay = (r: any, season: number, week: number, st: string) => {
  const clock = g(r, "clock") || {};
  return {
    play_id: g(r, "id"), game_id: g(r, "gameId"), drive_id: g(r, "driveId"), drive_number: g(r, "driveNumber"),
    play_number: g(r, "playNumber"), season, week, season_type: st,
    offense: g(r, "offense"), defense: g(r, "defense"), home: g(r, "home"), away: g(r, "away"),
    period: g(r, "period"), clock_minutes: g(clock, "minutes"), clock_seconds: g(clock, "seconds"),
    down: g(r, "down"), distance: g(r, "distance"), yards_to_goal: g(r, "yardsToGoal"), yards_gained: g(r, "yardsGained"),
    yard_line: g(r, "yardline", "yardLine"), play_type: g(r, "playType"), play_text: g(r, "playText"),
    scoring: g(r, "scoring"), ppa: g(r, "ppa"), offense_score: g(r, "offenseScore"), defense_score: g(r, "defenseScore"),
    offense_timeouts: g(r, "offenseTimeouts"), defense_timeouts: g(r, "defenseTimeouts"), wallclock: g(r, "wallclock"),
  };
};

const tDrive = (r: any) => ({
  drive_id: g(r, "id"), game_id: g(r, "gameId"), drive_number: g(r, "driveNumber"),
  offense: g(r, "offense"), defense: g(r, "defense"), is_home_offense: g(r, "isHomeOffense"),
  scoring: g(r, "scoring"), start_period: g(r, "startPeriod"), end_period: g(r, "endPeriod"),
  start_yards_to_goal: g(r, "startYardsToGoal"), end_yards_to_goal: g(r, "endYardsToGoal"),
  yards: g(r, "yards"), plays: g(r, "plays", "playCount"), result: g(r, "driveResult"),
  start_offense_score: g(r, "startOffenseScore"), start_defense_score: g(r, "startDefenseScore"),
  end_offense_score: g(r, "endOffenseScore"), end_defense_score: g(r, "endDefenseScore"),
  time_minutes_elapsed: g(g(r, "elapsed") || {}, "minutes"), time_seconds_elapsed: g(g(r, "elapsed") || {}, "seconds"),
});

function currentSeason(now: Date): number {
  const m = now.getUTCMonth() + 1;
  return m >= 8 ? now.getUTCFullYear() : now.getUTCFullYear() - 1;
}

async function currentWeeks(season: number, now: Date): Promise<Array<[number, string]>> {
  const cal = await fetchApi("/calendar", { year: season });
  const t = now.getTime();
  const done: Array<[number, string]> = [];
  for (const w of cal) {
    const start = new Date(g(w, "startDate", "firstGameStart") ?? 0).getTime();
    if (start <= t) done.push([g(w, "week"), g(w, "seasonType") || "regular"]);
  }
  return done.slice(-2); // current + previous week window
}

async function runWeekly(now: Date) {
  const season = currentSeason(now);
  const recruitYear = season + 1;
  const steps: Array<[string, number | null, () => Promise<number>]> = [
    ["games", season, async () => stageFlush("games_api", (await fetchApi("/games", { year: season, seasonType: "both" })).map(tGame).filter((r) => r.game_id != null))],
    ["games_next", season + 1, async () => stageFlush("games_api", (await fetchApi("/games", { year: season + 1, seasonType: "both" })).map(tGame).filter((r) => r.game_id != null))],
    ["plays", season, async () => {
      const weeks = await currentWeeks(season, now);
      let n = 0;
      for (const [wk, st] of weeks) {
        const data = await fetchApi("/plays", { year: season, week: wk, seasonType: st });
        n += await stageFlush("plays_api", data.map((r) => tPlay(r, season, wk, st)).filter((r) => r.play_id != null && r.game_id != null));
      }
      return n;
    }],
    ["drives", season, async () => stageFlush("drives_api", dedupe((await fetchApi("/drives", { year: season })).map(tDrive).filter((r) => r.drive_id != null), "drive_id"), "flush_drives")],
    ["lines", season, async () => {
      const data = await fetchApi("/lines", { year: season });
      const recs: any[] = [];
      for (const game of data) for (const ln of (g(game, "lines") || [])) recs.push({
        game_id: g(game, "id"), season: g(game, "season"), week: g(game, "week"), season_type: g(game, "seasonType"),
        home_team: g(game, "homeTeam"), away_team: g(game, "awayTeam"), provider: g(ln, "provider") || "unknown",
        spread: g(ln, "spread"), spread_open: g(ln, "spreadOpen"), over_under: g(ln, "overUnder"), over_under_open: g(ln, "overUnderOpen"),
        home_moneyline: g(ln, "homeMoneyline"), away_moneyline: g(ln, "awayMoneyline"), formatted_spread: g(ln, "formattedSpread"),
      });
      return stageFlush("lines", dedupe(recs, "game_id", "provider"));
    }],
    ["rankings", season, async () => {
      const data = await fetchApi("/rankings", { year: season });
      const recs: any[] = [];
      for (const wk of data) for (const poll of (g(wk, "polls") || [])) for (const rk of (g(poll, "ranks") || [])) recs.push({
        season: g(wk, "season"), season_type: g(wk, "seasonType"), week: g(wk, "week"), poll: g(poll, "poll"),
        rank: g(rk, "rank"), school: g(rk, "school"), conference: g(rk, "conference"),
        first_place_votes: g(rk, "firstPlaceVotes"), points: g(rk, "points"),
      });
      return stageFlush("poll_ranks", recs.filter((r) => r.school));
    }],
    ["sp", season, async () => stageFlush("sp", dedupe((await fetchApi("/ratings/sp", { year: season })).filter((r) => g(r, "team")).map((r) => ({ season: g(r, "year") ?? season, team: g(r, "team"), conference: g(r, "conference"), rating: g(r, "rating"), ranking: g(r, "ranking"), second_order_wins: g(r, "secondOrderWins"), sos: g(r, "sos"), offense_rating: g(g(r, "offense") || {}, "rating"), defense_rating: g(g(r, "defense") || {}, "rating"), special_teams_rating: g(g(r, "specialTeams") || {}, "rating"), raw: r })), "season", "team"))],
    ["srs", season, async () => stageFlush("srs", dedupe((await fetchApi("/ratings/srs", { year: season })).filter((r) => g(r, "team")).map((r) => ({ season: g(r, "year") ?? season, team: g(r, "team"), conference: g(r, "conference"), division: g(r, "division"), rating: g(r, "rating"), ranking: g(r, "ranking") })), "season", "team"))],
    ["elo", season, async () => stageFlush("elo", dedupe((await fetchApi("/ratings/elo", { year: season })).filter((r) => g(r, "team")).map((r) => ({ season: g(r, "year") ?? season, team: g(r, "team"), conference: g(r, "conference"), elo: g(r, "elo") })), "season", "team"))],
    ["fpi", season, async () => stageFlush("fpi", dedupe((await fetchApi("/ratings/fpi", { year: season })).filter((r) => g(r, "team")).map((r) => ({ season: g(r, "year") ?? season, team: g(r, "team"), conference: g(r, "conference"), fpi: g(r, "fpi"), ranking: g(g(r, "resumeRanks") || {}, "fpi"), raw: r })), "season", "team"))],
    ["talent", season, async () => stageFlush("talent", dedupe((await fetchApi("/talent", { year: season })).filter((r) => g(r, "team", "school")).map((r) => ({ season: g(r, "year") ?? season, team: g(r, "team", "school"), talent: g(r, "talent") })), "season", "team"))],
    ["wepa", season, async () => stageFlush("wepa", dedupe((await fetchApi("/wepa/team/season", { year: season })).filter((r) => g(r, "team")).map((r) => ({ season: g(r, "year", "season") ?? season, team: g(r, "team"), conference: g(r, "conference"), raw: r })), "season", "team"))],
    ["ppa_teams", season, async () => stageFlush("ppa_teams", dedupe((await fetchApi("/ppa/teams", { year: season })).filter((r) => g(r, "team")).map((r) => ({ season: g(r, "season") ?? season, team: g(r, "team"), conference: g(r, "conference"), offense_overall: g(g(r, "offense") || {}, "overall"), defense_overall: g(g(r, "defense") || {}, "overall"), raw: r })), "season", "team"))],
    ["ppa_players", season, async () => stageFlush("ppa_players", dedupe((await fetchApi("/ppa/players/season", { year: season })).filter((r) => g(r, "name")).map((r) => ({ season: g(r, "season") ?? season, player_id: String(g(r, "id") ?? ""), player: g(r, "name"), team: g(r, "team"), conference: g(r, "conference"), position: g(r, "position"), avg_ppa_all: g(g(r, "averagePPA") || {}, "all"), avg_ppa_pass: g(g(r, "averagePPA") || {}, "pass"), avg_ppa_rush: g(g(r, "averagePPA") || {}, "rush"), total_ppa_all: g(g(r, "totalPPA") || {}, "all"), raw: r })), "season", "player_id", "team"))],
    ["team_stats", season, async () => stageFlush("team_stats_season", dedupe((await fetchApi("/stats/season", { year: season })).filter((r) => g(r, "team") && g(r, "statName")).map((r) => ({ season: g(r, "season") ?? season, team: g(r, "team"), conference: g(r, "conference"), stat_name: g(r, "statName"), stat_value: g(r, "statValue") })), "season", "team", "stat_name"))],
    ["player_stats", season, async () => stageFlush("player_stats_season", dedupe((await fetchApi("/stats/player/season", { year: season })).filter((r) => g(r, "player")).map((r) => ({ season: g(r, "season") ?? season, player_id: String(g(r, "playerId") ?? ""), player: g(r, "player"), team: g(r, "team"), conference: g(r, "conference"), category: g(r, "category"), stat_type: g(r, "statType"), stat: g(r, "stat") })), "season", "player_id", "team", "category", "stat_type"))],
    ["weather", season, async () => stageFlush("weather", dedupe((await fetchApi("/games/weather", { year: season })).filter((r) => g(r, "id", "gameId") != null).map((r) => ({ game_id: g(r, "id", "gameId"), season: g(r, "season") ?? season, week: g(r, "week"), temperature: g(r, "temperature"), dewpoint: g(r, "dewPoint", "dewpoint"), humidity: g(r, "humidity"), precipitation: g(r, "precipitation"), snowfall: g(r, "snowfall"), wind_direction: g(r, "windDirection"), wind_speed: g(r, "windSpeed"), pressure: g(r, "pressure"), weather_condition: g(r, "weatherCondition"), raw: r })), "game_id"))],
    ["portal", recruitYear, async () => {
      let n = 0;
      for (const y of [season, recruitYear]) {
        const data = await fetchApi("/player/portal", { year: y });
        // replace-then-insert keeps portal current (rows have no natural key)
        if (data.length) await sql`delete from cfb.portal where season = ${y}`;
        n += await stageFlush("portal", data.map((r) => ({ season: g(r, "season") ?? y, first_name: g(r, "firstName"), last_name: g(r, "lastName"), position: g(r, "position"), origin: g(r, "origin"), destination: g(r, "destination"), transfer_date: g(r, "transferDate"), rating: g(r, "rating"), stars: g(r, "stars"), eligibility: g(r, "eligibility") })));
      }
      return n;
    }],
    ["recruits", recruitYear, async () => stageFlush("recruits", (await fetchApi("/recruiting/players", { year: recruitYear })).filter((r) => g(r, "name")).map((r) => ({ cfbd_id: g(r, "id"), athlete_id: g(r, "athleteId"), recruit_type: g(r, "recruitType"), year: g(r, "year") ?? recruitYear, ranking: g(r, "ranking"), name: g(r, "name"), school: g(r, "school"), committed_to: g(r, "committedTo"), position: g(r, "position"), height: g(r, "height"), weight: g(r, "weight"), stars: g(r, "stars"), rating: g(r, "rating"), city: g(r, "city"), state_province: g(r, "stateProvince"), country: g(r, "country"), latitude: g(g(r, "hometownInfo") || {}, "latitude"), longitude: g(g(r, "hometownInfo") || {}, "longitude") })))],
    ["rec_teams", recruitYear, async () => stageFlush("recruiting_teams", dedupe((await fetchApi("/recruiting/teams", { year: recruitYear })).filter((r) => g(r, "team")).map((r) => ({ year: g(r, "year") ?? recruitYear, rank: g(r, "rank"), team: g(r, "team"), points: g(r, "points") })), "year", "team"))],
  ];

  const results: Record<string, unknown> = {};
  for (const [name, season_, fn] of steps) {
    const before = CALLS;
    try {
      const rows = await fn();
      await logRun(`weekly:${name}`, season_, "ok", rows, CALLS - before);
      results[name] = rows;
    } catch (e) {
      await logRun(`weekly:${name}`, season_, "error", 0, CALLS - before, { error: String(e) });
      results[name] = `ERROR: ${e}`;
    }
  }
  return { season, api_calls: CALLS, results };
}

Deno.serve(async (req: Request) => {
  try {
    const body = await req.json().catch(() => ({}));
    const keyRow = await sql`select decrypted_secret from vault.decrypted_secrets where name = 'cfbd_api_key'`;
    CFBD_KEY = keyRow[0]?.decrypted_secret ?? "";
    if (!CFBD_KEY) return new Response(JSON.stringify({ error: "no cfbd key in vault" }), { status: 500 });
    await sql`set statement_timeout = '300s'`;
    const now = new Date();
    const job = body.job ?? "weekly";
    if (job === "weekly") {
      const out = await runWeekly(now);
      return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
    }
    return new Response(JSON.stringify({ error: `unknown job ${job}` }), { status: 400 });
  } catch (e) {
    try { await logRun("weekly", null, "fatal", 0, CALLS, { error: String(e) }); } catch (_) { /* noop */ }
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

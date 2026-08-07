-- Genesis Job 2 spot-checks: three known facts, asserted rather than eyeballed.
-- Every expected value here was read off the source database before the transfer ran,
-- so a pass means the restored data agrees with the source on facts a human can recognise.
-- Any failure raises and takes the run down with it.

\echo ''
\echo '--- spot-check 1: the Georgia Southern / Georgia State series is 6-6 over 12 meetings'
select count(*) as meetings,
       min(season) as first_season,
       max(season) as last_season,
       count(*) filter (where (home_team = 'Georgia Southern' and home_points > away_points)
                           or (away_team = 'Georgia Southern' and away_points > home_points)) as gso_wins,
       count(*) filter (where (home_team = 'Georgia State' and home_points > away_points)
                           or (away_team = 'Georgia State' and away_points > home_points)) as gst_wins
from cfb.games
where ((home_team = 'Georgia Southern' and away_team = 'Georgia State')
    or (home_team = 'Georgia State' and away_team = 'Georgia Southern'))
  and completed;

do $$
declare m int; gso int; gst int;
begin
  select count(*),
         count(*) filter (where (home_team = 'Georgia Southern' and home_points > away_points)
                             or (away_team = 'Georgia Southern' and away_points > home_points)),
         count(*) filter (where (home_team = 'Georgia State' and home_points > away_points)
                             or (away_team = 'Georgia State' and away_points > home_points))
    into m, gso, gst
  from cfb.games
  where ((home_team = 'Georgia Southern' and away_team = 'Georgia State')
      or (home_team = 'Georgia State' and away_team = 'Georgia Southern'))
    and completed;
  if m <> 12 or gso <> 6 or gst <> 6 then
    raise exception 'spot-check 1 FAILED: expected 12 meetings 6-6, got % meetings %-%', m, gso, gst;
  end if;
  raise notice 'spot-check 1 PASS: % meetings, %-%', m, gso, gst;
end $$;

\echo ''
\echo '--- spot-check 2: the 2026-11-14 rivalry game exists (Georgia Southern at Georgia State)'
select start_date, home_team, away_team, venue
from cfb.games
where start_date::date = date '2026-11-14'
  and home_team = 'Georgia State' and away_team = 'Georgia Southern';

do $$
declare n int; v text;
begin
  select count(*), max(venue) into n, v
  from cfb.games
  where start_date::date = date '2026-11-14'
    and home_team = 'Georgia State' and away_team = 'Georgia Southern';
  if n <> 1 then
    raise exception 'spot-check 2 FAILED: expected exactly 1 Nov 14 2026 rivalry game, got %', n;
  end if;
  if v is distinct from 'Center Parc Stadium' then
    raise exception 'spot-check 2 FAILED: expected Center Parc Stadium, got %', v;
  end if;
  raise notice 'spot-check 2 PASS: % game at %', n, v;
end $$;

\echo ''
\echo '--- spot-check 3: Georgia Southern 2013 shows exactly one game, the win at Florida'
select season, week, start_date, home_team, home_points, away_team, away_points, venue
from cfb.games
where season = 2013 and (home_team = 'Georgia Southern' or away_team = 'Georgia Southern');

do $$
declare n int; hp int; ap int; ht text;
begin
  select count(*) into n
  from cfb.games
  where season = 2013 and (home_team = 'Georgia Southern' or away_team = 'Georgia Southern');
  if n <> 1 then
    raise exception 'spot-check 3 FAILED: expected exactly 1 Georgia Southern game in 2013, got %', n;
  end if;
  select home_team, home_points, away_points into ht, hp, ap
  from cfb.games
  where season = 2013 and away_team = 'Georgia Southern';
  if ht is distinct from 'Florida' or ap is null or hp is null or ap <= hp then
    raise exception 'spot-check 3 FAILED: expected a Georgia Southern win at Florida, got % % - Georgia Southern %', ht, hp, ap;
  end if;
  raise notice 'spot-check 3 PASS: Georgia Southern % at Florida %', ap, hp;
end $$;

\echo ''
\echo '--- context: 2026 season game count (pinned at 1,638)'
select count(*) as games_2026 from cfb.games where season = 2026;

do $$
declare n int;
begin
  select count(*) into n from cfb.games where season = 2026;
  if n <> 1638 then
    raise warning 'FINDING: 2026 season has % games, pinned at 1,638', n;
  else
    raise notice '2026 season PASS: % games', n;
  end if;
end $$;

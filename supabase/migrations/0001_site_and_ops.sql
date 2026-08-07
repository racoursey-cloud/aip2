-- 0001_site_and_ops.sql
-- Genesis, Job 3. The publication's own data (`site`) and its operating state (`ops`).
--
-- Two deliberate design decisions, both worth stating because a later reader will wonder:
--
--  1. NO FOREIGN KEYS INTO cfb. Columns named game_id reference cfb.games logically, but
--     carry no FK constraint. cfb arrives in this project by pg_restore, not by migration,
--     so a migration that depended on it could not be applied to an empty database — and
--     "the repo can rebuild the database" is the property this whole design is built on.
--     ci.yml proves that property on every push by applying this file to an empty postgres.
--
--  2. site.picks IS INSERT-ONLY, ENFORCED. A pick records what was believed and what the
--     market said at the moment it was made. Rewriting one is falsifying the record, so a
--     trigger rejects UPDATE and DELETE outright. Grades are therefore not stored on the
--     pick: they are derived from the frozen line plus the final score whenever anyone
--     asks. That view lands in a later migration, once cfb is present.
--
-- RLS is deny-all everywhere: row security is enabled and NO policies are created, so
-- anon and authenticated can read nothing. The server reaches this data as service_role,
-- which carries BYPASSRLS.
--
-- This file contains no BEGIN/COMMIT: Supabase's migration runner wraps it, and ci.yml
-- applies it with psql --single-transaction, so it is atomic either way without the two
-- transaction layers fighting.

create schema if not exists site;
create schema if not exists ops;

comment on schema site is 'The publication: editions, pieces, briefs, observations, picks.';
comment on schema ops  is 'Operating state: working rules, session log, rulings.';

-- ===========================================================================
-- site
-- ===========================================================================

-- A week of the publication. The weekly loop hangs off this row.
create table site.editions (
  edition_id    bigint generated always as identity primary key,
  season        integer not null,
  week          integer not null,
  season_type   text    not null default 'regular'
                  check (season_type in ('regular','postseason')),
  title         text,
  status        text    not null default 'planned'
                  check (status in ('planned','assembling','published','archived')),
  opens_at      timestamptz,
  published_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (season, week, season_type)
);
comment on table site.editions is 'One row per publishing week.';

-- Tuesday: the assembled brief that the week's writing is built from.
create table site.briefs (
  brief_id      bigint generated always as identity primary key,
  edition_id    bigint not null references site.editions(edition_id) on delete cascade,
  game_id       bigint,                       -- logical ref to cfb.games; see header note 1
  headline      text,
  payload       jsonb  not null default '{}'::jsonb,
  sources       jsonb  not null default '[]'::jsonb,
  assembled_at  timestamptz not null default now(),
  assembled_by  text,
  created_at    timestamptz not null default now()
);
create index on site.briefs (edition_id);
create index on site.briefs (game_id);
comment on column site.briefs.payload is 'The assembled inputs: cfb pulls, availability, presser material.';

-- The written article. Thursday pregame, Sunday postgame, Monday notebook.
create table site.pieces (
  piece_id      bigint generated always as identity primary key,
  edition_id    bigint not null references site.editions(edition_id) on delete cascade,
  brief_id      bigint references site.briefs(brief_id) on delete set null,
  game_id       bigint,                       -- logical ref to cfb.games
  kind          text not null
                  check (kind in ('pregame','postgame','notebook','feature')),
  headline      text not null,
  dek           text,
  body_md       text,
  byline        text,
  status        text not null default 'draft'
                  check (status in ('draft','review','published','spiked')),
  published_at  timestamptz,
  -- Al grades himself against the editorial standard; the grades accumulate here.
  self_grade    numeric(4,2) check (self_grade is null or self_grade between 0 and 10),
  grade_notes   text,
  graded_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on site.pieces (edition_id);
create index on site.pieces (game_id);
create index on site.pieces (kind, status);

-- Saturday: what a human actually saw. The anti-hallucination feed — scene gets written
-- only from what somebody watched happen.
create table site.observations (
  observation_id bigint generated always as identity primary key,
  edition_id     bigint references site.editions(edition_id) on delete set null,
  game_id        bigint,                      -- logical ref to cfb.games
  observer       text not null,
  observed_at    timestamptz not null default now(),
  period         integer,
  clock          text,
  note           text not null,
  tags           text[] not null default '{}',
  created_at     timestamptz not null default now()
);
create index on site.observations (game_id, observed_at);
create index on site.observations (edition_id);
comment on table site.observations is
  'Timestamped human observation. Editorial standard marks anything sourced here as "observed".';

-- Thursday: the picks, with the market frozen at pick time. INSERT-ONLY, enforced below.
create table site.picks (
  pick_id        bigint generated always as identity primary key,
  edition_id     bigint not null references site.editions(edition_id),
  game_id        bigint not null,             -- logical ref to cfb.games
  pick_type      text not null
                   check (pick_type in ('straight','spread','total')),
  selection      text not null,               -- team taken, or 'over' / 'under'
  -- the market at the moment of the pick; never revised
  line_provider  text,
  spread         numeric(6,2),
  over_under     numeric(6,2),
  moneyline      integer,
  confidence     integer check (confidence is null or confidence between 1 and 5),
  rationale      text,
  engine_version text,
  picked_at      timestamptz not null default now(),
  picked_by      text not null default 'engine',
  unique (edition_id, game_id, pick_type)
);
create index on site.picks (game_id);
comment on table site.picks is
  'Insert-only. The line is frozen at pick time; grades are derived, never written back.';

create or replace function site.reject_mutation() returns trigger
language plpgsql as $fn$
begin
  raise exception
    'site.picks is insert-only: % rejected. A pick records what was believed and what the market said at that moment; rewriting one falsifies the record.',
    tg_op;
end;
$fn$;

create trigger picks_no_update before update on site.picks
  for each row execute function site.reject_mutation();
create trigger picks_no_delete before delete on site.picks
  for each row execute function site.reject_mutation();

-- ===========================================================================
-- ops
-- ===========================================================================

-- The rules, each bought by an incident. The incident travels with the rule: a rule
-- without its incident gets argued with.
create table ops.working_rules (
  rule_id     text primary key,
  ordinal     integer not null unique,
  rule        text not null,
  because     text not null,
  note        text,
  added_on    date not null,
  added_by    text not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Working rule close-with-a-session-record. Rule open-with-record-health reads this table
-- at the start of every session.
create table ops.session_log (
  session_id   bigint generated always as identity primary key,
  lane         text not null,
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  summary      text not null,
  changed      text,
  found        text,
  open_items   text,
  doc_path     text,
  created_at   timestamptz not null default now()
);
create index on ops.session_log (lane, started_at desc);

-- A decision the Publisher makes. A fact he repeats is a citation, not a ruling
-- (working rule no-citation-loops).
create table ops.rulings (
  ruling_id   bigint generated always as identity primary key,
  subject     text not null,
  decision    text not null check (decision in ('accepted','rejected','deferred','amended')),
  ruled_by    text not null,
  ruled_at    timestamptz not null default now(),
  verbatim    text,
  note        text,
  supersedes  bigint references ops.rulings(ruling_id),
  created_at  timestamptz not null default now()
);

-- ===========================================================================
-- RLS: deny-all. Row security on, no policies, no grants to anon/authenticated.
-- ===========================================================================

do $rls$
declare r record;
begin
  for r in
    select schemaname, tablename from pg_tables where schemaname in ('site','ops')
  loop
    -- ENABLE, not FORCE — this matches the shape cfb already has in the previous project
    -- (46 tables, row security on, zero policies), which is what "deny-all, as today" means.
    -- FORCE would also subject the table owner to RLS, a silent divergence from that shape.
    execute format('alter table %I.%I enable row level security', r.schemaname, r.tablename);
  end loop;
end
$rls$;

revoke all on all tables    in schema site, ops from public;
revoke all on all sequences in schema site, ops from public;
revoke all on schema site, ops from public;

do $grants$
begin
  -- Supabase's roles are absent from a vanilla postgres; ci.yml creates them so this
  -- migration exercises the same path it will take in production.
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on all tables in schema site, ops from anon;
    revoke all on schema site, ops from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on all tables in schema site, ops from authenticated;
    revoke all on schema site, ops from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema site, ops to service_role;
    grant select, insert, update, delete on all tables in schema site, ops to service_role;
    grant usage, select on all sequences in schema site, ops to service_role;
  end if;
end
$grants$;

-- ===========================================================================
-- Seed: the working rules, verbatim, with their incidents.
-- Eleven rules. The genesis seed document numbers them 1-9, then 10a
-- ("answer-the-question", explicitly "seed as the ELEVENTH rule"), then 10
-- ("ddl-exported-same-session"). Both are seeded; the count is 11, not 10.
-- ===========================================================================

insert into ops.working_rules (ordinal, rule_id, rule, because, note, added_on, added_by) values
(1, 'record-first',
 $r$Write the document to docs.documents FIRST, then mirror it to the Claude Project. Never the other way round.$r$,
 $b$On 2026-08-06 nine documents went to the Project and one reached the record; if interrupted halfway, this order leaves the SHARED copy done rather than the private one.$b$,
 $n$Genesis note: in the new world read "the record" as the repo + ops; the ordering principle — shared copy first — is what carries.$n$,
 date '2026-08-06', 'fabio'),

(2, 'open-with-record-health',
 $r$Run the record-health check at the start of every session, before reading any document.$r$,
 $b$A lane silent in the record while working is a lane whose picture you are about to inherit wrongly.$b$,
 $n$Genesis note: the new-world equivalent queries ops.session_log.$n$,
 date '2026-08-06', 'fabio'),

(3, 'close-with-a-session-record',
 $r$Every working session ends with a session record: what changed, what was found, what is open, ranked.$r$,
 $b$Continuity is the deliverable; reconstruction is where this project has repeatedly gone wrong.$b$,
 null, date '2026-08-06', 'fabio'),

(4, 'no-proxy-characterisation',
 $r$Never characterise a group of rows from a proxy when the real field is on the table.$r$,
 $b$Broken three times on 2026-08-06 and caught three times — preview form read from headlines when articles.scope held it; webfetch called summarised from average length when fetch_notes said paywalled row by row; 21 articles called incomplete by a regex that matched the word "untruncated".$b$,
 null, date '2026-08-06', 'fabio'),

(5, 'define-before-applying',
 $r$Write the definition down before you ask anyone to apply it.$r$,
 $b$The pilot assigned form from a stored label and asked coders "is this the form its label claims" without saying what the form was; 95% agreement with the written rule was luck, and only measurable because the Publisher asked out loud.$b$,
 null, date '2026-08-06', 'fabio'),

(6, 'test-patch-retest-write',
 $r$Dry-run a transformation over the whole set, patch what the residual scan finds, re-run, and only then write.$r$,
 $b$The first body extractor reported "applied 62 words" as success and had written a promotional card into article 127 as if it were Ryan Aber's reporting. A success message is not evidence — look at what landed.$b$,
 null, date '2026-08-06', 'fabio'),

(7, 'no-citation-loops',
 $r$When the Publisher restates something this project already told him, that is not evidence and it is not a ruling. Check it against the tables like any other claim, and label it as a restatement in the record.$r$,
 $b$On 2026-08-06 an unsupported finding came back wearing his authority and was promoted; he said unprompted, "Don't let that guide your actions. I was only quoting you." A decision he makes is a ruling; a fact he repeats is a citation, and the citation is to us.$b$,
 null, date '2026-08-06', 'fabio'),

(8, 'fabio-does-not-apply',
 $r$THE TEST: if it changes what a number MEANS, it is an assignment. If it IS a number a run produced, Fabio records it in the same turn. DDL and migrations: never Fabio, assignment only. Shared definitions: propose, Clyde applies. Run output: Fabio writes, INSERT ONLY. Prose records: Fabio's.$r$,
 $b$On 2026-08-06 Fabio applied a production migration reading a ruling on WHAT as permission for WHO. The line is drawn where the opposite error is worse: blocking same-turn recording would recreate the 27-game loss, the single most expensive thing that has happened to this project. Reversible by the Publisher at any time. Re-confirmed 2026-08-07, pre-call: on "I need help setting up the Supabase project," Fabio moved to create it via MCP; the Publisher stopped it before any call ran. Infrastructure clicks — projects, repos, spend, credentials — are the Publisher's even when the spend is pre-approved; "help" means walk him through it.$b$,
 $n$Incident appended 2026-08-07.$n$,
 date '2026-08-06', 'fabio'),

(9, 'cite-only-what-the-reader-can-reach',
 $r$Never cite a document in an assignment that its executor cannot read. If he needs it, it goes where he can reach it, in the same turn as the citation.$r$,
 $b$On 2026-08-06 an assignment cited a Claude Project doc Clyde could not read — and the figure quoted from it was stale anyway.$b$,
 $n$Genesis note: in the new world everyone reads the public repo, which retires most of this rule's bite; it stays because it is cheap and it was paid for.$n$,
 date '2026-08-06', 'fabio'),

(10, 'ddl-exported-same-session',
 $r$No session that applies DDL ends with it unexported. The migration file reaches the repo in the same session that applied it — no exceptions.$r$,
 $b$The August 6 evaluation found 43 of 57 applied migrations existed only in the database — the repo could not rebuild it. Ratified by Robert the same evening.$b$,
 null, date '2026-08-06', 'fable-eval'),

(11, 'answer-the-question',
 $r$When the Publisher asks a question, answer the question — nothing else. No action of any kind without his explicit approval. This bounds do-more-ask-less: that instruction governs how to execute approved work, never whether to start new work.$r$,
 $b$On 2026-08-07 "I need help setting up the Supabase project" was met with "On it — I'll create AIP2 for you right now"; he stopped it pre-call and gave the instruction verbatim the same evening, ratified in the same exchange.$b$,
 null, date '2026-08-07', 'robert via fabio')
on conflict (rule_id) do nothing;

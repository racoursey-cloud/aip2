-- 0002_cfb_sync_schedule.sql
-- Genesis, Job 3. Recreate the weekly cfb sync schedule in AIP2.
--
-- The cfb schema arrived by pg_restore, which carries its tables and its two sync functions
-- but NOT the pg_cron entries that drive them: cron.job lives in the cron schema, outside the
-- dump. Without this file the data is present and the sync is dead, which is the kind of quiet
-- half-migration that is only ever noticed in September.
--
-- The schedule matches the previous project's three cfb entries exactly. The three `voice`
-- entries that also ran there are deliberately NOT recreated: the voice schema is not carried
-- into AIP2, it stays in the sealed archive, and transcript retrieval is rebuilt in Wave 2.
--
-- Guarded on pg_cron being installed so that ci.yml can still apply this file to a vanilla
-- PostgreSQL 17, which has neither pg_cron nor the cfb schema. cron.schedule() is reached only
-- inside the guarded branch, and the function bodies it schedules are plain strings resolved
-- at fire time, so nothing here needs cfb to exist at apply time.

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron is not installed; skipping the cfb sync schedule (expected in CI).';
    return;
  end if;

  -- cron.schedule upserts on (jobname, username), so re-applying is idempotent.
  perform cron.schedule('cfb-weekly-enqueue',  '0 9 * * 1',         'select cfb.enqueue_weekly_sync()');
  perform cron.schedule('cfb-process-morning', '2-59/5 9-11 * * 1', 'select cfb.process_sync_responses()');
  perform cron.schedule('cfb-process-midday',  '0,15,30 13 * * 1',  'select cfb.process_sync_responses()');

  raise notice 'cfb sync schedule installed: 3 jobs.';
end
$$;

import { hasDatabaseConfig, supabaseServer } from '@/lib/supabase';

// Rendered per request, on the server. Never statically prerendered: the data is read with
// a service-role key, and a build should not need database credentials to succeed.
export const dynamic = 'force-dynamic';

type Snapshot = {
  configured: boolean;
  error?: string;
  games2026?: number | null;
  rules?: number | null;
  rivalry?: {
    start_date: string;
    home_team: string;
    away_team: string;
    venue: string | null;
  } | null;
};

async function readSnapshot(): Promise<Snapshot> {
  if (!hasDatabaseConfig()) return { configured: false };

  const db = supabaseServer();
  try {
    const [games, rules, rivalry] = await Promise.all([
      db.schema('cfb').from('games').select('*', { count: 'exact', head: true }).eq('season', 2026),
      db.schema('ops').from('working_rules').select('*', { count: 'exact', head: true }),
      db
        .schema('cfb')
        .from('games')
        .select('start_date, home_team, away_team, venue')
        .eq('home_team', 'Georgia State')
        .eq('away_team', 'Georgia Southern')
        .gte('start_date', '2026-11-14')
        .lt('start_date', '2026-11-16')
        .maybeSingle(),
    ]);

    return {
      configured: true,
      games2026: games.count ?? null,
      rules: rules.count ?? null,
      rivalry: (rivalry.data as Snapshot['rivalry']) ?? null,
    };
  } catch (e) {
    return { configured: true, error: e instanceof Error ? e.message : String(e) };
  }
}

export default async function Home() {
  const snap = await readSnapshot();

  return (
    <main>
      <p className="kicker">Genesis</p>
      <h1>The A.I. Pickens Report</h1>
      <p className="dek">
        A weekly brief, a pregame piece, picks with the line frozen at pick time and graded on
        the record afterward, and — the part that keeps the rest honest — what somebody actually
        watched happen.
      </p>

      <hr />

      {!snap.configured && (
        <p className="note">
          No database credentials in this environment, so the numbers below are not being read.
          Set <code>SUPABASE_URL</code> and <code>SUPABASE_SERVICE_ROLE_KEY</code>; see{' '}
          <code>site/.env.example</code>.
        </p>
      )}

      {snap.error && (
        <p className="note">
          The database is configured but did not answer: {snap.error}
        </p>
      )}

      {snap.configured && !snap.error && (
        <>
          <div className="grid">
            <div className="stat">
              <div className="n">{snap.games2026 ?? '—'}</div>
              <div className="l">2026 games loaded</div>
            </div>
            <div className="stat">
              <div className="n">{snap.rules ?? '—'}</div>
              <div className="l">working rules</div>
            </div>
          </div>

          <hr />

          <h2 style={{ fontSize: '1.1rem', margin: '0 0 .5rem' }}>The rivalry</h2>
          {snap.rivalry ? (
            <p style={{ margin: 0 }}>
              {snap.rivalry.away_team} at {snap.rivalry.home_team},{' '}
              {new Date(snap.rivalry.start_date).toLocaleDateString('en-US', {
                weekday: 'long',
                month: 'long',
                day: 'numeric',
                year: 'numeric',
                timeZone: 'UTC',
              })}
              {snap.rivalry.venue ? `, ${snap.rivalry.venue}` : ''}.
            </p>
          ) : (
            <p className="note" style={{ margin: 0 }}>
              The November 14 game is not in the database yet — cfb has not been restored into
              this project.
            </p>
          )}
        </>
      )}

      <hr />

      <p className="note">
        Skeleton only. The site itself is Wave 1; this page exists to prove the server can reach
        the database with credentials that never touch a browser bundle.
      </p>
    </main>
  );
}
